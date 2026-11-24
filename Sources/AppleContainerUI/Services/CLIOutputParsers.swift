import Foundation

// Parsers for real CLI output. They are pure functions so they can be unit-tested with fixtures.
//
// Rule: a value the CLI did not report stays empty / zero. Nothing is invented here —
// the views render unknown values as "—".

private func dig(_ root: Any?, _ path: String...) -> Any? {
    var current = root
    for key in path {
        guard let dict = current as? [String: Any] else { return nil }
        current = dict[key]
    }
    return current
}

private func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
}

private func int64Value(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let text = value as? String { return Int64(text) }
    return nil
}

private func doubleValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String { return Double(text) }
    return nil
}

enum CLIDateParser {
    /// Accepts ISO-8601 strings (with or without fractional seconds) and numeric timestamps.
    /// Swift's default `JSONEncoder` writes dates as seconds since 2001-01-01, so small numbers
    /// are interpreted relative to that reference date and large ones as Unix time.
    static func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            guard seconds > 0 else { return nil }
            return seconds > 1_200_000_000
                ? Date(timeIntervalSince1970: seconds)
                : Date(timeIntervalSinceReferenceDate: seconds)
        }
        guard let text = value as? String, !text.isEmpty, !text.hasPrefix("0001-01-01") else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // Docker emits nanosecond precision, which the formatter rejects: trim to milliseconds.
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<zone].prefix(3)
            let trimmed = text[..<dot] + "." + digits + text[zone...]
            if let date = fractional.date(from: String(trimmed)) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Splits an image reference into repository and tag (`ghcr.io/org/app:1.2` -> `ghcr.io/org/app`, `1.2`).
func splitImageReference(_ reference: String) -> (repository: String, tag: String) {
    if let at = reference.firstIndex(of: "@") {
        return (String(reference[..<at]), String(reference[reference.index(after: at)...]))
    }
    let lastSlash = reference.lastIndex(of: "/")
    if let colon = reference.lastIndex(of: ":"), lastSlash == nil || colon > lastSlash! {
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }
    return (reference, "latest")
}

extension ContainerItem {
    /// A container with nothing but identity; parsers fill in what the CLI actually reported.
    static func empty(id: String, name: String, backend: RuntimeBackend) -> ContainerItem {
        ContainerItem(
            id: id,
            name: name,
            image: "",
            os: "linux",
            arch: "",
            state: .stopped,
            ipAddress: "",
            macAddress: "",
            networkName: "",
            domainName: "",
            command: "",
            createdAt: Date(),
            startedAt: nil,
            cpuLimitCores: 0,
            memoryLimitBytes: 0,
            ports: [],
            mounts: [],
            env: [:],
            labels: [:],
            backend: backend,
            composeProject: nil,
            cpuUsageUsec: 0,
            cpuUtilization: 0,
            memoryUsageBytes: 0,
            networkRxBytes: 0,
            networkTxBytes: 0,
            blockReadBytes: 0,
            blockWriteBytes: 0,
            numProcesses: 0,
            metricsHistory: [],
            logs: [],
            fileEntries: []
        )
    }
}

