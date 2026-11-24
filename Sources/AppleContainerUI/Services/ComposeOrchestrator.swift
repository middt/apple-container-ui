import Foundation

/// One command of a Compose execution plan, as an argument vector for the `container` CLI.
struct ComposePlanStep: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Run `container <arguments>`.
        case command
        /// Poll `container <arguments>` (an `exec` of the service's healthcheck) until it exits 0.
        case waitHealthy(container: String, timeoutSeconds: Int)
        /// Wait until the container has stopped (a one-shot job such as a migrator has finished).
        case waitExited(container: String, timeoutSeconds: Int)
    }

    let id: Int
    /// Arguments after the tool name, e.g. `["run", "-d", "--name", "web", "nginx"]`.
    let arguments: [String]
    /// A failing step with `allowFailure` (e.g. "network already exists") does not abort the plan.
    var allowFailure: Bool = false
    var note: String? = nil
    var kind: Kind = .command

    var displayCommand: String {
        switch kind {
        case .command:
            return ShellWords.join(["container"] + arguments)
        case .waitHealthy(let container, let timeout):
            return "# wait up to \(timeout)s until \(container) is healthy: " + ShellWords.join(["container"] + arguments)
        case .waitExited(let container, let timeout):
            return "# wait up to \(timeout)s until \(container) has finished"
        }
    }
}

struct ComposeParseResult: Equatable {
    var services: [ComposeServiceDefinition] = []
    /// Named volumes declared at the top level or referenced by services.
    var namedVolumes: [String] = []
    var warnings: [String] = []
    /// Key of the first top-level network, if the file declares one.
    var networkKey: String? = nil
    /// `networks.<key>.name`, if set.
    var networkExplicitName: String? = nil
    var networkIsExternal: Bool = false
    /// Named volumes that keep their name (`external: true` or an explicit `name:`), by key.
    var fixedVolumeNames: [String: String] = [:]
}

/// Parses standard `docker-compose.yml` / `compose.yaml` files and turns them into
/// `apple/container` commands, without requiring any manual conversion.
enum ComposeOrchestrator {

    // MARK: - Parsing

    /// Convenience wrapper used where only the service list matters.
    static func parseServices(from yaml: String) -> [ComposeServiceDefinition] {
        parse(yaml: yaml).services
    }

