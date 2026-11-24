import Foundation
import SwiftUI
import Combine
import AppKit

/// Central application state.
///
/// The store is split across several files:
/// - `ContainerStore.swift` — state, the `perform` / `settle` command pipeline, telemetry timer
/// - `ContainerStore+Actions.swift` — container / image / volume / network / engine actions
/// - `ContainerStore+Groups.swift` — Compose project groups and their bulk actions
/// - `ContainerStore+Compose.swift` — Compose stack deployment
/// - `ContainerStore+Live.swift` — reading real state back from the `container` and `docker` CLIs
///
/// Every command goes through a `ContainerRuntime`. State only changes after the runtime reports
/// success, and is then re-read from the CLI.
@MainActor
final class ContainerStore: ObservableObject {
    // Localization (auto-detects the macOS system language until the user picks one)
    @Published var language: AppLanguage {
        didSet { settings.language = language }
    }

    func t(_ en: String, _ tr: String) -> String {
        language == .tr ? tr : en
    }

    // Navigation & Selection
    @Published var selectedSidebar: SidebarItem = .containers
    @Published var selectedContainerID: String?
    /// When set, the detail pane shows the dashboard of this Compose group instead of a container.
    @Published var selectedGroupID: String?
    @Published var collapsedGroupIDs: Set<String> = []
    /// Destructive action waiting for confirmation (shown as a dialog by `MainWindowView`).
    @Published var pendingConfirmation: PendingConfirmation?
    @Published var selectedDetailTab: ContainerDetailTab = .stats
    @Published var containerFilter: ContainerFilterState = .all
    @Published var searchText: String = ""
    @Published var showNewContainerSheet: Bool = false

    // Inspector UI State
    @Published var logSearchText: String = ""
    @Published var showEnvValues: Bool = true
    @Published var copiedToast: String?
    @Published var httpTestResponsePreview: String = ""
    /// Real `container inspect` / `docker inspect` output, keyed by container id (live backends only).
    @Published var inspectJSONByContainerID: [String: String] = [:]

    // Resource Creation Form Inputs
    @Published var pullRefInput: String = "alpine:3.21"
    @Published var newVolumeName: String = ""
    @Published var newVolumeSizeGB: Int = 5
    @Published var newNetName: String = ""
    @Published var newNetSubnet: String = "192.168.70.0/24"

    // New Container Sheet Form State
    @Published var newContainerName: String = "web-service"
    @Published var newContainerImage: String = "nginx:1.27-alpine"
    @Published var newContainerCPUs: Int = 2
    @Published var newContainerMemoryMB: Int = 1024
    @Published var newContainerHostPort: String = "8090"
    @Published var newContainerTargetPort: String = "80"
    @Published var newContainerPortProtocol: PortAppProtocol = .http
    @Published var newContainerMountSource: String = ""
    @Published var newContainerMountDest: String = "/workspace"
    @Published var newContainerEnvKey: String = "APP_ENV"
    @Published var newContainerEnvValue: String = "production"
    @Published var newContainerNetwork: String = "default"
    @Published var newContainerCommand: String = ""

    // Engine & CLI State
    @Published var customBinaryPath: String = ""
    @Published var detectedBinaryPath: String?
    @Published var detectedDockerPath: String?
    @Published var engineState: ContainerState = .stopped
    @Published var engineVersion: String = ""
    @Published var hostArch: String = "arm64 (Apple Silicon)"
    @Published var statusBannerMessage: String?
    /// Local DNS domain created with `sudo container system dns create <domain>`, if any.
    /// Compose services can only reach each other by name when one exists.
    @Published var dnsDomain: String?
    /// Last command failure, shown as a dismissible banner in the main window.
    @Published var errorBanner: String?
    /// Containers whose published ports are unreachable because macOS denied the Local Network
    /// permission to `container-runtime-linux`. Non-empty shows a warning with a link to Settings.
    @Published var localNetworkBlockedContainers: [String] = []
    /// Labels of long-running operations in flight (pulls, builds, stack deployments).
    @Published var busyLabels: [String] = []

