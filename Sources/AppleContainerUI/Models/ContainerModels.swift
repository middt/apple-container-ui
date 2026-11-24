import Foundation
import SwiftUI

// MARK: - Navigation & Tabs

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case containers = "Containers"
    case stacks = "Compose Stacks"
    case images = "Images"
    case volumes = "Volumes"
    case networks = "Networks"
    case activity = "CLI & Docker"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .containers: return "shippingbox.fill"
        case .stacks: return "square.stack.3d.down.right.fill"
        case .images: return "square.stack.3d.up.fill"
        case .volumes: return "internaldrive.fill"
        case .networks: return "network"
        case .activity: return "terminal.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: return "Cluster & Charts"
        case .containers: return "Linux MicroVMs"
        case .stacks: return "docker-compose.yml"
        case .images: return "OCI Registry & Layers"
        case .volumes: return "Persistent Storage"
        case .networks: return "vmnet Bridges & DNS"
        case .activity: return "Engine & Translator"
        }
    }
}

enum RuntimeBackend: String, Codable, CaseIterable, Identifiable {
    case appleContainer = "apple/container"
    case dockerEngine = "docker"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleContainer: return "Apple Container (MicroVM)"
        case .dockerEngine: return "Docker CLI Engine"
        }
    }

    var shortBadge: String {
        switch self {
        case .appleContainer: return "apple/container"
        case .dockerEngine: return "docker"
        }
    }
}

enum ComposeStackTab: String, CaseIterable, Identifiable {
    case topology = "Services & Topology"
    case yaml = "docker-compose.yml"
    case plan = "Apple Container Execution"
    case logs = "Stack Logs"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .topology: return "point.3.filled.connected.trianglepath.dotted"
        case .yaml: return "doc.text.fill"
        case .plan: return "cpu.fill"
        case .logs: return "text.alignleft"
        }
    }
}

struct ComposeHealthcheck: Equatable {
    var test: [String]
    var interval: String?
    var timeout: String?
    var retries: Int?
    var startPeriod: String?
    var disabled: Bool = false

    /// The probe as an argument vector for `container exec` (`CMD-SHELL` runs through `sh -c`).
    var execArguments: [String] {
        guard let kind = test.first else { return [] }
        switch kind {
        case "CMD": return Array(test.dropFirst())
        case "CMD-SHELL": return ["sh", "-c", test.dropFirst().joined(separator: " ")]
        case "NONE": return []
        default: return test
        }
    }

    /// How long Vessel waits for the service to become healthy:
    /// `start_period + retries × (interval + timeout)`, with Compose's defaults for missing values.
    var startupTimeoutSeconds: Int {
        let start = ComposeOrchestrator.parseDurationSeconds(startPeriod) ?? 0
        let every = ComposeOrchestrator.parseDurationSeconds(interval) ?? 30
        let limit = ComposeOrchestrator.parseDurationSeconds(timeout) ?? 30
        return max(5, start + (retries ?? 3) * (every + limit))
    }
}

struct ComposeBuild: Equatable {
    var context: String
    var dockerfile: String?
    var args: [String: String] = [:]
    var target: String?
}

struct ComposeServiceDefinition: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var image: String
    var ports: [PortMapping]
    var environment: [String: String]
    /// Short-syntax volume specs (`source:target[:ro]`), exactly as they are passed to `--volume`.
    var volumes: [String]
    var dependsOn: [String]
    var cpus: Int
    var memoryMB: Int
    var command: [String] = []
    var entrypoint: [String]? = nil
    var build: ComposeBuild? = nil
    var envFiles: [String] = []
    var healthcheck: ComposeHealthcheck? = nil
    var containerName: String? = nil
    var labels: [String: String] = [:]
    var workingDir: String? = nil
    var user: String? = nil
    var restart: String? = nil
    /// `depends_on` conditions by service name (`service_started`, `service_healthy`, `service_completed_successfully`).
    var dependencyConditions: [String: String] = [:]
    var tmpfs: [String] = []
    var capAdd: [String] = []
    var capDrop: [String] = []
    var profiles: [String] = []
    var networkMode: String? = nil
}

struct ComposeStackItem: Identifiable, Equatable {
    let id: String
    var name: String
    var filePath: String
    var yamlContent: String
    var targetBackend: RuntimeBackend
    var status: ContainerState
    var services: [ComposeServiceDefinition]
    var networkName: String
    var lastDeployedAt: Date?
    /// Things in the Compose file that Vessel could not honour (shown in the execution plan).
    var warnings: [String] = []
    /// `networks: <x>: external: true` — shared with other stacks, so "Stack Down" must not delete it.
    var networkIsExternal: Bool = false
    /// Actual names of named volumes, by the key used in the file (`external` / `name:` volumes keep
    /// their name; everything else becomes `<stack>_<volume>` like in Compose).
    var volumeNames: [String: String] = [:]

