import SwiftUI
import AppKit
import Darwin

@main
struct AppleContainerUIApp: App {
    @StateObject private var store = ContainerStore()

    init() {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        // Filter out macOS LaunchServices / AppKit automatic flags (-psn_*, -NS*, -Apple*)
        let cliArgs = rawArgs.filter { arg in
            !arg.hasPrefix("-psn_") && !arg.hasPrefix("-NS") && !arg.hasPrefix("-Apple")
        }
        if !cliArgs.isEmpty {
            Self.runCLI(arguments: cliArgs)
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Unified `vessel` CLI:
    /// - `vessel stack-up <docker-compose.yml>` / `vessel stack-down <docker-compose.yml>`: Zero-conversion Compose orchestration on `apple/container`.
    /// - `vessel list`, `vessel run ...`, `vessel system start`, `vessel logs ...`, `vessel exec -it ...`: Direct zero-overhead pass-through (`execv`) to `apple/container`.
    @MainActor
    private static func runCLI(arguments: [String]) -> Never {
        let action = arguments[0]

        if action == "--help" || action == "-h" || action == "help" {
            print("""
            Vessel — Native macOS Container Studio & Unified CLI for apple/container

            Compose Orchestration (Zero Conversion):
              vessel stack-up <path/to/docker-compose.yml>     Import & deploy a Compose stack on apple/container
              vessel stack-down <path/to/docker-compose.yml>   Stop & remove a Compose stack on apple/container

            Container & System Commands (Powered by apple/container):
              vessel system start                              Start the background container engine
              vessel system stop                               Stop the background container engine
              vessel system status                             Show engine status
              vessel list [--all]                              List containers
              vessel run [options] <image> [command]           Run a new Linux microVM container
              vessel start <container-id>                      Start a container
              vessel stop <container-id>                       Stop a container
              vessel delete [--force] <container-id>           Delete a container
              vessel logs <container-id>                       View container logs
              vessel exec -it <container-id> /bin/sh           Open an interactive shell inside a container
              vessel stats                                     Display live container resource usage
              vessel image | volume | network | builder ...    Manage OCI images, volumes, vmnet networks & builder
            """)
            exit(0)
        }

        if ["stack-up", "up", "stack-down", "down"].contains(action) {
            Self.runHeadlessComposeCLI(arguments: arguments)
        }

        // Pass-through any other `vessel <subcommand> ...` directly to the `apple/container` binary via execv
        guard let binary = ContainerCLIService.detectBinaryPath() else {
            FileHandle.standardError.write(Data("Error: apple/container engine ('container') not found. Install it with: brew install --cask container\n".utf8))
            exit(1)
        }

        var cArgs: [UnsafeMutablePointer<CChar>?] = ([binary] + arguments).map { strdup($0) }
        cArgs.append(nil)
        execv(binary, &cArgs)

        // Only reached if execv fails
        perror("execv")
        exit(1)
    }

    @MainActor
    private static func runHeadlessComposeCLI(arguments: [String]) -> Never {
        let action = arguments[0]
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("Usage: vessel \(action) <path/to/docker-compose.yml>\n".utf8))
            exit(1)
        }

        let rawPath = arguments[1]
        let resolvedURL: URL
        if rawPath.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            resolvedURL = URL(fileURLWithPath: cwd).appendingPathComponent(rawPath).standardizedFileURL
        }
        let composePath = resolvedURL.path

        guard FileManager.default.fileExists(atPath: composePath) else {
            FileHandle.standardError.write(Data("Error: Compose file not found at \(composePath)\n".utf8))
            exit(1)
        }

        guard let binary = ContainerCLIService.detectBinaryPath() else {
            FileHandle.standardError.write(Data("Error: apple/container CLI ('container') not found. Install it with: brew install --cask container\n".utf8))
            exit(1)
        }

        let sema = DispatchSemaphore(value: 0)
        var exitStatus: Int32 = 0

        Task { @MainActor in
            let store = ContainerStore(
                settings: AppSettings(),
                appleRuntime: LiveCLIRuntime(backend: .appleContainer, path: binary),
                dockerRuntime: ContainerCLIService.detectDockerBinaryPath().map { LiveCLIRuntime(backend: .dockerEngine, path: $0) }
                    ?? UnavailableRuntime(backend: .dockerEngine),
                enableBackgroundServices: false
            )
            await store.refreshFromLiveCLI(userInitiated: true)
            guard store.engineState == .running else {
                FileHandle.standardError.write(Data("Error: apple/container system is not running. Start it first with: vessel system start\n".utf8))
                exitStatus = 1
                sema.signal()
                return
            }

            if let existing = store.stacks.first(where: { $0.filePath == composePath }),
               let yaml = try? String(contentsOfFile: composePath, encoding: .utf8) {
                store.updateStackYAML(stackID: existing.id, newYAML: yaml)
            } else {
                store.importComposeFile(at: resolvedURL)
            }

            guard let stack = store.stacks.first(where: { $0.filePath == composePath }) else {
                FileHandle.standardError.write(Data("Error: Failed to parse Compose stack at \(composePath)\n".utf8))
                exitStatus = 1
                sema.signal()
                return
            }

            if action == "stack-down" || action == "down" {
                print("==> [Vessel] Stopping stack '\(stack.name)' (\(stack.services.count) services) on apple/container...")
                await store.stopStack(stack).value
            } else {
                print("==> [Vessel] Deploying stack '\(stack.name)' (\(stack.services.count) services, network: \(stack.networkName)) on apple/container...")
                for warning in stack.warnings {
                    print("    warning: \(warning)")
                }
                await store.deployStack(stack).value
            }

            for entry in store.commandLog.reversed() where entry.command.hasPrefix("container ") || entry.command.hasPrefix("#") || entry.exitCode != 0 {
                let displayCmd = entry.command.hasPrefix("container ")
                    ? "vessel " + String(entry.command.dropFirst("container ".count))
                    : entry.command
                print("    [exit \(entry.exitCode), \(entry.durationMs)ms] \(displayCmd)")
            }

            if let err = store.errorBanner {
                FileHandle.standardError.write(Data("Error: \(err)\n".utf8))
                exitStatus = 1
            } else {
                print("==> [Vessel] Done!")
            }
            sema.signal()
        }

        while sema.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        exit(exitStatus)
    }

    var body: some Scene {
        WindowGroup("Vessel — Apple Container Studio") {
            MainWindowView(store: store)
                .frame(minWidth: 1080, idealWidth: 1280, minHeight: 680, idealHeight: 800)
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandMenu("Containers") {
                Button("Run New Container MicroVM…") {
                    store.showNewContainerSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Refresh Containers & Telemetry") {
                    Task {
                        await store.refreshAll()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    Button("Switch to \(item.rawValue)") {
                        store.selectedSidebar = item
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                }
            }
        }

        MenuBarExtra("Vessel", systemImage: "shippingbox.fill") {
            MenuBarTrayView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