    // Compose Stacks State
    @Published var stacks: [ComposeStackItem] = []
    @Published var selectedStackID: String?
    @Published var selectedStackTab: ComposeStackTab = .topology
    @Published var dockerCommandInput: String = "docker run -d -p 8090:8080 --name httpbin -e PORT=8080 mccutchen/go-httpbin:v2.15.0"

    // Core Entities
    @Published var containers: [ContainerItem] = []
    @Published var images: [ImageItem] = []
    @Published var volumes: [VolumeItem] = []
    @Published var networks: [NetworkItem] = []
    @Published var commandLog: [CommandActivity] = []
    @Published var clusterMetricsHistory: [MetricSample] = []

    // Interactive Exec Console state
    @Published var execCommandInput: String = "ps aux"
    @Published var execOutputHistory: [String] = []

    // MARK: - Runtimes & internals

    let settings: AppSettings
    /// Hover state of the container list (deliberately not `@Published`, see `HoverState`).
    let listHover = HoverState()
    private(set) var appleRuntime: any ContainerRuntime
    private(set) var dockerRuntime: any ContainerRuntime
    /// Tests inject runtimes and disable timers / HTTP listeners / binary detection.
    private let usesInjectedRuntimes: Bool
    let backgroundServicesEnabled: Bool

    private var telemetryTimer: Timer?
    var tickCount: Int = 0
    var isRefreshing = false
    var pendingRefresh: (userInitiated: Bool, includeResources: Bool)?
    var isPollingStats = false
    var isFetchingDetails = false
    var isCheckingLocalNetwork = false
    /// Running containers whose published port was already probed, keyed by name and start time.
    var verifiedPortKeys: Set<String> = []
    /// Opens (and closes) a TCP connection to a host port. Replaced in tests.
    var portProbe: (Int) async -> Void = ContainerStore.tcpProbe
    /// Delay between two healthcheck / completion polls while a stack starts.
    var healthPollNanoseconds: UInt64 = 2_000_000_000
    /// How long to wait for the port forwarder's log entry after a probe.
    var probeSettleNanoseconds: UInt64 = 1_000_000_000
    /// Polling slows down while Vessel is in the background. Replaced in tests.
    var isAppActive: () -> Bool = { NSApplication.shared.isActive }
    /// True once `docker ps` succeeded; avoids polling a stopped Docker daemon every tick.
    var dockerReachable = false
    var lastStatsSampleAt: [String: Date] = [:]
    var lastLogText: [String: String] = [:]
    var fileListingAttempted: Set<String> = []
    /// UI protocol hints (`http` / `https`) for published ports, keyed by `"<container>|<hostPort>"`.
    /// Engines only know tcp/udp, so the hint is re-applied when live state is read back.
    var portProtocolHints: [String: String] = [:]

    init(
        settings: AppSettings = AppSettings(),
        appleRuntime: (any ContainerRuntime)? = nil,
        dockerRuntime: (any ContainerRuntime)? = nil,
        enableBackgroundServices: Bool = true
    ) {
        self.settings = settings
        self.language = settings.language ?? AppLanguage.detectSystemDefault()
        self.customBinaryPath = settings.customBinaryPath
        self.backgroundServicesEnabled = enableBackgroundServices
        self.usesInjectedRuntimes = appleRuntime != nil || dockerRuntime != nil
        self.appleRuntime = appleRuntime ?? UnavailableRuntime(backend: .appleContainer)
        self.dockerRuntime = dockerRuntime ?? UnavailableRuntime(backend: .dockerEngine)

        if !usesInjectedRuntimes {
            configureRuntimes()
        }
        reloadEverything()

        if enableBackgroundServices {
            startTelemetryLoop()
        }
    }

    // MARK: - Runtimes

    func runtime(for backend: RuntimeBackend) -> any ContainerRuntime {
        backend == .appleContainer ? appleRuntime : dockerRuntime
    }

    /// False when the `container` binary could not be found.
    var isContainerCLIAvailable: Bool { appleRuntime.isAvailable }