    /// Directory that relative paths (`./data`, `env_file`, `build.context`) resolve against.
    var baseDirectory: String? {
        guard !filePath.isEmpty else { return nil }
        let dir = (filePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }
}

enum ContainerDetailTab: String, CaseIterable, Identifiable {
    case stats = "Metrics"
    case logs = "Logs"
    case terminal = "Exec / Shell"
    case info = "Inspect & Mounts"
    case files = "Files"
    case rawJSON = "Raw JSON"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .stats: return "chart.xyaxis.line"
        case .logs: return "doc.text.magnifyingglass"
        case .terminal: return "apple.terminal"
        case .info: return "info.circle"
        case .files: return "folder"
        case .rawJSON: return "curlybraces"
        }
    }
}

enum ContainerFilterState: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case stopped = "Stopped"

    var id: String { rawValue }
}

// MARK: - Container Lifecycle & State

enum ContainerState: String, Codable, CaseIterable {
    case running = "running"
    case stopped = "stopped"
    case paused = "paused"
    case starting = "starting"
    case stopping = "stopping"

    var label: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .paused: return "Paused"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        }
    }

    var color: Color {
        switch self {
        case .running: return Color(red: 0.18, green: 0.84, blue: 0.45)
        case .stopped: return Color.secondary.opacity(0.6)
        case .paused: return Color.orange
        case .starting, .stopping: return Color.yellow
        }
    }
}

// MARK: - Telemetry Sample (For Real-Time Charts)

struct MetricSample: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let cpuPercent: Double          // e.g. 14.5% (100% = 1 core or normalized to allocated cores)
    let cpuCoresUsed: Double        // e.g. 0.29 cores
    let memoryUsageBytes: Int64
    let memoryLimitBytes: Int64
    let netRxBytesPerSec: Double    // Bytes/sec
    let netTxBytesPerSec: Double    // Bytes/sec
    let blockReadBytesPerSec: Double
    let blockWriteBytesPerSec: Double
    let numProcesses: Int

    var memoryUsageMB: Double {
        Double(memoryUsageBytes) / (1024.0 * 1024.0)
    }

    var memoryLimitMB: Double {
        Double(max(memoryLimitBytes, 1)) / (1024.0 * 1024.0)
    }

    var memoryPercent: Double {
        guard memoryLimitBytes > 0 else { return 0 }
        return min(100.0, (Double(memoryUsageBytes) / Double(memoryLimitBytes)) * 100.0)
    }

    var netRxKBps: Double {
        netRxBytesPerSec / 1024.0
    }

    var netTxKBps: Double {
        netTxBytesPerSec / 1024.0
    }

    var diskReadKBps: Double {
        blockReadBytesPerSec / 1024.0
    }

    var diskWriteKBps: Double {
        blockWriteBytesPerSec / 1024.0
    }
}

// MARK: - Port & Mount Structures

enum PortAppProtocol: String, Codable, CaseIterable, Identifiable {
    case http = "http"
    case https = "https"
    case tcp = "tcp"
    case udp = "udp"

    var id: String { rawValue }

    var isWebHTTP: Bool {
        self == .http || self == .https
    }
}

struct PortMapping: Identifiable, Hashable, Codable {
    var id: String { "\(String(hostPort)):\(String(containerPort))/\(protocolType)" }
    let hostIP: String
    let hostPort: Int
    let containerPort: Int
    let protocolType: String // "http", "https", "tcp", "udp"

    var appProtocol: PortAppProtocol {
        if let p = PortAppProtocol(rawValue: protocolType.lowercased()) {
            return p
        }
        // Infer HTTP only for known web ports when raw "tcp" is passed
        let knownHTTPPorts: Set<Int> = [80, 443, 3000, 3001, 5000, 5173, 8000, 8080, 8081, 8088, 8443, 8888, 9000]
        if knownHTTPPorts.contains(containerPort) || knownHTTPPorts.contains(hostPort) {
            return (containerPort == 443 || hostPort == 8443) ? .https : .http
        }
        return .tcp
    }

    var isHTTPService: Bool {
        appProtocol.isWebHTTP
    }

    var displayString: String {
        "\(String(hostPort)) → \(String(containerPort))/\(appProtocol.rawValue)"
    }

    /// Transport protocol understood by the engines (`http` / `https` are Vessel UI hints on top of TCP).
    var transportProtocol: String {
        protocolType.lowercased() == "udp" ? "udp" : "tcp"
    }

    /// Value for `--publish`: `[host-ip:]host-port:container-port[/udp]`.
    var publishArgument: String {
        var spec = "\(String(hostPort)):\(String(containerPort))"
        if !hostIP.isEmpty && hostIP != "0.0.0.0" {
            spec = (hostIP.contains(":") ? "[\(hostIP)]" : hostIP) + ":" + spec
        }
        if transportProtocol == "udp" {
            spec += "/udp"
        }
        return spec
    }