private func environmentDictionary(_ entries: [String]) -> [String: String] {
    var env: [String: String] = [:]
    for entry in entries {
        if let separator = entry.firstIndex(of: "=") {
            env[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        } else {
            env[entry] = ""
        }
    }
    return env
}

// MARK: - apple/container

enum AppleContainerParser {
    /// Interprets `container system status --format json`.
    /// The CLI exits with 0 even when the services are stopped (`{"status":"unregistered"}`),
    /// so the exit code alone says nothing; older versions print plain text instead of JSON.
    static func isSystemRunning(statusOutput: String, exitCode: Int32) -> Bool {
        guard exitCode == 0 else { return false }
        if let object = try? JSONSerialization.jsonObject(with: Data(statusOutput.utf8)) as? [String: Any],
           let status = object["status"] as? String {
            return status.lowercased() == "running"
        }
        let text = statusOutput.lowercased()
        return text.contains("running") && !text.contains("not running") && !text.contains("not registered")
    }

    /// Parses `container system dns list --format json` (a JSON array of domain names).
    static func dnsDomains(fromJSON data: Data) -> [String] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String]) ?? []
    }

    /// Finds containers whose published ports are dead because macOS denied the Local Network
    /// permission to `container-runtime-linux`.
    ///
    /// The port forwarder then accepts the connection on the host port but cannot reach the
    /// container, and logs `backend - connect failed … No route to host (errno: 65) [uuid=<id>]`.
    /// A container that simply is not listening yet fails with "Connection refused" (errno 61)
    /// instead, so errno 65 is a reliable signal.
    /// - Parameter since: ignore log lines older than this (so errors from before a probe, or
    ///   from before the permission was granted, do not count). Lines without a timestamp are kept.
    static func containersBlockedByLocalNetwork(systemLog: String, since: Date? = nil) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"

        var ids: [String] = []
        for line in systemLog.split(whereSeparator: \.isNewline) {
            guard line.contains("backend - connect failed"), line.contains("errno: 65"),
                  let start = line.range(of: "[uuid=") else { continue }
            if let since, let timestamp = formatter.date(from: String(line.prefix(31))), timestamp < since {
                continue
            }
            let id = String(line[start.upperBound...].prefix { $0 != "]" })
            if !id.isEmpty && !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Parses `container list --all --format json`. Returns `nil` when the output is not a JSON array.
    static func containers(fromJSON data: Data) -> [ContainerItem]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.compactMap(container(from:))
    }

    static func container(from entry: [String: Any]) -> ContainerItem? {
        let config = entry["configuration"] as? [String: Any] ?? [:]
        guard let id = (config["id"] as? String) ?? (entry["id"] as? String), !id.isEmpty else { return nil }

        var item = ContainerItem.empty(id: id, name: (entry["name"] as? String) ?? id, backend: .appleContainer)

        // container 1.x nests runtime state under `status` ({ state, networks, startedDate });
        // earlier releases reported `status` as a plain string with `networks` at the top level.
        let runtime = entry["status"] as? [String: Any]
        let status = ((runtime?["state"] as? String) ?? (entry["status"] as? String) ?? (entry["state"] as? String) ?? "").lowercased()
        switch status {
        case "running": item.state = .running
        case "stopping": item.state = .stopping
        case "starting", "created": item.state = status == "starting" ? .starting : .stopped
        case "paused": item.state = .paused
        default: item.state = .stopped
        }

        item.image = (dig(config, "image", "reference") as? String) ?? (entry["image"] as? String) ?? ""
        item.os = (dig(config, "platform", "os") as? String) ?? "linux"
        item.arch = (dig(config, "platform", "architecture") as? String) ?? ""
        item.cpuLimitCores = intValue(dig(config, "resources", "cpus")) ?? 0
        item.memoryLimitBytes = int64Value(dig(config, "resources", "memoryInBytes")) ?? 0
        item.labels = (config["labels"] as? [String: String]) ?? [:]
        item.composeProject = item.labels["com.docker.compose.project"]

        if let process = config["initProcess"] as? [String: Any] {
            let executable = (process["executable"] as? String) ?? ""
            let arguments = (process["arguments"] as? [String]) ?? []
            item.command = ShellWords.join(([executable] + arguments).filter { !$0.isEmpty })
            item.env = environmentDictionary((process["environment"] as? [String]) ?? [])
        }

        let attachments = (runtime?["networks"] as? [[String: Any]]) ?? (entry["networks"] as? [[String: Any]])
        if let attachment = attachments?.first {
            let address = (attachment["ipv4Address"] as? String) ?? (attachment["address"] as? String) ?? ""
            item.ipAddress = address.components(separatedBy: "/").first ?? ""
            item.networkName = (attachment["network"] as? String) ?? ""
            item.macAddress = (attachment["macAddress"] as? String) ?? ""
            item.domainName = (attachment["hostname"] as? String) ?? ""
        }

        for port in (config["publishedPorts"] as? [[String: Any]]) ?? [] {
            guard let hostPort = intValue(port["hostPort"]), let containerPort = intValue(port["containerPort"]) else { continue }
            let transport = ((port["proto"] as? String) ?? (port["protocol"] as? String) ?? "tcp").lowercased()
            item.ports.append(ComposeOrchestrator.makePort(
                hostIP: (port["hostAddress"] as? String) ?? "0.0.0.0",
                hostPort: hostPort,
                containerPort: containerPort,
                explicitProtocol: transport == "udp" ? "udp" : nil
            ))
        }

        for mount in (config["mounts"] as? [[String: Any]]) ?? [] {
            guard let destination = mount["destination"] as? String else { continue }
            let type: String
            if let typeName = mount["type"] as? String {
                type = typeName
            } else if let typeDict = mount["type"] as? [String: Any], let typeName = typeDict.keys.first {
                type = typeName
            } else {
                type = "mount"
            }
            let options = (mount["options"] as? [String]) ?? []
            item.mounts.append(VolumeMount(
                type: type,
                source: (mount["source"] as? String) ?? "",
                destination: destination,
                readOnly: options.contains("ro")
            ))
        }

        let started = CLIDateParser.date(from: runtime?["startedDate"] ?? entry["startedDate"])
        if let created = CLIDateParser.date(from: config["creationDate"]) ?? started {
            item.createdAt = created
        }
        item.startedAt = item.state == .running ? started : nil
        return item
    }

    /// Parses `container stats --format json --no-stream`.
    static func stats(fromJSON data: Data) -> [RawContainerStatJSON]? {
        try? JSONDecoder().decode([RawContainerStatJSON].self, from: data)
    }

    /// Parses `container image list --format json`.
    /// container 1.x: `{ configuration: { name, descriptor, creationDate }, variants: [{ platform, size, config }] }`.
    static func images(fromJSON data: Data) -> [ImageItem]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            let config = entry["configuration"] as? [String: Any]
            guard let reference = (config?["name"] as? String) ?? (entry["reference"] as? String) ?? (entry["name"] as? String),
                  !reference.isEmpty else { return nil }
            let (repository, tag) = splitImageReference(reference)

            // Prefer the variant for this Mac's architecture; fall back to the first real platform.
            let variants = (entry["variants"] as? [[String: Any]]) ?? []
            let variant = variants.first { (dig($0, "platform", "architecture") as? String) == "arm64" && (dig($0, "platform", "os") as? String) == "linux" }
                ?? variants.first { (dig($0, "platform", "os") as? String) == "linux" }
                ?? variants.first
            let imageConfig = dig(variant, "config", "config") as? [String: Any]
            let command = ((imageConfig?["Entrypoint"] as? [String]) ?? []) + ((imageConfig?["Cmd"] as? [String]) ?? [])
            let exposed = ((imageConfig?["ExposedPorts"] as? [String: Any]) ?? [:]).keys
                .compactMap { Int($0.components(separatedBy: "/")[0]) }
                .sorted()

            return ImageItem(
                repository: repository,
                tag: tag,
                digest: (dig(config, "descriptor", "digest") as? String)
                    ?? (dig(entry, "descriptor", "digest") as? String) ?? (entry["digest"] as? String) ?? "",
                // The index descriptor's `size` is the manifest size, not the image size: only a variant knows that.
                sizeBytes: int64Value(variant?["size"]) ?? int64Value(entry["fullSize"]) ?? int64Value(entry["sizeBytes"]) ?? 0,
                createdAt: CLIDateParser.date(from: config?["creationDate"] ?? entry["created"] ?? entry["createdAt"]) ?? Date(),
                os: (dig(variant, "platform", "os") as? String) ?? (entry["os"] as? String) ?? "linux",
                arch: (dig(variant, "platform", "architecture") as? String) ?? (entry["arch"] as? String) ?? "",
                layersCount: (dig(variant, "config", "rootfs", "diff_ids") as? [Any])?.count ?? 0,
                exposedPorts: exposed,
                defaultCommand: ShellWords.join(command)
            )
        }
    }

    /// Parses `container volume list --format json`.
    static func volumes(fromJSON data: Data) -> [VolumeItem]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            // Resources in container 1.x wrap their properties in `configuration`; older releases are flat.
            let config = (entry["configuration"] as? [String: Any]) ?? entry
            guard let name = (config["name"] as? String) ?? (entry["id"] as? String), !name.isEmpty else { return nil }
            return VolumeItem(
                name: name,
                driver: (config["driver"] as? String) ?? "",
                format: (config["format"] as? String) ?? "",
                mountpoint: (config["source"] as? String) ?? (config["mountpoint"] as? String) ?? "",
                sizeBytes: int64Value(config["sizeInBytes"]) ?? int64Value(config["size"]) ?? 0,
                createdAt: CLIDateParser.date(from: config["creationDate"] ?? config["createdAt"]) ?? Date(),
                attachedContainers: []
            )
        }
    }

    /// Parses `container network list --format json`.
    static func networks(fromJSON data: Data) -> [NetworkItem]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            let name = (entry["id"] as? String) ?? (dig(entry, "config", "id") as? String) ?? (entry["name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let status = entry["status"] as? [String: Any]
            return NetworkItem(
                name: name,
                mode: (dig(entry, "configuration", "mode") as? String) ?? (dig(entry, "config", "mode") as? String) ?? (entry["mode"] as? String) ?? "",
                subnet: (status?["ipv4Subnet"] as? String) ?? (status?["address"] as? String) ?? (entry["subnet"] as? String) ?? "",
                gateway: (status?["ipv4Gateway"] as? String) ?? (status?["gateway"] as? String) ?? (entry["gateway"] as? String) ?? "",
                dnsDomain: "",
                interfaceName: "",
                ipv6Enabled: (status?["ipv6Subnet"] as? String) != nil,
                connectedContainers: []
            )
        }
    }
}

