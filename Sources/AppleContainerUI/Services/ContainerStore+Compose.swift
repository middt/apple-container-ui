import Foundation
import AppKit

// Compose stacks: parsing, deployment and teardown on either engine.
extension ContainerStore {

    /// Re-parses a stack's YAML and stores services, network, volume names and everything Vessel could not honour.
    /// A file that yields no services (e.g. while it is being edited) keeps the previous service list.
    func reparseStack(at idx: Int) {
        let parsed = ComposeOrchestrator.parse(yaml: stacks[idx].yamlContent, baseDirectory: stacks[idx].baseDirectory)
        if !parsed.services.isEmpty {
            stacks[idx].services = parsed.services
        }

        // Compose naming: an external or explicitly named network keeps its name, otherwise `<stack>_<key>`.
        if let key = parsed.networkKey {
            stacks[idx].networkName = parsed.networkExplicitName ?? (parsed.networkIsExternal ? key : "\(stacks[idx].name)_\(key)")
        } else {
            stacks[idx].networkName = "\(stacks[idx].name)_default"
        }
        stacks[idx].networkIsExternal = parsed.networkIsExternal
        stacks[idx].volumeNames = parsed.fixedVolumeNames

        var warnings = parsed.warnings
        if stacks[idx].targetBackend == .appleContainer {
            warnings += ComposeOrchestrator.appleContainerLimitations(for: stacks[idx].services)
            if dnsDomain == nil, appleRuntime.isAvailable, engineState == .running, stacks[idx].services.count > 1 {
                warnings.append("No local DNS domain exists, so these services cannot reach each other by name. Run once in a terminal: sudo container system dns create vessel.test")
            }
        }
        stacks[idx].warnings = warnings
    }

    func updateStackYAML(stackID: String, newYAML: String) {
        guard let idx = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        stacks[idx].yamlContent = newYAML
        reparseStack(at: idx)
        persistStacks()
    }

    func updateStackBackend(stackID: String, backend: RuntimeBackend) {
        guard let idx = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        stacks[idx].targetBackend = backend
        reparseStack(at: idx)
        persistStacks()
    }

    /// The commands "Stack Up" will run for this stack on `apple/container`.
    func executionPlan(for stack: ComposeStackItem) -> [ComposePlanStep] {
        let existing = Set(containers.filter { $0.backend == .appleContainer }.map { $0.name })
        return ComposeOrchestrator.buildAppleContainerPlan(for: stack, existingContainerNames: existing, dnsDomain: dnsDomain)
    }