    /// Parses a Compose file.
    /// - Parameters:
    ///   - baseDirectory: directory of the Compose file; `.env`, `env_file` and relative paths resolve against it.
    ///   - environment: variables available to `${VAR}` interpolation (the process environment by default).
    static func parse(
        yaml: String,
        baseDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ComposeParseResult {
        var result = ComposeParseResult()

        // Compose precedence: the shell environment overrides the project's `.env` file.
        var variables: [String: String] = [:]
        if let baseDirectory,
           let dotEnv = try? String(contentsOfFile: (baseDirectory as NSString).appendingPathComponent(".env"), encoding: .utf8) {
            variables = parseDotEnv(dotEnv)
        }
        variables.merge(environment) { _, shell in shell }

        var missing: [String] = []
        let root = MiniYAML.parse(yaml).mapScalars { interpolate($0, variables: variables, missing: &missing) }
        for name in missing where !result.warnings.contains(where: { $0.contains("${\(name)}") }) {
            result.warnings.append("Variable ${\(name)} is not set; an empty string was substituted.")
        }

        guard let servicesMap = root["services"]?.map else {
            return result
        }

        var namedVolumes: [String] = root["volumes"]?.map?.keys ?? []
        for (key, node) in root["volumes"]?.map?.entries ?? [] {
            if let explicit = node["name"]?.string {
                result.fixedVolumeNames[key] = explicit
            } else if isTruthy(node["external"]) {
                result.fixedVolumeNames[key] = key
            }
        }

        // Vessel attaches every service of a stack to one network: the first one the file declares.
        if let (key, node) = root["networks"]?.map?.entries.first {
            result.networkKey = key
            result.networkExplicitName = node["name"]?.string
            result.networkIsExternal = isTruthy(node["external"])
        }
        if (root["networks"]?.map?.keys.count ?? 0) > 1 {
            result.warnings.append("Several networks are declared; Vessel attaches every service to the first one.")
        }

        // Compose profiles: a service with `profiles:` only runs when one of them is active.
        let activeProfiles = Set((variables["COMPOSE_PROFILES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        var skippedByProfile: [String] = []
        var services: [ComposeServiceDefinition] = []

        for (name, node) in servicesMap.entries {
            let service = parseService(name: name, node: node, baseDirectory: baseDirectory, warnings: &result.warnings)
            if !service.profiles.isEmpty && activeProfiles.isDisjoint(with: service.profiles) {
                skippedByProfile.append(name)
                continue
            }
            for spec in service.volumes {
                if let volumeName = namedVolume(in: spec), !namedVolumes.contains(volumeName) {
                    namedVolumes.append(volumeName)
                }
            }
            services.append(service)
        }

        if !skippedByProfile.isEmpty {
            result.warnings.append("Skipped by profile (set COMPOSE_PROFILES in .env to enable): \(skippedByProfile.joined(separator: ", ")).")
        }
        result.services = sortServicesByDependencies(services)
        result.namedVolumes = namedVolumes
        return result
    }

    private static func isTruthy(_ node: YAMLNode?) -> Bool {
        guard let node else { return false }
        if let text = node.string { return text.lowercased() == "true" }
        return node.map != nil      // `external: { name: x }` (legacy form)
    }

    /// Parses Compose durations such as `10s`, `1m30s`, `500ms`, `2h` into whole seconds.
    static func parseDurationSeconds(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        if let plain = Double(text) { return Int(plain.rounded(.up)) }
        var total = 0.0
        var number = ""
        var unit = ""
        func flush() -> Bool {
            guard let value = Double(number) else { return false }
            switch unit {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            case "ms": total += value / 1000
            case "us", "µs": total += value / 1_000_000
            default: return false
            }
            number = ""
            unit = ""
            return true
        }
        for ch in text {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty, !flush() { return nil }
                number.append(ch)
            } else {
                unit.append(ch)
            }
        }
        guard flush() else { return nil }
        return Int(total.rounded(.up))
    }

    private static func parseService(
        name: String,
        node: YAMLNode,
        baseDirectory: String?,
        warnings: inout [String]
    ) -> ComposeServiceDefinition {
        var service = ComposeServiceDefinition(
            name: name,
            image: node["image"]?.string ?? "",
            ports: [],
            environment: [:],
            volumes: [],
            dependsOn: [],
            cpus: 2,
            memoryMB: 512
        )

        // build: "./dir"  |  build: { context, dockerfile, args, target }
        if let buildNode = node["build"] {
            if let context = buildNode.string {
                service.build = ComposeBuild(context: context)
            } else if buildNode.map != nil {
                service.build = ComposeBuild(
                    context: buildNode["context"]?.string ?? ".",
                    dockerfile: buildNode["dockerfile"]?.string,
                    args: keyValuePairs(buildNode["args"]),
                    target: buildNode["target"]?.string
                )
            }
        }
        if service.image.isEmpty {
            service.image = "\(name):latest"
        }

        service.containerName = node["container_name"]?.string
        service.workingDir = node["working_dir"]?.string
        service.user = node["user"]?.string
        service.restart = node["restart"]?.string
        service.labels = keyValuePairs(node["labels"])
        service.profiles = stringList(node["profiles"])
        service.capAdd = stringList(node["cap_add"])
        service.capDrop = stringList(node["cap_drop"])
        service.tmpfs = stringList(node["tmpfs"])
        service.networkMode = node["network_mode"]?.string
        if let mode = service.networkMode, mode.hasPrefix("service:") || mode.hasPrefix("container:") {
            warnings.append("\(name): network_mode '\(mode)' is not possible on apple/container — every container is its own VM and cannot share another one's network. The service runs with its own address; point it at the other service by name instead of localhost.")
        }

        if let command = node["command"] {
            service.command = commandWords(command)
        }
        if let entrypoint = node["entrypoint"] {
            service.entrypoint = commandWords(entrypoint)
        }

        // Resources: `cpus` / `mem_limit` (v2 style) and `deploy.resources.limits` (v3 style).
        let limits = node["deploy"]?["resources"]?["limits"]
        if let cpuText = node["cpus"]?.string ?? limits?["cpus"]?.string, let cpus = Double(cpuText) {
            service.cpus = max(1, Int(cpus.rounded(.up)))
        }
        if let memText = node["mem_limit"]?.string ?? node["memory"]?.string ?? limits?["memory"]?.string,
           let megabytes = parseMemoryMB(memText) {
            service.memoryMB = megabytes
        }

        // env_file first, then `environment` overrides it.
        let envFileNodes: [YAMLNode] = node["env_file"].map { $0.list ?? [$0] } ?? []
        for envFileNode in envFileNodes {
            guard let path = envFileNode.string ?? envFileNode["path"]?.string else { continue }
            service.envFiles.append(path)
            let resolved = resolvePath(path, baseDirectory: baseDirectory)
            if let content = try? String(contentsOfFile: resolved, encoding: .utf8) {
                service.environment.merge(parseDotEnv(content)) { _, new in new }
            } else {
                warnings.append("\(name): env_file '\(path)' could not be read.")
            }
        }
        service.environment.merge(keyValuePairs(node["environment"])) { _, new in new }

        for portNode in node["ports"]?.list ?? [] {
            let mappings = parsePortNode(portNode)
            if mappings.isEmpty {
                warnings.append("\(name): port '\(portNode.string ?? "?")' has no fixed host port and was skipped.")
            }
            service.ports.append(contentsOf: mappings)
        }

        for volumeNode in node["volumes"]?.list ?? [] {
            if let spec = volumeNode.string {
                service.volumes.append(spec)
            } else if volumeNode["type"]?.string == "tmpfs", let target = volumeNode["target"]?.string {
                service.tmpfs.append(target)
            } else if volumeNode.map != nil, let target = volumeNode["target"]?.string {
                // Long syntax -> short syntax.
                var spec = target
                if let source = volumeNode["source"]?.string, !source.isEmpty {
                    spec = "\(source):\(target)"
                    if volumeNode["read_only"]?.string?.lowercased() == "true" {
                        spec += ":ro"
                    }
                }
                service.volumes.append(spec)
            }
        }

        if let dependsOn = node["depends_on"] {
            if let list = dependsOn.list {
                service.dependsOn = list.compactMap { $0.string }
            } else if let map = dependsOn.map {
                service.dependsOn = map.keys
                for (dependency, options) in map.entries {
                    if let condition = options["condition"]?.string {
                        service.dependencyConditions[dependency] = condition
                    }
                }
            }
        }

        if let health = node["healthcheck"], health.map != nil {
            var test: [String] = []
            if let testList = health["test"]?.list {
                test = testList.compactMap { $0.string }
            } else if let testString = health["test"]?.string {
                test = ["CMD-SHELL", testString]
            }
            let disabled = health["disable"]?.string?.lowercased() == "true" || test.first == "NONE"
            service.healthcheck = ComposeHealthcheck(
                test: test,
                interval: health["interval"]?.string,
                timeout: health["timeout"]?.string,
                retries: health["retries"]?.string.flatMap { Int($0) },
                startPeriod: health["start_period"]?.string,
                disabled: disabled
            )
        }

        return service
    }

    /// A YAML list of scalars, or a single scalar, as strings.
    private static func stringList(_ node: YAMLNode?) -> [String] {
        guard let node else { return [] }
        if let list = node.list { return list.compactMap { $0.string } }
        if let text = node.string { return [text] }
        return []
    }

    /// `command: "nginx -g 'daemon off;'"` (shell words) or `command: ["nginx", "-g", "daemon off;"]`.
    private static func commandWords(_ node: YAMLNode) -> [String] {
        if let list = node.list {
            return list.compactMap { $0.string }
        }
        if let text = node.string {
            return ShellWords.split(text)
        }
        return []
    }

    /// Accepts both the map form (`KEY: value`) and the list form (`- KEY=value`).
    private static func keyValuePairs(_ node: YAMLNode?) -> [String: String] {
        guard let node else { return [:] }
        var pairs: [String: String] = [:]
        if let map = node.map {
            for (key, value) in map.entries {
                pairs[key] = value.string ?? ""
            }
        } else if let list = node.list {
            for item in list {
                guard let text = item.string else { continue }
                if let separator = text.firstIndex(of: "=") {
                    let key = text[..<separator].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        pairs[key] = String(text[text.index(after: separator)...])
                    }
                } else if !text.isEmpty {
                    // `- KEY` passes the host value through.
                    pairs[text] = ProcessInfo.processInfo.environment[text] ?? ""
                }
            }
        }
        return pairs
    }

    // MARK: - Ports

    private static let knownHTTPPorts: Set<Int> = [80, 443, 3000, 3001, 5000, 5173, 8000, 8080, 8081, 8088, 8090, 8443, 8888, 9000]

    private static func parsePortNode(_ node: YAMLNode) -> [PortMapping] {
        if let text = node.string {
            return parsePortMappings(text)
        }
        guard node.map != nil,
              let target = node["target"]?.string.flatMap({ Int($0) }),
              let published = node["published"]?.string.flatMap({ Int($0) }) else {
            return []
        }
        let explicit = node["app_protocol"]?.string ?? node["protocol"]?.string
        return [makePort(
            hostIP: node["host_ip"]?.string ?? "0.0.0.0",
            hostPort: published,
            containerPort: target,
            explicitProtocol: explicit?.lowercased()
        )]
    }

    /// Parses the Compose short port syntax:
    /// `8080:80`, `127.0.0.1:8080:80`, `[::1]:8080:80`, `8080:80/udp`, `8000-8002:8000-8002`.
    /// Vessel additionally accepts `/http` and `/https` as UI hints.
    static func parsePortMappings(_ raw: String) -> [PortMapping] {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var explicitProtocol: String? = nil
        if let slash = text.lastIndex(of: "/") {
            explicitProtocol = text[text.index(after: slash)...].lowercased()
            text = String(text[..<slash])
        }

        var parts = text.components(separatedBy: ":")
        guard parts.count >= 2, let containerPart = parts.popLast(), let hostPart = parts.popLast() else {
            return []
        }
        var hostIP = parts.joined(separator: ":")
        if hostIP.hasPrefix("[") && hostIP.hasSuffix("]") {
            hostIP = String(hostIP.dropFirst().dropLast())
        }
        if hostIP.isEmpty {
            hostIP = "0.0.0.0"
        }

        guard let hostRange = parsePortRange(hostPart), let containerRange = parsePortRange(containerPart),
              hostRange.count == containerRange.count, hostRange.count <= 256 else {
            return []
        }
        return zip(hostRange, containerRange).map { hostPort, containerPort in
            makePort(hostIP: hostIP, hostPort: hostPort, containerPort: containerPort, explicitProtocol: explicitProtocol)
        }
    }

    private static func parsePortRange(_ text: String) -> [Int]? {
        let bounds = text.components(separatedBy: "-")
        if bounds.count == 1, let port = Int(bounds[0]), (1...65535).contains(port) {
            return [port]
        }
        if bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]),
           (1...65535).contains(low), (1...65535).contains(high), low <= high {
            return Array(low...high)
        }
        return nil
    }