// MARK: - Docker

struct DockerStatSample: Equatable {
    var name: String
    var cpuPercent: Double
    var memoryUsageBytes: Int64
    var memoryLimitBytes: Int64
    var networkRxBytes: Int64
    var networkTxBytes: Int64
    var blockReadBytes: Int64
    var blockWriteBytes: Int64
    var numProcesses: Int
}

enum DockerParser {
    /// Parses `docker inspect <ids...>` (a JSON array).
    static func containers(fromInspectJSON data: Data) -> [ContainerItem]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            guard let rawName = entry["Name"] as? String else { return nil }
            let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
            guard !name.isEmpty else { return nil }

            var item = ContainerItem.empty(id: name, name: name, backend: .dockerEngine)
            let config = entry["Config"] as? [String: Any] ?? [:]
            let hostConfig = entry["HostConfig"] as? [String: Any] ?? [:]
            let state = entry["State"] as? [String: Any] ?? [:]

            switch ((state["Status"] as? String) ?? "").lowercased() {
            case "running": item.state = .running
            case "paused": item.state = .paused
            case "restarting": item.state = .starting
            case "removing": item.state = .stopping
            default: item.state = .stopped
            }

            item.image = (config["Image"] as? String) ?? ""
            item.os = (entry["Platform"] as? String) ?? "linux"
            item.env = environmentDictionary((config["Env"] as? [String]) ?? [])
            item.labels = (config["Labels"] as? [String: String]) ?? [:]
            item.composeProject = item.labels["com.docker.compose.project"]
            item.command = ShellWords.join(([(entry["Path"] as? String) ?? ""] + ((entry["Args"] as? [String]) ?? [])).filter { !$0.isEmpty })