    /// Docker Compose project names must be lowercase alphanumerics, `-` and `_`.
    static func dockerProjectName(_ name: String) -> String {
        let mapped = name.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" || ch == "_" ? ch : "-"
        }
        let trimmed = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "vessel-stack" : trimmed
    }

    /// Writes the stack's YAML where `docker compose` can read it and returns the `compose` prefix arguments.
    private func dockerComposeArguments(for stack: ComposeStackItem) throws -> [String] {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("vessel-stacks/\(Self.dockerProjectName(stack.name))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let composeFile = (directory as NSString).appendingPathComponent("docker-compose.yml")
        try ComposeOrchestrator.dockerCompatibleYAML(stack.yamlContent).write(toFile: composeFile, atomically: true, encoding: .utf8)

        var arguments = ["compose", "--project-name", Self.dockerProjectName(stack.name)]
        // Relative paths in the file (bind mounts, env_file, build contexts) must resolve
        // against the original location, not the temporary copy.
        if let base = stack.baseDirectory, FileManager.default.fileExists(atPath: base) {
            arguments += ["--project-directory", base]
        }
        arguments += ["--file", composeFile]
        return arguments
    }

    @discardableResult
    func deployStack(_ stack: ComposeStackItem) -> Task<Void, Never> {
        guard let stackIndex = stacks.firstIndex(where: { $0.id == stack.id }) else { return Task {} }
        reparseStack(at: stackIndex)
        let current = stacks[stackIndex]
        let previousStatus = current.status
        guard previousStatus != .starting, previousStatus != .stopping else { return Task {} }
        guard !current.services.isEmpty else {
            errorBanner = t("This Compose file defines no services.", "Bu Compose dosyasında servis tanımlı değil.")
            return Task {}
        }
        stacks[stackIndex].status = .starting

        for service in current.services {
            let name = ComposeOrchestrator.containerName(stackName: current.name, service: service)
            for port in service.ports where port.isHTTPService {
                portProtocolHints["\(name)|\(port.hostPort)"] = port.protocolType
            }
        }

        return Task {
            let backend = current.targetBackend
            let succeeded = await withBusyLabel(t("Deploying \(current.name)…", "\(current.name) dağıtılıyor…")) {
                await self.runStackUp(current)
            }

            guard let idx = stacks.firstIndex(where: { $0.id == current.id }) else { return }
            if succeeded {
                if backend == .dockerEngine { noteDockerCommandSucceeded() }
                stacks[idx].status = .running
                stacks[idx].lastDeployedAt = Date()
                await settle()
            } else {
                // A failed plan may have started some services: read the real state back.
                stacks[idx].status = previousStatus == .running ? .running : .stopped
                await settle()
            }
        }
    }

    private func runStackUp(_ stack: ComposeStackItem) async -> Bool {
        switch stack.targetBackend {
        case .dockerEngine:
            do {
                let prefix = try dockerComposeArguments(for: stack)
                return await perform(.dockerEngine, prefix + ["up", "--detach"], timeout: 1800).succeeded
            } catch {
                errorBanner = t(
                    "Could not write the Compose file: \(error.localizedDescription)",
                    "Compose dosyası yazılamadı: \(error.localizedDescription)"
                )
                return false
            }

        case .appleContainer:
            let workingDirectory = stack.baseDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            for step in executionPlan(for: stack) {
                switch step.kind {
                case .command:
                    let result = await perform(
                        .appleContainer,
                        step.arguments,
                        workingDirectory: workingDirectory,
                        timeout: 1800,
                        reportFailure: !step.allowFailure
                    )
                    if !result.succeeded && !step.allowFailure {
                        return false
                    }
                case .waitHealthy(let container, let timeout):
                    guard await waitUntilHealthy(container: container, probe: step.arguments, timeoutSeconds: timeout) else { return false }
                case .waitExited(let container, let timeout):
                    guard await waitUntilExited(container: container, timeoutSeconds: timeout) else { return false }
                }
            }
            return true
        }
    }

    /// Emulates Compose's `condition: service_healthy`: runs the dependency's healthcheck inside
    /// it with `container exec` until it succeeds. Only the outcome is recorded in the audit log.
    private func waitUntilHealthy(container: String, probe: [String], timeoutSeconds: Int) async -> Bool {
        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(timeoutSeconds))
        var last = CLIExecutionResult(command: appleRuntime.displayCommand(probe), stdout: "", stderr: "not attempted", exitCode: 1, durationMs: 1)

        return await withBusyLabel(t("Waiting for \(container) to become healthy…", "\(container) sağlıklı olana dek bekleniyor…")) {
            while true {
                last = await appleRuntime.run(probe, timeout: 30)
                if last.succeeded || Date() >= deadline { break }
                try? await Task.sleep(nanoseconds: healthPollNanoseconds)
            }
            let waited = max(1, Int(Date().timeIntervalSince(started) * 1000))
            recordCommand(
                command: last.command,
                durationMs: waited,
                exitCode: last.exitCode,
                outputPreview: last.succeeded ? "\(container) is healthy" : "\(container) did not become healthy within \(timeoutSeconds)s"
            )
            if !last.succeeded {
                errorBanner = "\(container) did not become healthy within \(timeoutSeconds)s\n\(last.command)\n\(String(last.failureMessage.prefix(300)))"
            }
            return last.succeeded
        }
    }

    /// Emulates Compose's `condition: service_completed_successfully` for one-shot jobs (migrators,
    /// seeders): waits until the container has stopped. apple/container does not report exit
    /// codes, so "completed" is all Vessel can verify — check the job's logs if in doubt.
    private func waitUntilExited(container: String, timeoutSeconds: Int) async -> Bool {
        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(timeoutSeconds))

        return await withBusyLabel(t("Waiting for \(container) to finish…", "\(container) bitene dek bekleniyor…")) {
            var finished = false
            var missing = false
            while Date() < deadline {
                let list = await appleRuntime.run(["list", "--all", "--format", "json"], timeout: 30)
                if list.succeeded, let items = AppleContainerParser.containers(fromJSON: Data(list.stdout.utf8)) {
                    guard let item = items.first(where: { $0.name == container }) else {
                        missing = true
                        break
                    }
                    if item.state == .stopped {
                        finished = true
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: healthPollNanoseconds)
            }
            recordCommand(
                command: "# wait until \(container) has finished",
                durationMs: max(1, Int(Date().timeIntervalSince(started) * 1000)),
                exitCode: finished ? 0 : 1,
                outputPreview: finished ? "\(container) finished" : (missing ? "\(container) does not exist" : "\(container) was still running after \(timeoutSeconds)s")
            )
            if !finished {
                errorBanner = missing
                    ? "\(container) does not exist, so the services that wait for it were not started."
                    : "\(container) was still running after \(timeoutSeconds)s, so the services that wait for it were not started."
            }
            return finished
        }
    }

    /// Takes a stack down: `docker compose down`, or stop + delete of its containers on `apple/container`.
    @discardableResult
    func stopStack(_ stack: ComposeStackItem) -> Task<Void, Never> {
        guard let stackIndex = stacks.firstIndex(where: { $0.id == stack.id }) else { return Task {} }
        let current = stacks[stackIndex]
        let previousStatus = current.status
        guard previousStatus != .starting, previousStatus != .stopping else { return Task {} }
        stacks[stackIndex].status = .stopping

        return Task {
            let backend = current.targetBackend
            var succeeded = true

            switch backend {
            case .dockerEngine:
                succeeded = await perform(
                    .dockerEngine,
                    ["compose", "--project-name", Self.dockerProjectName(current.name), "down"],
                    timeout: 600
                ).succeeded
            case .appleContainer:
                for step in ComposeOrchestrator.buildAppleContainerTeardownPlan(for: current) {
                    let result = await perform(.appleContainer, step.arguments, timeout: 600, reportFailure: !step.allowFailure)
                    if !result.succeeded && !step.allowFailure {
                        succeeded = false
                        break
                    }
                }
            }

            guard let idx = stacks.firstIndex(where: { $0.id == current.id }) else { return }
            stacks[idx].status = succeeded ? .stopped : previousStatus
            await settle()
        }
    }

    func importComposeFileFromDisk() {
        let panel = NSOpenPanel()
        panel.title = t("Import docker-compose.yml / compose.yaml", "docker-compose.yml / compose.yaml içe aktar")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importComposeFile(at: url)
    }

    func importComposeFile(at url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            errorBanner = t("Could not read \(url.path)", "\(url.path) okunamadı")
            return
        }
        let folderName = Self.dockerProjectName(url.deletingLastPathComponent().lastPathComponent)
        var stackID = folderName
        var suffix = 2
        while stacks.contains(where: { $0.id == stackID }) {
            stackID = "\(folderName)-\(suffix)"
            suffix += 1
        }

        stacks.insert(ComposeStackItem(
            id: stackID,
            name: stackID,
            filePath: url.path,
            yamlContent: content,
            targetBackend: .appleContainer,
            status: .stopped,
            services: [],
            networkName: "\(stackID)_default",
            lastDeployedAt: nil
        ), at: 0)
        reparseStack(at: 0)
        selectedStackID = stackID
        selectedSidebar = .stacks
        persistStacks()
        updateStackStatuses()
    }

    func removeStack(_ stack: ComposeStackItem) {
        stacks.removeAll { $0.id == stack.id }
        if selectedStackID == stack.id {
            selectedStackID = stacks.first?.id
        }
        persistStacks()
    }
}
