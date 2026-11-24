import Foundation

/// The single seam between Vessel and a container engine.
///
/// `ContainerStore` never spawns processes itself: every command goes through a `ContainerRuntime`.
/// - `LiveCLIRuntime` runs the real `container` / `docker` binary.
/// - `UnavailableRuntime` stands in for a CLI that is not installed; every command fails with a clear message.
/// Tests inject their own implementation.
///
/// The store only commits a state change after the runtime reports success, and then re-reads
/// the real state from the CLI.
protocol ContainerRuntime: Sendable {
    var backend: RuntimeBackend { get }
    /// CLI name used when rendering commands (`container` or `docker`).
    var toolName: String { get }
    var binaryPath: String? { get }

    func run(_ arguments: [String], workingDirectory: String?, timeout: TimeInterval) async -> CLIExecutionResult
}

extension ContainerRuntime {
    func run(_ arguments: [String]) async -> CLIExecutionResult {
        await run(arguments, workingDirectory: nil, timeout: 120)
    }

    func run(_ arguments: [String], timeout: TimeInterval) async -> CLIExecutionResult {
        await run(arguments, workingDirectory: nil, timeout: timeout)
    }

    /// Copy-pasteable rendering of a command for this runtime.
    func displayCommand(_ arguments: [String]) -> String {
        ShellWords.join([toolName] + arguments)
    }
}

extension RuntimeBackend {
    var toolName: String {
        switch self {
        case .appleContainer: return "container"
        case .dockerEngine: return "docker"
        }
    }
}

/// Executes the real CLI binary.
struct LiveCLIRuntime: ContainerRuntime {
    let backend: RuntimeBackend
    let path: String

    var toolName: String { backend.toolName }
    var binaryPath: String? { path }

    func run(_ arguments: [String], workingDirectory: String?, timeout: TimeInterval) async -> CLIExecutionResult {
        await ProcessRunner.run(
            executable: path,
            arguments: arguments,
            displayCommand: displayCommand(arguments),
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }
}

/// Stands in for a CLI binary that is not installed. Nothing is executed.
struct UnavailableRuntime: ContainerRuntime {
    let backend: RuntimeBackend

    var toolName: String { backend.toolName }
    var binaryPath: String? { nil }

    func run(_ arguments: [String], workingDirectory: String?, timeout: TimeInterval) async -> CLIExecutionResult {
        CLIExecutionResult(
            command: displayCommand(arguments),
            stdout: "",
            stderr: "The `\(toolName)` CLI was not found on this Mac.",
            exitCode: 127,
            durationMs: 1
        )
    }
}

extension ContainerRuntime {
    /// False when the CLI binary is missing.
    var isAvailable: Bool { !(self is UnavailableRuntime) }
}
