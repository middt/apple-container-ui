import Foundation
import AppKit
import Network

// State is read back from the real `container` and `docker` CLIs.
// Nothing in this file fabricates data — a field the CLI did not report stays empty.
extension ContainerStore {

    /// Cmd+R / toolbar refresh.
    func refreshAll() async {
        await refreshFromLiveCLI(userInitiated: true)
    }

    /// Re-reads containers (and optionally images / volumes / networks) from every live backend.
    /// - Parameter userInitiated: record the commands in the audit log and report failures.
    ///   Background polls stay silent so the log is not flooded.
    func refreshFromLiveCLI(userInitiated: Bool, includeResources: Bool = false) async {
        // A refresh requested while another one is in flight must not be dropped: the running one
        // may already have read stale state. Remember the request and run one more pass afterwards.
        guard !isRefreshing else {
            pendingRefresh = (
                userInitiated: (pendingRefresh?.userInitiated ?? false) || userInitiated,
                includeResources: (pendingRefresh?.includeResources ?? false) || includeResources
            )
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var request: (userInitiated: Bool, includeResources: Bool)? = (userInitiated, includeResources)
        while let current = request {
            pendingRefresh = nil
            await refreshOnce(userInitiated: current.userInitiated, includeResources: current.includeResources)
            request = pendingRefresh
        }
    }

    private func refreshOnce(userInitiated: Bool, includeResources: Bool) async {
        let loadResources = userInitiated || includeResources
        var liveItems: [ContainerItem] = []

        if appleRuntime.isAvailable {
            liveItems += await loadAppleContainers(userInitiated: userInitiated)
            if loadResources && engineState == .running {
                await loadAppleResources()
            }
        }
        if dockerRuntime.isAvailable {
            liveItems += await loadDockerContainers(userInitiated: userInitiated)
        }

        mergeLiveContainers(liveItems)
        updateStackStatuses()
        updateResourceUsage()
    }

    // MARK: - apple/container

    private func loadAppleContainers(userInitiated: Bool) async -> [ContainerItem] {
        if engineVersion.isEmpty {
            // `--version` works even when the system services are stopped.
            let version = await appleRuntime.run(["--version"], timeout: 20)
            if version.succeeded {
                engineVersion = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let status = await appleRuntime.run(["system", "status", "--format", "json"], timeout: 20)
        let running = AppleContainerParser.isSystemRunning(statusOutput: status.stdout + status.stderr, exitCode: status.exitCode)
        if userInitiated { record(status) }

        // Do not override a transition the user just asked for.
        if engineState != .stopping || !running {
            engineState = running ? .running : .stopped
        }
        guard running else { return [] }

        let list = await appleRuntime.run(["list", "--all", "--format", "json"], timeout: 30)
        if userInitiated { record(list) }
        guard list.succeeded, let parsed = AppleContainerParser.containers(fromJSON: Data(list.stdout.utf8)) else {
            if userInitiated {
                errorBanner = "\(list.command)\n\(String(list.failureMessage.prefix(400)))"
            }
            // Keep what we had rather than blanking the list on a transient failure.
            return containers.filter { $0.backend == .appleContainer }
        }
        return parsed
    }

    private func loadAppleResources() async {
        async let imageResult = appleRuntime.run(["image", "list", "--format", "json"], timeout: 30)
        async let volumeResult = appleRuntime.run(["volume", "list", "--format", "json"], timeout: 30)
        async let networkResult = appleRuntime.run(["network", "list", "--format", "json"], timeout: 30)
        async let dnsResult = appleRuntime.run(["system", "dns", "list", "--format", "json"], timeout: 30)
        let (imageList, volumeList, networkList, dnsList) = await (imageResult, volumeResult, networkResult, dnsResult)

        let domain = dnsList.succeeded ? AppleContainerParser.dnsDomains(fromJSON: Data(dnsList.stdout.utf8)).first : nil
        if domain != dnsDomain {
            dnsDomain = domain
            for index in stacks.indices {
                reparseStack(at: index)      // the "no DNS domain" warning depends on it
            }
        }

        if imageList.succeeded, let parsed = AppleContainerParser.images(fromJSON: Data(imageList.stdout.utf8)) {
            images = parsed
        }
        if volumeList.succeeded, let parsed = AppleContainerParser.volumes(fromJSON: Data(volumeList.stdout.utf8)) {
            volumes = parsed
        }
        if networkList.succeeded, let parsed = AppleContainerParser.networks(fromJSON: Data(networkList.stdout.utf8)) {
            networks = parsed
        }
    }

    // MARK: - Docker

    private func loadDockerContainers(userInitiated: Bool) async -> [ContainerItem] {
        // A stopped daemon is only re-probed on explicit refreshes, not on every background poll.
        guard dockerReachable || userInitiated else { return [] }

        let list = await dockerRuntime.run(["ps", "--all", "--quiet"], timeout: 20)
        guard list.succeeded else {
            dockerReachable = false
            return []
        }
        dockerReachable = true

        let ids = list.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard !ids.isEmpty else { return [] }

        let inspect = await dockerRuntime.run(["inspect"] + ids, timeout: 30)
        guard inspect.succeeded, let parsed = DockerParser.containers(fromInspectJSON: Data(inspect.stdout.utf8)) else {
            return containers.filter { $0.backend == .dockerEngine }
        }
        return parsed
    }

    /// Marks Docker as reachable after a Docker command succeeded, so its containers get listed.
    func noteDockerCommandSucceeded() {
        if dockerRuntime.isAvailable {
            dockerReachable = true
        }
    }

    // MARK: - Merging

    /// Replaces the containers of live backends with `liveItems`, keeping locally accumulated
    /// runtime data (metric history, counters, logs) for containers that still exist.
    func mergeLiveContainers(_ liveItems: [ContainerItem]) {
        let previous = Dictionary(
            containers.map { ("\($0.backend.rawValue)|\($0.name)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var usedIDs: Set<String> = []
        var merged: [ContainerItem] = []

        for var item in liveItems {
            // Container ids must be unique across engines.
            if usedIDs.contains(item.id) {
                item = item.withID("\(item.backend.rawValue):\(item.name)")
            }
            usedIDs.insert(item.id)

            if let old = previous["\(item.backend.rawValue)|\(item.name)"] {
                item.metricsHistory = old.metricsHistory
                item.logs = old.logs
                item.fileEntries = old.fileEntries
                item.cpuUsageUsec = old.cpuUsageUsec
                item.networkRxBytes = old.networkRxBytes
                item.networkTxBytes = old.networkTxBytes
                item.blockReadBytes = old.blockReadBytes
                item.blockWriteBytes = old.blockWriteBytes
                if item.state == .running {
                    item.cpuUtilization = old.cpuUtilization
                    item.memoryUsageBytes = old.memoryUsageBytes
                    item.numProcesses = old.numProcesses
                }
                if item.memoryLimitBytes == 0 { item.memoryLimitBytes = old.memoryLimitBytes }
            }

            item.ports = item.ports.map { port in
                guard let hint = portProtocolHints["\(item.name)|\(port.hostPort)"], port.transportProtocol == "tcp" else {
                    return port
                }
                return PortMapping(hostIP: port.hostIP, hostPort: port.hostPort, containerPort: port.containerPort, protocolType: hint)
            }
            merged.append(item)
        }

        if merged != containers {
            containers = merged
        }
        if let selectedGroupID, !containerGroups(in: containers).contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = nil
        }
        if let selectedContainerID, !containers.contains(where: { $0.id == selectedContainerID }) {
            self.selectedContainerID = containers.first?.id
        } else if selectedContainerID == nil {
            selectedContainerID = containers.first?.id
        }
    }

    /// A stack on a live backend is running when one of its containers is.
    func updateStackStatuses() {
        for idx in stacks.indices {
            guard stacks[idx].status != .starting, stacks[idx].status != .stopping else { continue }
            let members = containers(in: stacks[idx]).filter { $0.backend == stacks[idx].targetBackend }
            let status: ContainerState = members.contains { $0.state == .running } ? .running : .stopped
            if stacks[idx].status != status {
                stacks[idx].status = status
            }
        }
    }

    /// Derives "used by" information for volumes and networks from the container list.
    func updateResourceUsage() {
        let live = containers.filter { $0.backend == .appleContainer }
        for idx in volumes.indices {
            let users = live.filter { c in c.mounts.contains { $0.source == volumes[idx].name } }.map { $0.name }
            if volumes[idx].attachedContainers != users { volumes[idx].attachedContainers = users }
        }
        for idx in networks.indices {
            let users = live.filter { $0.networkName == networks[idx].name }.map { $0.name }
            if networks[idx].connectedContainers != users { networks[idx].connectedContainers = users }
        }
    }

    // MARK: - Local Network permission

    /// Published ports only work when macOS lets `container-runtime-linux` reach the container
    /// network. A denial is silent — the host port accepts the connection and then resets it —
    /// so Vessel checks proactively: it opens a TCP connection to the published port of every
    /// newly started container and then looks for the forwarder's `No route to host (errno: 65)`
    /// error in the system log. Nobody has to try the port in a browser first.
    ///
    /// - Parameters:
    ///   - recheckBlocked: probe containers that are currently flagged again (clears the warning
    ///     once the permission has been granted).
    ///   - force: container names to probe again regardless of earlier results.
    func verifyPublishedPorts(recheckBlocked: Bool = false, force: Set<String> = []) async {
        guard appleRuntime.isAvailable, engineState == .running, !isCheckingLocalNetwork else { return }

        func key(_ container: ContainerItem) -> String {
            "\(container.name)|\(container.startedAt?.timeIntervalSince1970 ?? 0)"
        }
        func tcpPort(_ container: ContainerItem) -> PortMapping? {
            container.ports.first { $0.transportProtocol == "tcp" }
        }

        let candidates = containers.filter { $0.backend == .appleContainer && $0.state == .running && tcpPort($0) != nil }
        let candidateNames = Set(candidates.map { $0.name })

        // Forget containers that stopped, so they are probed again after a restart.
        verifiedPortKeys.formIntersection(Set(candidates.map(key)))
        let stillBlocked = localNetworkBlockedContainers.filter { candidateNames.contains($0) }
        if stillBlocked != localNetworkBlockedContainers {
            localNetworkBlockedContainers = stillBlocked
        }

        let targets = candidates.filter { container in
            !verifiedPortKeys.contains(key(container))
                || force.contains(container.name)
                || (recheckBlocked && localNetworkBlockedContainers.contains(container.name))
        }
        guard !targets.isEmpty else { return }

        isCheckingLocalNetwork = true
        defer { isCheckingLocalNetwork = false }

        let since = Date().addingTimeInterval(-1)
        for target in targets {
            if let port = tcpPort(target) {
                await portProbe(port.hostPort)
            }
            verifiedPortKeys.insert(key(target))
        }
        // The forwarder logs asynchronously, and the unified log trails real time slightly.
        try? await Task.sleep(nanoseconds: probeSettleNanoseconds)

        let logs = await appleRuntime.run(["system", "logs", "--last", "1m"], timeout: 30)
        guard logs.succeeded else { return }
        let blockedNow = Set(AppleContainerParser.containersBlockedByLocalNetwork(systemLog: logs.stdout + logs.stderr, since: since))

        var result = localNetworkBlockedContainers
        for target in targets {
            if blockedNow.contains(target.name) {
                if !result.contains(target.name) { result.append(target.name) }
            } else {
                result.removeAll { $0 == target.name }
            }
        }
        if result != localNetworkBlockedContainers {
            localNetworkBlockedContainers = result
        }
    }

    /// Opens a TCP connection to `127.0.0.1:<port>`, keeps it briefly so the forwarder attempts
    /// its backend connection, and closes it. No data is sent.
    nonisolated static func tcpProbe(port: Int) async {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            let once = OnceFlag()
            let finish: @Sendable () -> Void = {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { finish() }
                case .failed, .cancelled, .waiting:
                    finish()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish() }
        }
    }

    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Stats polling

    /// Samples resource usage of live containers. Overlapping polls are skipped, and rates are
    /// computed from the real time elapsed since the previous sample of each container.
    func pollLiveStats() async {
        guard !isPollingStats else { return }
        isPollingStats = true
        defer { isPollingStats = false }

        async let appleStats: [RawContainerStatJSON]? = loadAppleStats()
        async let dockerStats: [DockerStatSample]? = loadDockerStats()
        let (apple, docker) = await (appleStats, dockerStats)

        let now = Date()
        var working = containers
        var changed = false

        for stat in apple ?? [] {
            guard let id = stat.id,
                  let idx = working.firstIndex(where: { $0.backend == .appleContainer && ($0.name == id || $0.id == id) }) else { continue }
            let key = "apple|\(working[idx].name)"
            let elapsed = lastStatsSampleAt[key].map { now.timeIntervalSince($0) } ?? 0
            lastStatsSampleAt[key] = now

            func rate(_ new: Int64?, _ old: Int64) -> Double {
                guard let new, elapsed > 0.2 else { return 0 }
                return Double(max(0, new - old)) / elapsed
            }

            let utilization: Double
            if let reported = stat.cpuUtilization {
                utilization = reported
            } else if let usage = stat.cpuUsageUsec, elapsed > 0.2 {
                utilization = Double(max(0, usage - working[idx].cpuUsageUsec)) / (elapsed * 1_000_000)
            } else {
                utilization = 0
            }

            let sample = MetricSample(
                timestamp: now,
                cpuPercent: utilization * 100,
                cpuCoresUsed: utilization,
                memoryUsageBytes: stat.memoryUsageBytes ?? 0,
                memoryLimitBytes: max(1, stat.memoryLimitBytes ?? working[idx].memoryLimitBytes),
                netRxBytesPerSec: rate(stat.networkRxBytes, working[idx].networkRxBytes),
                netTxBytesPerSec: rate(stat.networkTxBytes, working[idx].networkTxBytes),
                blockReadBytesPerSec: rate(stat.blockReadBytes, working[idx].blockReadBytes),
                blockWriteBytesPerSec: rate(stat.blockWriteBytes, working[idx].blockWriteBytes),
                numProcesses: stat.numProcesses ?? working[idx].numProcesses
            )

            working[idx].cpuUtilization = utilization
            working[idx].cpuUsageUsec = stat.cpuUsageUsec ?? working[idx].cpuUsageUsec
            working[idx].memoryUsageBytes = stat.memoryUsageBytes ?? 0
            if working[idx].memoryLimitBytes == 0, let limit = stat.memoryLimitBytes { working[idx].memoryLimitBytes = limit }
            working[idx].networkRxBytes = stat.networkRxBytes ?? working[idx].networkRxBytes
            working[idx].networkTxBytes = stat.networkTxBytes ?? working[idx].networkTxBytes
            working[idx].blockReadBytes = stat.blockReadBytes ?? working[idx].blockReadBytes
            working[idx].blockWriteBytes = stat.blockWriteBytes ?? working[idx].blockWriteBytes
            working[idx].numProcesses = stat.numProcesses ?? working[idx].numProcesses
            working[idx].metricsHistory.append(sample)
            trimHistory(&working[idx])
            changed = true
        }

        for stat in docker ?? [] {
            guard let idx = working.firstIndex(where: { $0.backend == .dockerEngine && $0.name == stat.name }) else { continue }
            let key = "docker|\(stat.name)"
            let elapsed = lastStatsSampleAt[key].map { now.timeIntervalSince($0) } ?? 0
            lastStatsSampleAt[key] = now

            func rate(_ new: Int64, _ old: Int64) -> Double {
                elapsed > 0.2 ? Double(max(0, new - old)) / elapsed : 0
            }

            let sample = MetricSample(
                timestamp: now,
                cpuPercent: stat.cpuPercent,
                cpuCoresUsed: stat.cpuPercent / 100,
                memoryUsageBytes: stat.memoryUsageBytes,
                memoryLimitBytes: max(1, stat.memoryLimitBytes),
                netRxBytesPerSec: rate(stat.networkRxBytes, working[idx].networkRxBytes),
                netTxBytesPerSec: rate(stat.networkTxBytes, working[idx].networkTxBytes),
                blockReadBytesPerSec: rate(stat.blockReadBytes, working[idx].blockReadBytes),
                blockWriteBytesPerSec: rate(stat.blockWriteBytes, working[idx].blockWriteBytes),
                numProcesses: stat.numProcesses
            )

            working[idx].cpuUtilization = stat.cpuPercent / 100
            working[idx].memoryUsageBytes = stat.memoryUsageBytes
            if working[idx].memoryLimitBytes == 0 { working[idx].memoryLimitBytes = stat.memoryLimitBytes }
            working[idx].networkRxBytes = stat.networkRxBytes
            working[idx].networkTxBytes = stat.networkTxBytes
            working[idx].blockReadBytes = stat.blockReadBytes
            working[idx].blockWriteBytes = stat.blockWriteBytes
            working[idx].numProcesses = stat.numProcesses
            working[idx].metricsHistory.append(sample)
            trimHistory(&working[idx])
            changed = true
        }

        // `working` was copied after the last suspension point, so this publishes exactly once per poll.
        if changed {
            containers = working
        }
    }

    /// Charts show a rolling window of 60 samples.
    func trimHistory(_ container: inout ContainerItem) {
        if container.metricsHistory.count > 60 {
            container.metricsHistory.removeFirst(container.metricsHistory.count - 60)
        }
    }

    private func loadAppleStats() async -> [RawContainerStatJSON]? {
        guard appleRuntime.isAvailable, engineState == .running,
              containers.contains(where: { $0.backend == .appleContainer && $0.state == .running }) else { return nil }
        let result = await appleRuntime.run(["stats", "--format", "json", "--no-stream"], timeout: 15)
        guard result.succeeded else { return nil }
        return AppleContainerParser.stats(fromJSON: Data(result.stdout.utf8))
    }

    private func loadDockerStats() async -> [DockerStatSample]? {
        guard dockerRuntime.isAvailable, dockerReachable,
              containers.contains(where: { $0.backend == .dockerEngine && $0.state == .running }) else { return nil }
        let result = await dockerRuntime.run(["stats", "--no-stream", "--format", "json"], timeout: 15)
        guard result.succeeded else { return nil }
        return DockerParser.stats(fromJSONLines: result.stdout)
    }

    // MARK: - On-demand details (logs, inspect JSON, root file listing)

    /// Fetches the data behind the tab the user is currently looking at, for live containers only.
    func fetchVisibleDetails() async {
        guard !isFetchingDetails else { return }
        isFetchingDetails = true
        defer { isFetchingDetails = false }

        if selectedSidebar == .stacks, selectedStackTab == .logs, let stack = selectedStack {
            for container in containers(in: stack) {
                await refreshLogs(for: container)
            }
            return
        }

        guard selectedSidebar == .containers, selectedGroupID == nil, let container = selectedContainer else { return }
        switch selectedDetailTab {
        case .logs:
            await refreshLogs(for: container)
        case .rawJSON:
            if inspectJSONByContainerID[container.id] == nil || tickCount % 6 == 0 {
                await refreshInspectJSON(for: container)
            }
        case .files:
            // One attempt per container: images without `ls` (distroless) would otherwise be retried forever.
            if container.fileEntries.isEmpty, container.state == .running, !fileListingAttempted.contains(container.id) {
                fileListingAttempted.insert(container.id)
                await refreshRootListing(for: container)
            }
        default:
            break
        }
    }

    func refreshLogs(for container: ContainerItem) async {
        let arguments = container.backend == .dockerEngine
            ? ["logs", "--tail", "200", container.cliID]
            : ["logs", "-n", "200", container.cliID]
        let result = await runtime(for: container.backend).run(arguments, timeout: 15)
        guard result.succeeded else { return }

        // Docker writes container stderr to our stderr; show both streams.
        let text = result.stdout + result.stderr
        let key = "\(container.backend.rawValue)|\(container.name)"
        guard lastLogText[key] != text else { return }
        lastLogText[key] = text

        let now = Date()
        let entries = text.split(whereSeparator: \.isNewline).map { line -> LogEntry in
            let message = String(line)
            let lower = message.lowercased()
            let level: LogEntry.LogLevel
            if lower.contains("error") || lower.contains("fatal") || lower.contains("panic") {
                level = .error
            } else if lower.contains("warn") {
                level = .warn
            } else if lower.contains("debug") {
                level = .debug
            } else {
                level = .info
            }
            return LogEntry(timestamp: now, stream: "stdout", level: level, message: message)
        }
        if let idx = containers.firstIndex(where: { $0.id == container.id }) {
            containers[idx].logs = entries
        }
    }

    func refreshInspectJSON(for container: ContainerItem) async {
        let result = await runtime(for: container.backend).run(["inspect", container.cliID], timeout: 15)
        guard result.succeeded else { return }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if inspectJSONByContainerID[container.id] != text {
            inspectJSONByContainerID[container.id] = text
        }
    }

    func refreshRootListing(for container: ContainerItem) async {
        let result = await runtime(for: container.backend).run(["exec", container.cliID, "ls", "-la", "/"], timeout: 15)
        guard result.succeeded, let idx = containers.firstIndex(where: { $0.id == container.id }) else { return }
        containers[idx].fileEntries = Self.parseDirectoryListing(result.stdout)
    }

    /// Parses `ls -la` output (GNU coreutils and BusyBox share this layout).
    nonisolated static func parseDirectoryListing(_ output: String) -> [ContainerFileEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 9, let type = fields[0].first, "-dlbcps".contains(type) else { return nil }
            var name = fields[8...].joined(separator: " ")
            if type == "l", let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            guard name != "." && name != ".." else { return nil }
            return ContainerFileEntry(
                name: name,
                permissions: fields[0],
                owner: "\(fields[2]):\(fields[3])",
                size: Int64(fields[4]).map { ByteFormat.string($0) } ?? fields[4],
                modified: fields[5...7].joined(separator: " "),
                isDirectory: type == "d",
                isSymlink: type == "l"
            )
        }
    }
}

/// Lets exactly one caller through, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

extension ContainerItem {
    /// `id` is immutable, so re-keying a container means rebuilding it.
    func withID(_ newID: String) -> ContainerItem {
        ContainerItem(
            id: newID, name: name, image: image, os: os, arch: arch, state: state, ipAddress: ipAddress,
            macAddress: macAddress, networkName: networkName, domainName: domainName, command: command,
            createdAt: createdAt, startedAt: startedAt, cpuLimitCores: cpuLimitCores,
            memoryLimitBytes: memoryLimitBytes, ports: ports, mounts: mounts, env: env, labels: labels,
            backend: backend, composeProject: composeProject, cpuUsageUsec: cpuUsageUsec,
            cpuUtilization: cpuUtilization, memoryUsageBytes: memoryUsageBytes, networkRxBytes: networkRxBytes,
            networkTxBytes: networkTxBytes, blockReadBytes: blockReadBytes, blockWriteBytes: blockWriteBytes,
            numProcesses: numProcesses, metricsHistory: metricsHistory, logs: logs, fileEntries: fileEntries
        )
    }
}