            if let nanoCPUs = int64Value(hostConfig["NanoCpus"]), nanoCPUs > 0 {
                item.cpuLimitCores = max(1, Int((Double(nanoCPUs) / 1_000_000_000).rounded(.up)))
            }
            item.memoryLimitBytes = int64Value(hostConfig["Memory"]) ?? 0

            if let created = CLIDateParser.date(from: entry["Created"]) {
                item.createdAt = created
            }
            if item.state == .running {
                item.startedAt = CLIDateParser.date(from: state["StartedAt"])
            }

            let networks = dig(entry, "NetworkSettings", "Networks") as? [String: Any] ?? [:]
            if let networkName = networks.keys.sorted().first, let network = networks[networkName] as? [String: Any] {
                item.networkName = networkName
                item.ipAddress = (network["IPAddress"] as? String) ?? ""
                item.macAddress = (network["MacAddress"] as? String) ?? ""
            }
            item.domainName = (config["Hostname"] as? String) ?? ""

            let ports = dig(entry, "NetworkSettings", "Ports") as? [String: Any] ?? [:]
            for key in ports.keys.sorted() {
                guard let bindings = ports[key] as? [[String: Any]] else { continue }
                let pieces = key.components(separatedBy: "/")
                guard let containerPort = Int(pieces[0]) else { continue }
                let transport = pieces.count > 1 ? pieces[1].lowercased() : "tcp"
                for binding in bindings {
                    guard let hostPort = intValue(binding["HostPort"]) else { continue }
                    let hostIP = (binding["HostIp"] as? String) ?? "0.0.0.0"
                    // Docker reports one binding per address family; keep the IPv4 one.
                    if hostIP.contains(":") && item.ports.contains(where: { $0.hostPort == hostPort && $0.containerPort == containerPort }) {
                        continue
                    }
                    item.ports.append(ComposeOrchestrator.makePort(
                        hostIP: hostIP.isEmpty || hostIP == "::" ? "0.0.0.0" : hostIP,
                        hostPort: hostPort,
                        containerPort: containerPort,
                        explicitProtocol: transport == "udp" ? "udp" : nil
                    ))
                }
            }