    var tcpEndpointString: String {
        "\(hostIP.isEmpty || hostIP == "0.0.0.0" ? "127.0.0.1" : hostIP):\(String(hostPort))"
    }

    var browserURL: URL? {
        guard isHTTPService else { return nil }
        let scheme = appProtocol == .https ? "https" : "http"
        return URL(string: "\(scheme)://localhost:\(String(hostPort))")
    }
}

struct VolumeMount: Identifiable, Hashable, Codable {
    var id: String { "\(source)->\(destination)" }
    let type: String      // "bind", "volume", "tmpfs", "virtiofs"
    let source: String
    let destination: String
    let readOnly: Bool
}

struct ContainerFileEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let permissions: String
    let owner: String
    let size: String
    let modified: String
    let isDirectory: Bool
    let isSymlink: Bool
}

// MARK: - Container Item

struct ContainerItem: Identifiable, Equatable {
    let id: String
    var name: String
    var image: String
    var os: String
    var arch: String
    var state: ContainerState
    var ipAddress: String
    var macAddress: String
    var networkName: String
    var domainName: String
    var command: String
    var createdAt: Date
    var startedAt: Date?
    var cpuLimitCores: Int
    var memoryLimitBytes: Int64
    var ports: [PortMapping]
    var mounts: [VolumeMount]
    var env: [String: String]
    var labels: [String: String]
    var backend: RuntimeBackend = .appleContainer
    var composeProject: String? = nil

    // Live cumulative counters (matching `container stats --format json`)
    var cpuUsageUsec: Int64
    var cpuUtilization: Double // fraction of single core e.g. 0.25 = 25%
    var memoryUsageBytes: Int64
    var networkRxBytes: Int64
    var networkTxBytes: Int64
    var blockReadBytes: Int64
    var blockWriteBytes: Int64
    var numProcesses: Int

    // Rolling 60-second history for real-time charts
    var metricsHistory: [MetricSample]
    var logs: [LogEntry]
    var fileEntries: [ContainerFileEntry]

    /// Identifier to pass to the engine CLI. Docker containers are addressed by name.
    var cliID: String {
        backend == .dockerEngine ? name : id
    }

    var latestMetric: MetricSample? {
        metricsHistory.last
    }

    var cpuPercentDisplay: Double {
        guard state == .running else { return 0.0 }
        return latestMetric?.cpuPercent ?? (cpuUtilization * 100.0)
    }

    var memoryUsageMBDisplay: Double {
        guard state == .running else { return 0.0 }
        return Double(memoryUsageBytes) / (1024.0 * 1024.0)
    }

    var memoryLimitMBDisplay: Double {
        Double(memoryLimitBytes) / (1024.0 * 1024.0)
    }

    var memoryPercentDisplay: Double {
        guard state == .running, memoryLimitBytes > 0 else { return 0.0 }
        return min(100.0, (Double(memoryUsageBytes) / Double(memoryLimitBytes)) * 100.0)
    }

    var uptimeString: String {
        guard state == .running, let startedAt else { return "Stopped" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        if seconds < 86400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 86400)d \((seconds % 86400) / 3600)h"
    }
}

/// A destructive action waiting for the user's confirmation.
struct PendingConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let action: () -> Void
}

/// Hover state of the container list. It lives outside `ContainerStore`'s published state so that
/// moving the mouse over the list re-renders only the rows, not every view of the app.
final class HoverState: ObservableObject {
    @Published var id: String?
}

// MARK: - Compose Group

/// The containers of one Compose project on one engine (grouped by the
/// `com.docker.compose.project` label that both `docker compose` and Vessel set).
struct ContainerGroup: Identifiable, Equatable {
    let name: String
    let backend: RuntimeBackend
    var containers: [ContainerItem]

    var id: String { "\(backend.rawValue)|\(name)" }

    var runningCount: Int {
        containers.filter { $0.state == .running }.count
    }

    var isBusy: Bool {
        containers.contains { $0.state == .starting || $0.state == .stopping }
    }

    /// Running if every member runs, stopped if none does, paused (amber) for a partial group.
    var state: ContainerState {
        if isBusy { return .starting }
        if runningCount == 0 { return .stopped }
        return runningCount == containers.count ? .running : .paused
    }

    var cpuPercent: Double {
        containers.reduce(0) { $0 + $1.cpuPercentDisplay }
    }

    /// Sum of the members' CPU limits, in cores (0 when no limit is known).
    var cpuLimitCores: Int {
        containers.reduce(0) { $0 + $1.cpuLimitCores }
    }

