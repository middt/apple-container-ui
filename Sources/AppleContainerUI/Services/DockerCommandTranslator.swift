import Foundation

/// Translates `docker ...` command lines into their `apple/container` equivalents.
///
/// The command is tokenised like a shell would, so flag position, attached values (`-p8080:80`),
/// `--flag=value`, combined short flags (`-dit`) and quoted arguments are all handled.
/// Flags without an `apple/container` equivalent are dropped and listed in a trailing `#` note.
enum DockerCommandTranslator {
    struct Translation: Equatable {
        var arguments: [String]
        var dropped: [String] = []
        var message: String? = nil
    }

    /// `docker run` flags that take a value, mapped to the `container run` flag.
    private static let valueFlags: [String: String] = [
        "-p": "--publish", "--publish": "--publish",
        "-v": "--volume", "--volume": "--volume",
        "-e": "--env", "--env": "--env",
        "--env-file": "--env-file",
        "--name": "--name",
        "-m": "--memory", "--memory": "--memory",
        "--cpus": "--cpus",
        "-w": "--workdir", "--workdir": "--workdir",
        "-u": "--user", "--user": "--user",
        "--entrypoint": "--entrypoint",
        "-l": "--label", "--label": "--label",
        "--network": "--network", "--net": "--network",
        "--platform": "--platform",
        "--mount": "--mount",
        "--tmpfs": "--tmpfs",
        "--dns": "--dns",
        "--dns-search": "--dns-search",
        "--dns-option": "--dns-option", "--dns-opt": "--dns-option",
        "--cap-add": "--cap-add",
        "--cap-drop": "--cap-drop",
        "--cidfile": "--cidfile",
        "--ulimit": "--ulimit",
        "--shm-size": "--shm-size"
    ]

    /// `docker run` boolean flags, mapped to the `container run` flag.
    private static let booleanFlags: [String: String] = [
        "-d": "--detach", "--detach": "--detach",
        "-i": "--interactive", "--interactive": "--interactive",
        "-t": "--tty", "--tty": "--tty",
        "--rm": "--rm",
        "--read-only": "--read-only",
        "--init": "--init"
    ]

    /// Docker flags with a value that `apple/container` cannot express.
    private static let unsupportedValueFlags: Set<String> = [
        "--restart", "-h", "--hostname", "--link", "--health-cmd", "--health-interval", "--health-retries",
        "--health-timeout", "--health-start-period", "--log-driver", "--log-opt", "--add-host", "--pull",
        "--gpus", "--cpu-shares", "-c", "--cpuset-cpus", "--memory-swap", "--memory-reservation", "--pid",
        "--ipc", "--device", "--expose", "--security-opt", "--stop-signal", "--stop-timeout",
        "--network-alias", "--ip", "--ip6", "--mac-address", "--volumes-from", "--sysctl", "--userns",
        "--detach-keys", "--runtime", "--group-add", "-a", "--attach", "--isolation", "--domainname",
        "--pids-limit", "--blkio-weight", "--cgroup-parent", "--uts", "--volume-driver", "--annotation"
    ]

    /// Docker boolean flags that `apple/container` cannot express.
    private static let unsupportedBooleanFlags: Set<String> = [
        "--privileged", "-P", "--publish-all", "--oom-kill-disable", "--no-healthcheck", "--sig-proxy", "-q", "--quiet"
    ]

    /// Human-readable translation used by the UI: the command, plus a `#` note for dropped flags.
    static func translate(_ dockerCommand: String) -> String {
        let translation = translateToArguments(dockerCommand)
        if let message = translation.message {
            return message
        }
        var text = ShellWords.join(translation.arguments)
        if !translation.dropped.isEmpty {
            text += "\n# Not supported by apple/container (dropped): " + translation.dropped.joined(separator: ", ")
        }
        return text
    }