    /// Detects the CLIs and picks a runtime per backend.
    private func configureRuntimes() {
        guard !usesInjectedRuntimes else { return }
        detectedBinaryPath = ContainerCLIService.detectBinaryPath(customPath: customBinaryPath)
        detectedDockerPath = ContainerCLIService.detectDockerBinaryPath()

        if let path = detectedBinaryPath {
            appleRuntime = LiveCLIRuntime(backend: .appleContainer, path: path)
        } else {
            appleRuntime = UnavailableRuntime(backend: .appleContainer)
        }
        if let dockerPath = detectedDockerPath {
            dockerRuntime = LiveCLIRuntime(backend: .dockerEngine, path: dockerPath)
        } else {
            dockerRuntime = UnavailableRuntime(backend: .dockerEngine)
        }
    }

    func recheckBinary() {
        settings.customBinaryPath = customBinaryPath
        configureRuntimes()
        if let found = detectedBinaryPath {
            statusBannerMessage = t("Connected to the `container` binary at \(found)", "`container` binary bulundu: \(found)")
        } else {
            statusBannerMessage = t(
                "The `container` binary was not found in the standard paths.",
                "`container` binary standart yollarda bulunamadı."
            )
        }
        reloadEverything()
    }

    /// Drops all state and reads it again from the CLIs.
    private func reloadEverything() {
        containers = []
        images = []
        volumes = []
        networks = []
        clusterMetricsHistory = []
        commandLog = []
        execOutputHistory = []
        inspectJSONByContainerID = [:]
        lastStatsSampleAt = [:]
        lastLogText = [:]
        fileListingAttempted = []
        selectedContainerID = nil
        selectedGroupID = nil
        localNetworkBlockedContainers = []
        verifiedPortKeys = []
        errorBanner = nil
        dockerReachable = false
        engineVersion = ""
        engineState = isContainerCLIAvailable ? .starting : .stopped

        stacks = settings.stacks.map { persisted in
            ComposeStackItem(
                id: persisted.id,
                name: persisted.name,
                filePath: persisted.filePath,
                yamlContent: persisted.yamlContent,
                targetBackend: persisted.targetBackend,
                status: .stopped,
                services: [],
                networkName: persisted.networkName,
                lastDeployedAt: nil
            )
        }
        for index in stacks.indices {
            reparseStack(at: index)
        }
        selectedStackID = stacks.first?.id

        if !isContainerCLIAvailable {
            errorBanner = t(
                "The `container` CLI was not found. Install it from github.com/apple/container/releases, or set its path under CLI & Docker.",
                "`container` CLI bulunamadı. github.com/apple/container/releases adresinden kurun ya da CLI & Docker bölümünden yolunu girin."
            )
        }
        Task { await refreshFromLiveCLI(userInitiated: true) }
    }

    func persistStacks() {
        settings.stacks = stacks
            .map {
                PersistedStack(
                    id: $0.id, name: $0.name, filePath: $0.filePath, yamlContent: $0.yamlContent,
                    targetBackend: $0.targetBackend, networkName: $0.networkName
                )
            }
    }

    // MARK: - Command pipeline

    /// Runs a command on the runtime of `backend`, records it in the audit log and surfaces failures.
    @discardableResult
    func perform(
        _ backend: RuntimeBackend,
        _ arguments: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval = 120,
        reportFailure: Bool = true
    ) async -> CLIExecutionResult {
        let result = await runtime(for: backend).run(arguments, workingDirectory: workingDirectory, timeout: timeout)
        record(result)
        if !result.succeeded && reportFailure {
            errorBanner = "\(result.command)\n\(String(result.failureMessage.prefix(400)))"
        }
        return result
    }

    /// Commits the outcome of a command by re-reading the real state from the CLI,
    /// so the UI shows what actually happened rather than what was asked for.
    func settle() async {
        await refreshFromLiveCLI(userInitiated: false, includeResources: true)
    }