    static func makePort(hostIP: String, hostPort: Int, containerPort: Int, explicitProtocol: String?) -> PortMapping {
        let protocolType: String
        if let explicitProtocol, ["tcp", "udp", "http", "https"].contains(explicitProtocol) {
            // An explicit protocol always wins over port-number inference.
            protocolType = explicitProtocol
        } else if knownHTTPPorts.contains(containerPort) || knownHTTPPorts.contains(hostPort) {
            protocolType = (containerPort == 443 || hostPort == 8443) ? "https" : "http"
        } else {
            protocolType = "tcp"
        }
        return PortMapping(hostIP: hostIP, hostPort: hostPort, containerPort: containerPort, protocolType: protocolType)
    }

    // MARK: - Scalars, interpolation, dotenv

    /// Parses Compose byte values (`512m`, `1g`, `1.5GB`, `268435456`) into whole megabytes.
    static func parseMemoryMB(_ text: String) -> Int? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        let numberPart = lower.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(numberPart) else { return nil }
        let unit = lower.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)

        let bytes: Double
        switch unit {
        case "", "b": bytes = value
        case "k", "kb", "kib": bytes = value * 1024
        case "m", "mb", "mib": bytes = value * 1024 * 1024
        case "g", "gb", "gib": bytes = value * 1024 * 1024 * 1024
        default: return nil
        }
        return max(1, Int((bytes / (1024 * 1024)).rounded()))
    }

    /// Compose variable interpolation: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`,
    /// `${VAR:+alt}`, `${VAR+alt}`, `${VAR:?error}`, `${VAR?error}` and the `$$` escape.
    static func interpolate(_ text: String, variables: [String: String], missing: inout [String]) -> String {
        guard text.contains("$") else { return text }
        let chars = Array(text)
        var result = ""
        var index = 0

        func isNameStart(_ ch: Character) -> Bool { ch == "_" || (ch.isASCII && ch.isLetter) }
        func isNameChar(_ ch: Character) -> Bool { ch == "_" || (ch.isASCII && (ch.isLetter || ch.isNumber)) }

        while index < chars.count {
            let ch = chars[index]
            guard ch == "$", index + 1 < chars.count else {
                result.append(ch)
                index += 1
                continue
            }
            let next = chars[index + 1]

            if next == "$" {
                result.append("$")
                index += 2
            } else if next == "{" {
                // Find the matching brace (defaults may contain nested `${...}`).
                var depth = 1
                var cursor = index + 2
                while cursor < chars.count, depth > 0 {
                    if chars[cursor] == "{" { depth += 1 }
                    if chars[cursor] == "}" { depth -= 1 }
                    if depth > 0 { cursor += 1 }
                }
                guard cursor < chars.count else {
                    result.append(contentsOf: chars[index...])
                    break
                }
                let inner = String(chars[(index + 2)..<cursor])
                result += expandBraced(inner, variables: variables, missing: &missing)
                index = cursor + 1
            } else if isNameStart(next) {
                var cursor = index + 1
                while cursor < chars.count, isNameChar(chars[cursor]) { cursor += 1 }
                let name = String(chars[(index + 1)..<cursor])
                if let value = variables[name] {
                    result += value
                } else if !missing.contains(name) {
                    missing.append(name)
                }
                index = cursor
            } else {
                result.append(ch)
                index += 1
            }
        }
        return result
    }

    private static func expandBraced(_ inner: String, variables: [String: String], missing: inout [String]) -> String {
        let name = String(inner.prefix { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) })
        let rest = String(inner.dropFirst(name.count))
        let value = variables[name]

        if rest.isEmpty {
            if value == nil, !missing.contains(name) { missing.append(name) }
            return value ?? ""
        }

        let treatsEmptyAsUnset = rest.hasPrefix(":")
        let operatorAndWord = treatsEmptyAsUnset ? String(rest.dropFirst()) : rest
        guard let op = operatorAndWord.first else { return value ?? "" }
        let word = String(operatorAndWord.dropFirst())
        let isSet = treatsEmptyAsUnset ? !(value ?? "").isEmpty : value != nil

        switch op {
        case "-":
            return isSet ? (value ?? "") : interpolate(word, variables: variables, missing: &missing)
        case "+":
            return isSet ? interpolate(word, variables: variables, missing: &missing) : ""
        case "?":
            if !isSet, !missing.contains(name) { missing.append(name) }
            return value ?? ""
        default:
            return value ?? ""
        }
    }

    /// Parses `.env` / `env_file` content: `KEY=value`, `export KEY=value`, quotes and `#` comments.
    static func parseDotEnv(_ content: String) -> [String: String] {
        var variables: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = MiniYAML.unquote(value)
            } else {
                value = MiniYAML.stripComment(value).trimmingCharacters(in: .whitespaces)
            }
            variables[key] = value
        }
        return variables
    }

    // MARK: - Paths and volumes

    static func resolvePath(_ path: String, baseDirectory: String?) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        if path.hasPrefix("/") {
            return path
        }
        guard let baseDirectory else { return path }
        return ((baseDirectory as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    private static func isHostPath(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
    }

    /// The named volume referenced by a `source:target[:mode]` spec, if any.
    static func namedVolume(in spec: String) -> String? {
        let parts = spec.components(separatedBy: ":")
        guard parts.count >= 2, let source = parts.first, !source.isEmpty, !isHostPath(source) else { return nil }
        return source
    }

    /// Makes a volume spec absolute so it means the same thing regardless of the working directory.
    static func resolveVolumeSpec(_ spec: String, baseDirectory: String?) -> String {
        var parts = spec.components(separatedBy: ":")
        guard parts.count >= 2, isHostPath(parts[0]) else { return spec }
        parts[0] = resolvePath(parts[0], baseDirectory: baseDirectory)
        return parts.joined(separator: ":")
    }

    // MARK: - Dependency ordering

    /// Orders services so that every service comes after the ones it depends on.
    /// Unknown dependencies and dependency cycles are tolerated.
    static func sortServicesByDependencies(_ services: [ComposeServiceDefinition]) -> [ComposeServiceDefinition] {
        var result: [ComposeServiceDefinition] = []
        var visited: Set<String> = []
        let byName = Dictionary(services.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })

        func visit(_ service: ComposeServiceDefinition) {
            guard !visited.contains(service.name) else { return }
            visited.insert(service.name)
            for dependency in service.dependsOn {
                if let dependencyService = byName[dependency] {
                    visit(dependencyService)
                }
            }
            result.append(service)
        }

        for service in services {
            visit(service)
        }
        return result
    }

    // MARK: - Apple Container execution plan

    static func containerName(stackName: String, service: ComposeServiceDefinition) -> String {
        if let explicit = service.containerName, !explicit.isEmpty {
            return explicit
        }
        return "\(stackName)-\(service.name)-1"
    }

    /// The actual name of a named volume: fixed for `external` / `name:` volumes, `<stack>_<key>` otherwise.
    static func volumeName(_ key: String, in stack: ComposeStackItem) -> String {
        stack.volumeNames[key] ?? "\(stack.name)_\(key)"
    }

    /// Lowercase letters, digits and hyphens only — what a DNS label may contain.
    static func dnsLabel(_ text: String) -> String {
        let mapped = text.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" ? ch : "-"
        }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isValidDNSLabel(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 63 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            && !text.hasPrefix("-") && !text.hasSuffix("-")
    }

    /// The DNS zone in which the services of a network find each other: `<network>.<domain>`.
    /// Scoping by network keeps equally named services of unrelated stacks apart, while stacks
    /// that share an external network can still reach each other — like Docker's per-network DNS.
    static func dnsScope(network: String, domain: String) -> String {
        "\(dnsLabel(network)).\(domain)"
    }

    /// The `container` commands that bring a stack up, in dependency order.
    /// - Parameters:
    ///   - existingContainerNames: containers that already exist; the stack's own stale containers
    ///     among them are removed first so `container run --name` cannot collide.
    ///   - dnsDomain: a local DNS domain created with `container system dns create`. With it every
    ///     service is reachable from the others by service name and by container name; without it
    ///     containers can only reach each other by IP address.
    static func buildAppleContainerPlan(
        for stack: ComposeStackItem,
        existingContainerNames: Set<String> = [],
        dnsDomain: String? = nil
    ) -> [ComposePlanStep] {
        var steps: [ComposePlanStep] = []
        func add(_ arguments: [String], allowFailure: Bool = false, note: String? = nil, kind: ComposePlanStep.Kind = .command) {
            steps.append(ComposePlanStep(id: steps.count, arguments: arguments, allowFailure: allowFailure, note: note, kind: kind))
        }

        let names = stack.services.map { containerName(stackName: stack.name, service: $0) }
        let stale = names.filter { existingContainerNames.contains($0) }
        if !stale.isEmpty {
            add(["delete", "--force"] + stale, allowFailure: true, note: "Replace containers from a previous deployment")
        }

        let network = stack.networkName.isEmpty ? "default" : stack.networkName
        if network != "default" {
            add(["network", "create", network], allowFailure: true, note: "Ignored if the network already exists")
        }
        let scope = dnsDomain.map { dnsScope(network: network, domain: $0) }

        var volumeKeys: [String] = []
        for service in stack.services {
            for spec in service.volumes {
                if let key = namedVolume(in: spec), !volumeKeys.contains(key) {
                    volumeKeys.append(key)
                }
            }
        }
        for key in volumeKeys {
            add(["volume", "create", volumeName(key, in: stack)], allowFailure: true, note: "Ignored if the volume already exists")
        }

        let byName = Dictionary(stack.services.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })

        for service in stack.services {
            // Compose `depends_on` conditions: wait for dependencies before starting this service.
            for dependency in service.dependsOn {
                guard let condition = service.dependencyConditions[dependency], let dependencyService = byName[dependency] else { continue }
                let dependencyContainer = containerName(stackName: stack.name, service: dependencyService)
                if condition == "service_healthy", let health = dependencyService.healthcheck, !health.disabled, !health.execArguments.isEmpty {
                    add(
                        ["exec", dependencyContainer] + health.execArguments,
                        note: "\(service.name) depends on \(dependency) (service_healthy)",
                        kind: .waitHealthy(container: dependencyContainer, timeoutSeconds: health.startupTimeoutSeconds)
                    )
                } else if condition == "service_completed_successfully" {
                    add(
                        [],
                        note: "\(service.name) depends on \(dependency) (service_completed_successfully)",
                        kind: .waitExited(container: dependencyContainer, timeoutSeconds: 900)
                    )
                }
            }

            if let build = service.build {
                var arguments = ["build", "--tag", service.image]
                let context = resolvePath(build.context, baseDirectory: stack.baseDirectory)
                if let dockerfile = build.dockerfile {
                    arguments += ["--file", resolvePath(dockerfile, baseDirectory: context)]
                }
                if let target = build.target {
                    arguments += ["--target", target]
                }
                for (key, value) in build.args.sorted(by: { $0.key < $1.key }) {
                    arguments += ["--build-arg", "\(key)=\(value)"]
                }
                arguments.append(context)
                add(arguments)
            }

            let name = containerName(stackName: stack.name, service: service)
            var arguments: [String] = ["run", "--detach", "--name", name]

            if let scope {
                // Reachable by service name and by container name; short names resolve through the search domain.
                var aliases: [String] = []
                for candidate in [service.name, name] where isValidDNSLabel(candidate) && !aliases.contains(candidate.lowercased()) {
                    aliases.append(candidate.lowercased())
                }
                arguments += ["--network", ([network] + aliases.map { "alias=\($0).\(scope)" }).joined(separator: ",")]
                arguments += ["--dns-search", scope]
            } else if network != "default" {
                arguments += ["--network", network]
            }

            arguments += ["--cpus", String(service.cpus), "--memory", "\(String(service.memoryMB))M"]
            arguments += ["--label", "com.docker.compose.project=\(stack.name)"]
            arguments += ["--label", "com.docker.compose.service=\(service.name)"]
            for (key, value) in service.labels.sorted(by: { $0.key < $1.key }) {
                arguments += ["--label", "\(key)=\(value)"]
            }
            for port in service.ports {
                arguments += ["--publish", port.publishArgument]
            }
            for spec in service.volumes {
                if let key = namedVolume(in: spec) {
                    let rest = spec.dropFirst(key.count)
                    arguments += ["--volume", volumeName(key, in: stack) + rest]
                } else {
                    arguments += ["--volume", resolveVolumeSpec(spec, baseDirectory: stack.baseDirectory)]
                }
            }
            for path in service.tmpfs {
                arguments += ["--tmpfs", path]
            }
            for capability in service.capAdd {
                arguments += ["--cap-add", capability]
            }
            for capability in service.capDrop {
                arguments += ["--cap-drop", capability]
            }
            for (key, value) in service.environment.sorted(by: { $0.key < $1.key }) {
                arguments += ["--env", "\(key)=\(value)"]
            }
            if let workingDir = service.workingDir {
                arguments += ["--workdir", workingDir]
            }
            if let user = service.user {
                arguments += ["--user", user]
            }

            // `--entrypoint` takes a single executable; extra entrypoint words become leading arguments.
            var trailing = service.command
            if let entrypoint = service.entrypoint, let executable = entrypoint.first {
                arguments += ["--entrypoint", executable]
                trailing = Array(entrypoint.dropFirst()) + trailing
            }
            arguments.append(service.image)
            arguments += trailing
            add(arguments)
        }
        return steps
    }

    /// The `container` commands that take a stack down (stop, remove containers, remove its network).
    static func buildAppleContainerTeardownPlan(for stack: ComposeStackItem) -> [ComposePlanStep] {
        var steps: [ComposePlanStep] = []
        let names = stack.services.reversed().map { containerName(stackName: stack.name, service: $0) }
        guard !names.isEmpty else { return [] }

        steps.append(ComposePlanStep(id: 0, arguments: ["stop"] + names, allowFailure: true))
        steps.append(ComposePlanStep(id: 1, arguments: ["delete", "--force"] + names))
        if !stack.networkName.isEmpty, stack.networkName != "default", !stack.networkIsExternal {
            steps.append(ComposePlanStep(
                id: 2,
                arguments: ["network", "delete", stack.networkName],
                allowFailure: true,
                note: "Named volumes are kept"
            ))
        }
        return steps
    }

    /// Compose features that `apple/container` has no equivalent for.
    static func appleContainerLimitations(for services: [ComposeServiceDefinition]) -> [String] {
        var notes: [String] = []
        for service in services {
            if let health = service.healthcheck, !health.disabled {
                let gatesStartup = services.contains { $0.dependencyConditions[service.name] == "service_healthy" }
                notes.append(gatesStartup
                    ? "\(service.name): the healthcheck is only used to order startup (Vessel runs it with `container exec`); apple/container does not monitor health afterwards."
                    : "\(service.name): healthcheck is not supported by apple/container and is ignored.")
            }
            if let restart = service.restart, restart != "no" {
                notes.append("\(service.name): restart policy '\(restart)' is not supported by apple/container and is ignored.")
            }
        }
        return notes
    }

    // MARK: - Docker target

    /// Vessel accepts `8080:80/http` as a UI hint, but Docker only knows `tcp` / `udp` / `sctp`.
    /// Strips the hint from port list items so the same file can be handed to `docker compose`.
    static func dockerCompatibleYAML(_ yaml: String) -> String {
        let pattern = #"(?m)^(\s*-\s*["']?[\d.:\[\]a-fA-F-]+)/https?(["']?\s*(?:#.*)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return yaml }
        let range = NSRange(yaml.startIndex..., in: yaml)
        return regex.stringByReplacingMatches(in: yaml, range: range, withTemplate: "$1$2")
    }
}