    var memoryUsageBytes: Int64 {
        containers.filter { $0.state == .running }.reduce(0) { $0 + $1.memoryUsageBytes }
    }

    var memoryLimitBytes: Int64 {
        containers.reduce(0) { $0 + $1.memoryLimitBytes }
    }

    var memoryPercent: Double {
        guard memoryLimitBytes > 0 else { return 0 }
        return min(100, Double(memoryUsageBytes) / Double(memoryLimitBytes) * 100)
    }

    var numProcesses: Int {
        containers.filter { $0.state == .running }.reduce(0) { $0 + $1.numProcesses }
    }

    /// The members' metric histories summed per sampling instant (members are sampled together).
    var metricsHistory: [MetricSample] {
        var buckets: [Date: [MetricSample]] = [:]
        for container in containers {
            for sample in container.metricsHistory {
                buckets[sample.timestamp, default: []].append(sample)
            }
        }
        return buckets.keys.sorted().suffix(60).map { timestamp in
            let samples = buckets[timestamp] ?? []
            return MetricSample(
                timestamp: timestamp,
                cpuPercent: samples.reduce(0) { $0 + $1.cpuPercent },
                cpuCoresUsed: samples.reduce(0) { $0 + $1.cpuCoresUsed },
                memoryUsageBytes: samples.reduce(0) { $0 + $1.memoryUsageBytes },
                memoryLimitBytes: max(1, memoryLimitBytes),
                netRxBytesPerSec: samples.reduce(0) { $0 + $1.netRxBytesPerSec },
                netTxBytesPerSec: samples.reduce(0) { $0 + $1.netTxBytesPerSec },
                blockReadBytesPerSec: samples.reduce(0) { $0 + $1.blockReadBytesPerSec },
                blockWriteBytesPerSec: samples.reduce(0) { $0 + $1.blockWriteBytesPerSec },
                numProcesses: samples.reduce(0) { $0 + $1.numProcesses }
            )
        }
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let stream: String // "stdout" or "stderr"
    let level: LogLevel
    let message: String

    enum LogLevel: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"

        var color: Color {
            switch self {
            case .info: return .blue
            case .warn: return .orange
            case .error: return .red
            case .debug: return .secondary
            }
        }
    }
}

// MARK: - OCI Image Item

struct ImageItem: Identifiable, Equatable {
    var id: String { "\(repository):\(tag)-\(digest)" }
    var repository: String
    var tag: String
    var digest: String
    var sizeBytes: Int64
    var createdAt: Date
    var os: String
    var arch: String
    var layersCount: Int
    var exposedPorts: [Int]
    var defaultCommand: String

    var fullReference: String {
        "\(repository):\(tag)"
    }
}

// MARK: - Volume Item

struct VolumeItem: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var driver: String
    var format: String
    var mountpoint: String
    var sizeBytes: Int64
    var createdAt: Date
    var attachedContainers: [String]
}

// MARK: - Network Item (macOS vmnet)

struct NetworkItem: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var mode: String // "vmnet-shared", "vmnet-bridged", "vmnet-host"
    var subnet: String
    var gateway: String
    var dnsDomain: String
    var interfaceName: String
    var ipv6Enabled: Bool
    var connectedContainers: [String]
}

// MARK: - CLI Command Activity Log

struct CommandActivity: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let command: String
    let durationMs: Int
    let exitCode: Int32
    let outputPreview: String
}

// MARK: - Raw Apple Container CLI JSON Decoders

/// Matches `container stats --format json --no-stream`
struct RawContainerStatJSON: Codable {
    let id: String?
    let memoryUsageBytes: Int64?
    let memoryLimitBytes: Int64?
    let cpuUsageUsec: Int64?
    let networkRxBytes: Int64?
    let networkTxBytes: Int64?
    let blockReadBytes: Int64?
    let blockWriteBytes: Int64?
    let numProcesses: Int?
    let cpuUtilization: Double?
}

// MARK: - Formatting Helpers

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let absBytes = Double(max(0, bytes))
        if absBytes < 1024 {
            return "\(bytes) B"
        } else if absBytes < 1024 * 1024 {
            return String(format: "%.1f KB", absBytes / 1024.0)
        } else if absBytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", absBytes / (1024.0 * 1024.0))
        } else {
            return String(format: "%.2f GB", absBytes / (1024.0 * 1024.0 * 1024.0))
        }
    }

    /// Like `string(_:)`, but renders an unknown (zero) size as an em dash instead of "0 B".
    static func stringOrDash(_ bytes: Int64) -> String {
        bytes > 0 ? string(bytes) : "—"
    }

    static func rateString(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return String(format: "%.0f B/s", max(0, bytesPerSec))
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", bytesPerSec / 1024.0)
        } else {
            return String(format: "%.2f MB/s", bytesPerSec / (1024.0 * 1024.0))
        }
    }
}