    /// Tracks a long-running operation so the status bar can show progress.
    func withBusyLabel<T>(_ label: String, _ operation: () async -> T) async -> T {
        busyLabels.append(label)
        let value = await operation()
        if let index = busyLabels.firstIndex(of: label) {
            busyLabels.remove(at: index)
        }
        return value
    }

    func record(_ result: CLIExecutionResult) {
        let preview = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.stderr : result.stdout
        recordCommand(
            command: result.command,
            durationMs: result.durationMs,
            exitCode: result.exitCode,
            outputPreview: String(preview.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func recordCommand(command: String, durationMs: Int, exitCode: Int32, outputPreview: String) {
        commandLog.insert(CommandActivity(
            timestamp: Date(),
            command: command,
            durationMs: durationMs,
            exitCode: exitCode,
            outputPreview: outputPreview
        ), at: 0)
        if commandLog.count > 100 {
            commandLog.removeLast(commandLog.count - 100)
        }
    }

    // MARK: - Computed Properties

    var filteredContainers: [ContainerItem] {
        containers.filter { item in
            let matchesState: Bool
            switch containerFilter {
            case .all: matchesState = true
            case .running: matchesState = item.state == .running
            case .stopped: matchesState = item.state != .running
            }

            let matchesSearch: Bool
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matchesSearch = true
            } else {
                let q = searchText.lowercased()
                matchesSearch = item.name.lowercased().contains(q)
                    || item.image.lowercased().contains(q)
                    || item.ipAddress.lowercased().contains(q)
                    || item.id.lowercased().contains(q)
            }

            return matchesState && matchesSearch
        }
    }

    var selectedContainer: ContainerItem? {
        guard let selectedContainerID else { return filteredContainers.first ?? containers.first }
        return containers.first(where: { $0.id == selectedContainerID }) ?? filteredContainers.first
    }

    var selectedStack: ComposeStackItem? {
        guard let selectedStackID else { return stacks.first }
        return stacks.first(where: { $0.id == selectedStackID }) ?? stacks.first
    }

    var runningContainersCount: Int {
        containers.filter { $0.state == .running }.count
    }

    var stoppedContainersCount: Int {
        containers.filter { $0.state != .running }.count
    }

    var totalCPUPercent: Double {
        containers
            .filter { $0.state == .running }
            .reduce(0.0) { $0 + $1.cpuPercentDisplay }
    }

    var totalMemoryBytes: Int64 {
        containers
            .filter { $0.state == .running }
            .reduce(Int64(0)) { $0 + $1.memoryUsageBytes }
    }

    var totalMemoryLimitBytes: Int64 {
        containers
            .filter { $0.state == .running }
            .reduce(Int64(0)) { $0 + $1.memoryLimitBytes }
    }

    var totalNetRxKBps: Double {
        clusterMetricsHistory.last?.netRxKBps ?? 0
    }

    var totalNetTxKBps: Double {
        clusterMetricsHistory.last?.netTxKBps ?? 0
    }

    var totalImagesSizeBytes: Int64 {
        images.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    /// The containers that belong to a Compose stack (by Compose label, falling back to the name convention).
    func containers(in stack: ComposeStackItem) -> [ContainerItem] {
        let names = Set(stack.services.map { ComposeOrchestrator.containerName(stackName: stack.name, service: $0) })
        return containers.filter { $0.composeProject == stack.name || names.contains($0.name) }
    }

    func container(for service: ComposeServiceDefinition, in stack: ComposeStackItem) -> ContainerItem? {
        let expected = ComposeOrchestrator.containerName(stackName: stack.name, service: service)
        let candidates = containers(in: stack)
        return candidates.first { $0.name == expected }
            ?? candidates.first { $0.labels["com.docker.compose.service"] == service.name }
    }

    /// Argument vector for the container described by the New Container form.
    func runArguments(
        name: String,
        image: String,
        cpus: Int,
        memoryMB: Int,
        ports: [PortMapping],
        mounts: [VolumeMount],
        envPairs: [String: String],
        network: String,
        command: String
    ) -> [String] {
        var arguments = ["run", "--detach"]
        if !name.isEmpty {
            arguments += ["--name", name]
        }
        arguments += ["--cpus", String(cpus), "--memory", "\(String(memoryMB))M"]
        if !network.isEmpty && network != "default" {
            arguments += ["--network", network]
        }
        for port in ports {
            arguments += ["--publish", port.publishArgument]
        }
        for mount in mounts {
            arguments += ["--volume", "\(mount.source):\(mount.destination)"]
        }
        for (key, value) in envPairs.sorted(by: { $0.key < $1.key }) {
            arguments += ["--env", "\(key)=\(value)"]
        }
        arguments.append(image.isEmpty ? "alpine:latest" : image)
        arguments += ShellWords.split(command)
        return arguments
    }

    var previewRunCommand: String {
        var ports: [PortMapping] = []
        if let hp = Int(newContainerHostPort), let cp = Int(newContainerTargetPort), hp > 0, cp > 0 {
            ports.append(PortMapping(hostIP: "0.0.0.0", hostPort: hp, containerPort: cp, protocolType: newContainerPortProtocol.rawValue))
        }
        var mounts: [VolumeMount] = []
        if !newContainerMountSource.isEmpty && !newContainerMountDest.isEmpty {
            mounts.append(VolumeMount(type: "virtiofs", source: newContainerMountSource, destination: newContainerMountDest, readOnly: false))
        }
        return ShellWords.join(["container"] + runArguments(
            name: newContainerName.trimmingCharacters(in: .whitespacesAndNewlines),
            image: newContainerImage,
            cpus: newContainerCPUs,
            memoryMB: newContainerMemoryMB,
            ports: ports,
            mounts: mounts,
            envPairs: newContainerEnvKey.isEmpty ? [:] : [newContainerEnvKey: newContainerEnvValue],
            network: newContainerNetwork,
            command: newContainerCommand
        ))
    }

    // MARK: - Telemetry Loop (1 Hz)

    func startTelemetryLoop() {
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tickTelemetry()
            }
        }
    }

    /// The timer fires every second. The container list is re-read every 6 s and resource usage
    /// is sampled every 2 s — or every 10 s while Vessel is in the background, where nobody is
    /// looking at the charts and spawning `container stats` would only burn CPU.
    func tickTelemetry() async {
        tickCount += 1
        let active = isAppActive()

        if tickCount % 6 == 0 {
            await refreshFromLiveCLI(userInitiated: false)
            await verifyPublishedPorts(recheckBlocked: tickCount % 30 == 0)
        }
        guard tickCount % (active ? 2 : 10) == 0 else { return }
        await pollLiveStats()
        if active {
            await fetchVisibleDetails()
        }
        appendClusterSample()
    }

    /// Aggregates each running container's most recent sample into one cluster-wide sample.
    func appendClusterSample() {
        var cpu = 0.0, cores = 0.0, rx = 0.0, tx = 0.0, read = 0.0, write = 0.0
        var memory: Int64 = 0, memoryLimit: Int64 = 0
        var processes = 0

        for container in containers where container.state == .running {
            memoryLimit += container.memoryLimitBytes
            guard let sample = container.latestMetric else { continue }
            cpu += sample.cpuPercent
            cores += sample.cpuCoresUsed
            memory += sample.memoryUsageBytes
            rx += sample.netRxBytesPerSec
            tx += sample.netTxBytesPerSec
            read += sample.blockReadBytesPerSec
            write += sample.blockWriteBytesPerSec
            processes += sample.numProcesses
        }

        clusterMetricsHistory.append(MetricSample(
            timestamp: Date(),
            cpuPercent: cpu,
            cpuCoresUsed: cores,
            memoryUsageBytes: memory,
            memoryLimitBytes: max(1, memoryLimit),
            netRxBytesPerSec: rx,
            netTxBytesPerSec: tx,
            blockReadBytesPerSec: read,
            blockWriteBytesPerSec: write,
            numProcesses: processes
        ))
        if clusterMetricsHistory.count > 60 {
            clusterMetricsHistory.removeFirst(clusterMetricsHistory.count - 60)
        }
    }
}