    static func translateToArguments(_ dockerCommand: String) -> Translation {
        var tokens = ShellWords.split(dockerCommand)
        if tokens.first == "sudo" {
            tokens.removeFirst()
        }
        guard let first = tokens.first else {
            return Translation(arguments: [], message: "")
        }

        if first == "docker-compose" || (first == "docker" && tokens.dropFirst().first == "compose") {
            return Translation(
                arguments: [],
                message: "# Compose files run directly on apple/container: import the file in the 'Compose Stacks' tab."
            )
        }
        if first == "container" {
            return Translation(arguments: tokens)
        }
        if first == "docker" {
            tokens.removeFirst()
        }
        guard let subcommand = tokens.first else {
            return Translation(arguments: ["container"])
        }
        let rest = Array(tokens.dropFirst())

        switch subcommand {
        case "run", "create":
            var translation = translateRun(rest)
            translation.arguments = ["container", subcommand] + translation.arguments
            return translation
        case "container":
            // `docker container run ...` -> same as `docker run ...`
            return translateToArguments(ShellWords.join(["docker"] + rest))
        case "ps":
            return Translation(arguments: ["container", "list"] + rest)
        case "images":
            return Translation(arguments: ["container", "image", "list"] + rest)
        case "pull", "push", "tag", "save", "load":
            return Translation(arguments: ["container", "image", subcommand] + rest)
        case "rmi":
            return Translation(arguments: ["container", "image", "delete"] + rest)
        case "rm":
            return Translation(arguments: ["container", "delete"] + rest)
        case "image":
            var imageArguments = rest
            if let verb = imageArguments.first {
                let mapped = ["ls": "list", "rm": "delete"][verb] ?? verb
                imageArguments[0] = mapped
            }
            return Translation(arguments: ["container", "image"] + imageArguments)
        case "logs":
            return Translation(arguments: ["container", "logs"] + translateLogsFlags(rest))
        case "restart":
            guard !rest.isEmpty else {
                return Translation(arguments: ["container"], message: "# apple/container has no restart command; use: container stop <id> && container start <id>")
            }
            let targets = rest.filter { !$0.hasPrefix("-") }
            return Translation(
                arguments: [],
                message: ShellWords.join(["container", "stop"] + targets) + " && "
                    + targets.map { ShellWords.join(["container", "start", $0]) }.joined(separator: " && ")
            )
        case "version":
            return Translation(arguments: ["container", "system", "version"] + rest)
        case "info":
            return Translation(arguments: ["container", "system", "status"] + rest)
        default:
            // start, stop, kill, exec, inspect, build, stats, network, volume, ... share the same shape.
            return Translation(arguments: ["container", subcommand] + rest)
        }
    }

    private static func translateLogsFlags(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--tail", index + 1 < arguments.count {
                result += ["-n", arguments[index + 1]]
                index += 2
            } else if argument.hasPrefix("--tail=") {
                result += ["-n", String(argument.dropFirst("--tail=".count))]
                index += 1
            } else {
                result.append(argument)
                index += 1
            }
        }
        return result
    }

    private static func translateRun(_ tokens: [String]) -> Translation {
        var output: [String] = []
        var dropped: [String] = []
        var index = 0

        func emit(_ flag: String, _ value: String) {
            output += [flag, flag == "--memory" ? normalizedMemory(value) : value]
        }

        while index < tokens.count {
            let token = tokens[index]

            // First non-flag token is the image; everything after it is the container command.
            guard token.hasPrefix("-"), token != "-", token != "--" else {
                if token == "--" { index += 1 }
                output += tokens[index...]
                break
            }

            if token.hasPrefix("--") {
                if let equals = token.firstIndex(of: "=") {
                    let name = String(token[..<equals])
                    let value = String(token[token.index(after: equals)...])
                    if let mapped = valueFlags[name] {
                        emit(mapped, value)
                    } else if let mapped = booleanFlags[name] {
                        if value.lowercased() != "false" { output.append(mapped) }
                    } else {
                        dropped.append(name)
                    }
                    index += 1
                } else if let mapped = valueFlags[token] {
                    if index + 1 < tokens.count { emit(mapped, tokens[index + 1]) }
                    index += 2
                } else if let mapped = booleanFlags[token] {
                    output.append(mapped)
                    index += 1
                } else if unsupportedValueFlags.contains(token) {
                    dropped.append(token)
                    index += 2
                } else {
                    // Unknown or unsupported boolean flag.
                    dropped.append(token)
                    index += 1
                }
                continue
            }

            // Short flags: `-d`, `-dit`, `-p 80:80`, `-p80:80`, `-itp 80:80`.
            let letters = Array(token.dropFirst())
            var letterIndex = 0
            var consumedNextToken = false
            while letterIndex < letters.count {
                let short = "-" + String(letters[letterIndex])
                let attached = String(letters[(letterIndex + 1)...])
                if let mapped = booleanFlags[short] {
                    output.append(mapped)
                    letterIndex += 1
                } else if let mapped = valueFlags[short] {
                    if !attached.isEmpty {
                        emit(mapped, attached)
                    } else if index + 1 < tokens.count {
                        emit(mapped, tokens[index + 1])
                        consumedNextToken = true
                    }
                    break
                } else if unsupportedValueFlags.contains(short) {
                    dropped.append(short)
                    if attached.isEmpty { consumedNextToken = true }
                    break
                } else {
                    dropped.append(short)
                    letterIndex += 1
                }
            }
            index += consumedNextToken ? 2 : 1
        }

        return Translation(arguments: output, dropped: dropped)
    }

    /// Docker accepts lowercase unit suffixes (`512m`); `container` documents uppercase ones.
    private static func normalizedMemory(_ value: String) -> String {
        guard let last = value.last, last.isLetter else { return value }
        let digits = value.prefix { $0.isNumber || $0 == "." }
        let unit = value.dropFirst(digits.count).uppercased()
        let normalizedUnit = unit.hasSuffix("B") && unit.count > 1 ? String(unit.dropLast()) : unit
        return digits + normalizedUnit
    }
}
