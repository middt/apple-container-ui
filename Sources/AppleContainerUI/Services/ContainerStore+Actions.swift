import Foundation
import AppKit

// User actions. Each one follows the same shape:
//   1. show a transient state (`starting` / `stopping`) where it helps,
//   2. run the command through `perform` (which records it and reports failures),
//   3. `settle` — the real state is re-read from the CLI,
//   4. on failure restore the previous state.
// Actions return their `Task` so tests can await completion; views simply discard it.
extension ContainerStore {

    private func setContainerState(_ id: String, _ state: ContainerState) {
        if let idx = containers.firstIndex(where: { $0.id == id }), containers[idx].state != state {
            containers[idx].state = state
        }
    }

    // MARK: - Confirmations for destructive actions

    /// Deleting a running container kills its workload, so that asks first; a stopped one is removed directly.
    func requestDeleteContainer(_ container: ContainerItem) {
        guard container.state == .running else {
            deleteContainer(id: container.id)
            return
        }
        pendingConfirmation = PendingConfirmation(
            title: t("Delete the running container \(container.name)?", "Çalışan \(container.name) konteyneri silinsin mi?"),
            message: t("It is stopped immediately and removed.", "Hemen durdurulur ve silinir."),
            confirmLabel: t("Delete", "Sil"),
            action: { [weak self] in self?.deleteContainer(id: container.id) }
        )
    }

    func requestDeleteGroup(_ groupID: String) {
        guard let group = group(id: groupID) else { return }
        pendingConfirmation = PendingConfirmation(
            title: t("Delete the group \(group.name)?", "\(group.name) grubu silinsin mi?"),
            message: t(
                "All \(group.containers.count) containers of this Compose project are stopped and removed. Named volumes are kept.",
                "Bu Compose projesinin \(group.containers.count) konteynerinin tümü durdurulup silinir. Adlandırılmış volume'lar korunur."
            ),
            confirmLabel: t("Delete all containers", "Tüm konteynerleri sil"),
            action: { [weak self] in self?.deleteGroup(groupID) }
        )
    }

    func requestDeleteVolume(_ volume: VolumeItem) {
        pendingConfirmation = PendingConfirmation(
            title: t("Delete the volume \(volume.name)?", "\(volume.name) volume'u silinsin mi?"),
            message: t("Its data is lost permanently.", "İçindeki veri kalıcı olarak kaybolur."),
            confirmLabel: t("Delete volume", "Volume'u sil"),
            action: { [weak self] in self?.deleteVolume(volume) }
        )
    }

    /// Stopping the container system stops every container, so that asks first when any is running.
    func requestToggleSystemEngine() {
        guard engineState == .running, runningContainersCount > 0 else {
            toggleSystemEngine()
            return
        }
        pendingConfirmation = PendingConfirmation(
            title: t("Stop the container system?", "Konteyner sistemi durdurulsun mu?"),
            message: t(
                "This stops all \(runningContainersCount) running containers.",
                "Çalışan \(runningContainersCount) konteynerin tümü durur."
            ),
            confirmLabel: t("Stop everything", "Tümünü durdur"),
            action: { [weak self] in self?.toggleSystemEngine() }
        )
    }

