import Foundation
import AppKit

struct CLIExecutionResult: Sendable {
    /// Display form of the command, including the tool name (e.g. `docker compose up -d`).
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let durationMs: Int

    var succeeded: Bool { exitCode == 0 }

    /// Best human-readable explanation of a failure (stderr first, then stdout).
    var failureMessage: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return "exit code \(exitCode)"
    }
}

/// Runs a child process without blocking the caller and without deadlocking on large output.
enum ProcessRunner {
    /// Collects pipe output from a background queue.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func set(_ newData: Data) {
            lock.lock()
            data = newData
            lock.unlock()
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        displayCommand: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 120
    ) async -> CLIExecutionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = DispatchTime.now()
                func elapsedMs() -> Int {
                    max(1, Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000))
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let workingDirectory, !workingDirectory.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                }

                var env = ProcessInfo.processInfo.environment
                let basePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                if let existing = env["PATH"], !existing.isEmpty {
                    env["PATH"] = existing + ":" + basePath
                } else {
                    env["PATH"] = basePath
                }
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                // Never let a child wait for input that will not come.
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CLIExecutionResult(
                        command: displayCommand,
                        stdout: "",
                        stderr: error.localizedDescription,
                        exitCode: -1,
                        durationMs: elapsedMs()
                    ))
                    return
                }

                // Drain both pipes concurrently *while* the process runs. Reading only after
                // `waitUntilExit()` deadlocks as soon as the child fills the ~64 KB pipe buffer.
                let outBox = OutputBox()
                let errBox = OutputBox()
                let group = DispatchGroup()
                let readQueue = DispatchQueue.global(qos: .userInitiated)
                group.enter()
                readQueue.async {
                    outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                readQueue.async {
                    errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }

                let timedOut = OutputBox()
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.set(Data([1]))
                        process.terminate()
                    }
                }
                if timeout > 0 {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
                }

                process.waitUntilExit()
                watchdog.cancel()
                group.wait()

                var stderr = errBox.string
                var exitCode = process.terminationStatus
                if !timedOut.string.isEmpty {
                    stderr += (stderr.isEmpty ? "" : "\n") + "Timed out after \(Int(timeout))s and was terminated."
                    if exitCode == 0 { exitCode = -2 }
                }

                continuation.resume(returning: CLIExecutionResult(
                    command: displayCommand,
                    stdout: outBox.string,
                    stderr: stderr,
                    exitCode: exitCode,
                    durationMs: elapsedMs()
                ))
            }
        }
    }
}

/// Binary discovery and Terminal.app integration for the `container` and `docker` CLIs.
enum ContainerCLIService {
    static let candidatePaths: [String] = [
        "/usr/local/bin/container",
        "/opt/homebrew/bin/container",
        "/usr/bin/container",
        NSHomeDirectory() + "/.local/bin/container",
        "/Library/Application Support/com.apple.container/bin/container"
    ]

    static let dockerCandidatePaths: [String] = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/usr/bin/docker",
        NSHomeDirectory() + "/.orbstack/bin/docker",
        NSHomeDirectory() + "/.docker/bin/docker"
    ]

    static func detectBinaryPath(customPath: String? = nil) -> String? {
        if let customPath {
            let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        }
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func detectDockerBinaryPath() -> String? {
        dockerCandidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Builds the AppleScript that runs `arguments` in a new Terminal.app window.
    /// Each argument is shell-quoted, then the whole line is embedded as an AppleScript string literal,
    /// so container names or paths containing quotes, spaces or `;` cannot inject commands.
    static func terminalScriptSource(arguments: [String]) -> String {
        let commandLine = ShellWords.join(arguments)
        return """
        tell application "Terminal"
            activate
            do script \(ShellWords.appleScriptLiteral(commandLine))
        end tell
        """
    }

    /// Runs `arguments` in Terminal.app. Returns an error description on failure
    /// (for example when the user denied the Automation permission).
    @MainActor
    @discardableResult
    static func runInTerminal(arguments: [String]) -> String? {
        guard let script = NSAppleScript(source: terminalScriptSource(arguments: arguments)) else {
            return "Could not build the Terminal.app script."
        }
        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)
        if let errorDict {
            return (errorDict[NSAppleScript.errorMessage] as? String) ?? "Terminal.app refused the request."
        }
        return nil
    }
}