            for mount in (entry["Mounts"] as? [[String: Any]]) ?? [] {
                guard let destination = mount["Destination"] as? String else { continue }
                let type = (mount["Type"] as? String) ?? "bind"
                let source = type == "volume" ? ((mount["Name"] as? String) ?? "") : ((mount["Source"] as? String) ?? "")
                item.mounts.append(VolumeMount(
                    type: type,
                    source: source,
                    destination: destination,
                    readOnly: (mount["RW"] as? Bool) == false
                ))
            }
            return item
        }
    }

    /// Parses `docker stats --no-stream --format json` (one JSON object per line).
    static func stats(fromJSONLines text: String) -> [DockerStatSample] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = entry["Name"] as? String else { return nil }
            let memory = pair(entry["MemUsage"] as? String)
            let network = pair(entry["NetIO"] as? String)
            let block = pair(entry["BlockIO"] as? String)
            let cpuText = ((entry["CPUPerc"] as? String) ?? "").replacingOccurrences(of: "%", with: "")
            return DockerStatSample(
                name: name,
                cpuPercent: Double(cpuText) ?? 0,
                memoryUsageBytes: memory.0,
                memoryLimitBytes: memory.1,
                networkRxBytes: network.0,
                networkTxBytes: network.1,
                blockReadBytes: block.0,
                blockWriteBytes: block.1,
                numProcesses: Int((entry["PIDs"] as? String) ?? "") ?? 0
            )
        }
    }

    private static func pair(_ text: String?) -> (Int64, Int64) {
        let parts = (text ?? "").components(separatedBy: "/").map { parseSize($0) }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
    }

    /// Parses Docker's human-readable sizes: `3.9MiB`, `1.05kB`, `7.75GiB`, `0B`.
    static func parseSize(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(numberPart) else { return 0 }
        let multiplier: Double
        switch trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).lowercased() {
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        case "kib": multiplier = 1024
        case "mib": multiplier = 1024 * 1024
        case "gib": multiplier = 1024 * 1024 * 1024
        case "tib": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }
}