    func showCopiedToast(_ text: String) {
        copiedToast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self?.copiedToast == text { self?.copiedToast = nil }
        }
    }

    // MARK: - Container lifecycle

    @discardableResult
    func toggleContainerState(_ container: ContainerItem) -> Task<Void, Never> {
        container.state == .running ? stopContainer(id: container.id) : startContainer(id: container.id)
    }

    @discardableResult
    func startContainer(id: String) -> Task<Void, Never> {
        guard let container = containers.first(where: { $0.id == id }) else { return Task {} }
        let previous = container.state
        setContainerState(id, .starting)
        return Task {
            let result = await perform(container.backend, ["start", container.cliID])
            if result.succeeded {
                await settle()
            } else {
                setContainerState(id, previous)
            }
        }
    }

    @discardableResult
    func stopContainer(id: String) -> Task<Void, Never> {
        guard let container = containers.first(where: { $0.id == id }) else { return Task {} }
        let previous = container.state
        setContainerState(id, .stopping)
        return Task {
            let result = await perform(container.backend, ["stop", container.cliID])
            if result.succeeded {
                await settle()
            } else {
                setContainerState(id, previous)
            }
        }
    }

    /// `apple/container` has no restart command, so a restart is an explicit stop followed by a start.
    @discardableResult
    func restartContainer(id: String) -> Task<Void, Never> {
        guard let container = containers.first(where: { $0.id == id }) else { return Task {} }
        let previous = container.state
        setContainerState(id, .starting)
        return Task {
            let succeeded: Bool
            if container.backend == .dockerEngine {
                succeeded = await perform(.dockerEngine, ["restart", container.cliID]).succeeded
            } else {
                // Stopping an already stopped container is not an error worth aborting for.
                await perform(.appleContainer, ["stop", container.cliID], reportFailure: previous == .running)
                succeeded = await perform(.appleContainer, ["start", container.cliID]).succeeded
            }
            if succeeded {
                await settle()
            } else {
                setContainerState(id, previous)
                await settle()
            }
        }
    }

    @discardableResult
    func deleteContainer(id: String) -> Task<Void, Never> {
        guard let container = containers.first(where: { $0.id == id }) else { return Task {} }
        return Task {
            let arguments = container.backend == .dockerEngine
                ? ["rm", "--force", container.cliID]
                : ["delete", "--force", container.cliID]
            let result = await perform(container.backend, arguments)
            if result.succeeded {
                inspectJSONByContainerID[id] = nil
                await settle()
            }
        }
    }

    @discardableResult
    func createAndRunContainer(
        name: String,
        image: String,
        cpus: Int,
        memoryMB: Int,
        hostPort: Int?,
        containerPort: Int?,
        portProtocol: PortAppProtocol = .http,
        mountSource: String,
        mountDest: String,
        envPairs: [String: String],
        network: String,
        command: String
    ) -> Task<Void, Never> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = trimmedName.isEmpty ? "vm-\(Int.random(in: 100...999))" : trimmedName

        var ports: [PortMapping] = []
        if let hp = hostPort, let cp = containerPort, hp > 0, cp > 0 {
            ports.append(PortMapping(hostIP: "0.0.0.0", hostPort: hp, containerPort: cp, protocolType: portProtocol.rawValue))
        }
        var mounts: [VolumeMount] = []
        if !mountSource.isEmpty && !mountDest.isEmpty {
            mounts.append(VolumeMount(type: "virtiofs", source: mountSource, destination: mountDest, readOnly: false))
        }

        let arguments = runArguments(
            name: cleanName, image: image, cpus: cpus, memoryMB: memoryMB, ports: ports,
            mounts: mounts, envPairs: envPairs, network: network, command: command
        )
        for port in ports where port.isHTTPService {
            portProtocolHints["\(cleanName)|\(port.hostPort)"] = port.protocolType
        }

        return Task {
            let result = await withBusyLabel(t("Starting \(cleanName)…", "\(cleanName) başlatılıyor…")) {
                // The first run of an image includes pulling it.
                await perform(.appleContainer, arguments, timeout: 900)
            }
            guard result.succeeded else { return }
            await settle()
            if let created = containers.first(where: { $0.name == cleanName && $0.backend == .appleContainer }) {
                selectContainer(created.id)
            }
            selectedSidebar = .containers
        }
    }

    // MARK: - Exec, shell, HTTP probe

    @discardableResult
    func runQuickExec(for container: ContainerItem, command: String) -> Task<Void, Never> {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = ShellWords.split(trimmed)
        guard !words.isEmpty else { return Task {} }

        return Task {
            let result = await perform(container.backend, ["exec", container.cliID] + words, timeout: 60, reportFailure: false)
            let combined = [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let output = combined.isEmpty ? "(exit \(result.exitCode), no output)" : combined
            execOutputHistory.append("$ \(result.command)\n\(output)")
            if execOutputHistory.count > 50 {
                execOutputHistory.removeFirst(execOutputHistory.count - 50)
            }
        }
    }

    /// Opens an interactive shell for the container in Terminal.app.
    func openShell(for container: ContainerItem, shell: String = "/bin/sh") {
        let runtime = runtime(for: container.backend)
        guard let binary = runtime.binaryPath else {
            errorBanner = t("The `\(runtime.toolName)` CLI was not found.", "`\(runtime.toolName)` CLI bulunamadı.")
            return
        }
        let arguments = [binary, "exec", "--interactive", "--tty", container.cliID, shell]
        if let error = ContainerCLIService.runInTerminal(arguments: arguments) {
            errorBanner = t("Could not open Terminal.app: \(error)", "Terminal.app açılamadı: \(error)")
        }
    }

    /// Sends a real HTTP request to a published port and shows the actual response.
    @discardableResult
    func testHTTPOutput(for container: ContainerItem, port: PortMapping) -> Task<Void, Never> {
        let isHttpBin = container.name.lowercased().contains("httpbin") || container.image.lowercased().contains("httpbin")
        let scheme = port.appProtocol == .https ? "https" : "http"
        let urlString = "\(scheme)://127.0.0.1:\(String(port.hostPort))\(isHttpBin ? "/get" : "/")"
        let command = "curl -i \(urlString)"
        guard let url = URL(string: urlString) else { return Task {} }

        httpTestResponsePreview = "$ \(command)\n…"
        return Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let started = Date()
            let preview: String
            var exitCode: Int32 = 0
            var summary: String

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let headers = (http?.allHeaderFields ?? [:])
                    .map { "\($0.key): \($0.value)" }
                    .sorted()
                    .joined(separator: "\n")
                var body = String(decoding: data.prefix(4000), as: UTF8.self)
                if data.count > 4000 {
                    body += "\n… (\(data.count) bytes total)"
                }
                summary = "HTTP \(status) — \(data.count) bytes"
                preview = "$ \(command)\nHTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\n\(headers)\n\n\(body)"
            } catch {
                exitCode = 7
                summary = error.localizedDescription
                preview = "$ \(command)\ncurl: (7) \(error.localizedDescription)"
            }

            httpTestResponsePreview = preview
            if exitCode != 0, container.backend == .appleContainer {
                // A reset on a published port is the typical symptom of the denied Local Network permission.
                await verifyPublishedPorts(force: [container.name])
            }
            recordCommand(
                command: command,
                durationMs: max(1, Int(Date().timeIntervalSince(started) * 1000)),
                exitCode: exitCode,
                outputPreview: summary
            )
        }
    }

    // MARK: - Images

    @discardableResult
    func pullImage(reference: String) -> Task<Void, Never> {
        let clean = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Task {} }
        return Task {
            let result = await withBusyLabel(t("Pulling \(clean)…", "\(clean) çekiliyor…")) {
                await perform(.appleContainer, ["image", "pull", clean], timeout: 1800)
            }
            if result.succeeded {
                await settle()
            }
        }
    }

    @discardableResult
    func deleteImage(_ image: ImageItem) -> Task<Void, Never> {
        Task {
            let result = await perform(.appleContainer, ["image", "delete", image.fullReference])
            if result.succeeded {
                await settle()
            }
        }
    }

    // MARK: - Volumes

    @discardableResult
    func createVolume(name: String, sizeGB: Int) -> Task<Void, Never> {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Task {} }
        return Task {
            let result = await perform(.appleContainer, ["volume", "create", "-s", "\(String(sizeGB))G", clean])
            if result.succeeded {
                await settle()
            }
        }
    }

    @discardableResult
    func deleteVolume(_ volume: VolumeItem) -> Task<Void, Never> {
        Task {
            let result = await perform(.appleContainer, ["volume", "delete", volume.name])
            if result.succeeded {
                await settle()
            }
        }
    }

    // MARK: - Networks

    @discardableResult
    func createNetwork(name: String, subnet: String) -> Task<Void, Never> {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSubnet = subnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Task {} }
        var arguments = ["network", "create"]
        if !cleanSubnet.isEmpty {
            arguments += ["--subnet", cleanSubnet]
        }
        arguments.append(clean)

        return Task {
            let result = await perform(.appleContainer, arguments)
            if result.succeeded {
                await settle()
            }
        }
    }

    @discardableResult
    func deleteNetwork(_ network: NetworkItem) -> Task<Void, Never> {
        guard network.name != "default" else { return Task {} }
        return Task {
            let result = await perform(.appleContainer, ["network", "delete", network.name])
            if result.succeeded {
                await settle()
            }
        }
    }

    // MARK: - Engine

    @discardableResult
    func toggleSystemEngine() -> Task<Void, Never> {
        let wasRunning = engineState == .running
        engineState = wasRunning ? .stopping : .starting
        return Task {
            let result = await withBusyLabel(wasRunning
                ? t("Stopping the container system…", "Konteyner sistemi durduruluyor…")
                : t("Starting the container system…", "Konteyner sistemi başlatılıyor…")) {
                // `--enable-kernel-install` answers the first-run kernel prompt, which would otherwise
                // wait for input that a GUI cannot provide.
                await perform(
                    .appleContainer,
                    wasRunning ? ["system", "stop"] : ["system", "start", "--enable-kernel-install"],
                    timeout: 600
                )
            }
            guard result.succeeded else {
                engineState = wasRunning ? .running : .stopped
                return
            }
            engineState = wasRunning ? .stopped : .running
            await settle()
        }
    }
}
