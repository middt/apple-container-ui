import Foundation
import Testing
@testable import AppleContainerUI

/// An in-memory stand-in for the `container` / `docker` CLI, so these tests exercise the same code path as the real CLI.
final class FakeEngine: ContainerRuntime, @unchecked Sendable {
    let backend: RuntimeBackend
    var toolName: String { backend.toolName }
    let binaryPath: String? = "/fake/bin/tool"

    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var order: [String] = []
    private var status: [String: String] = [:]
    private var failures: [String: String] = [:]
    private var systemRunning = true
    private var images: [String] = ["docker.io/library/nginx:alpine"]
    private var volumes: [String] = []
    private var networks: [String] = ["default"]
    private var statsCalls = 0
    private var systemLog = ""
    private var dnsDomains: [String] = []
    private var oneShotJobs: Set<String> = []
    private var unhealthyProbes = 0
    func setDNSDomains(_ domains: [String]) { lock.withLock { dnsDomains = domains } }
    /// Containers with these names stop right after `run`, like a migrator that finished.
    func setOneShotJobs(_ names: Set<String>) { lock.withLock { oneShotJobs = names } }
    /// The next `count` healthcheck probes (`exec`) fail before they start succeeding.
    func failNextProbes(_ count: Int) { lock.withLock { unhealthyProbes = count } }
    func setSystemLog(_ text: String) { lock.withLock { systemLog = text } }

    init(backend: RuntimeBackend = .appleContainer, containers: [(String, String)] = [], project: String? = nil) {
        self.backend = backend
        for (id, state) in containers {
            order.append(id)
            status[id] = state
            if let project {
                composeLabels[id] = ["com.docker.compose.project=\(project)", "com.docker.compose.service=\(id)"]
            }
        }
    }

    var calls: [[String]] { lock.withLock { recorded } }
    func calls(startingWith prefix: String...) -> [[String]] { calls.filter { Array($0.prefix(prefix.count)) == prefix } }
    func fail(_ verb: String, with message: String) { lock.withLock { failures[verb] = message } }
    func state(of id: String) -> String? { lock.withLock { status[id] } }

    func run(_ arguments: [String], workingDirectory: String?, timeout: TimeInterval) async -> CLIExecutionResult {
        let (code, out, err) = lock.withLock { handle(arguments) }
        return CLIExecutionResult(command: displayCommand(arguments), stdout: out, stderr: err, exitCode: code, durationMs: 1)
    }

    private func handle(_ a: [String]) -> (Int32, String, String) {
        recorded.append(a)
        let verb = a.first ?? ""
        let key = (verb == "system" || verb == "image" || verb == "volume" || verb == "network" || verb == "builder" || verb == "compose")
            ? a.filter { !$0.hasPrefix("-") && !$0.hasPrefix("/") }.prefix(2).joined(separator: " ")
            : verb
        if let message = failures[key] ?? failures[verb] {
            return (1, "", message)
        }

        switch verb {
        case "--version":
            return (0, "container CLI version 9.9.9 (test)\n", "")
        case "system":
            switch a.dropFirst().first {
            case "status": return (0, systemRunning ? "{\"status\":\"running\"}\n" : "{\"status\":\"unregistered\"}\n", "")
            case "start": systemRunning = true
            case "stop": systemRunning = false
            case "logs": return (0, systemLog, "")
            case "dns": return (0, "[" + dnsDomains.map { "\"\($0)\"" }.joined(separator: ",") + "]", "")
            default: break
            }
            return (0, "", "")
        case "list":
            let entries = order.map { id in
                """
                {"status":"\(status[id] ?? "stopped")","configuration":{"id":"\(id)","image":{"reference":"nginx:alpine"},\
                "resources":{"cpus":2,"memoryInBytes":536870912},"labels":{\(labelsJSON(for: id))},\
                "publishedPorts":[{"hostAddress":"0.0.0.0","hostPort":18080,"containerPort":80,"proto":"tcp"}]},\
                "networks":[{"network":"default","hostname":"\(id)","address":"192.168.64.7/24"}]}
                """
            }
            return (0, "[" + entries.joined(separator: ",") + "]", "")
        case "ps":
            return (0, order.joined(separator: "\n"), "")
        case "start", "restart":
            for id in a.dropFirst() {
                guard status[id] != nil else { return (1, "", "container \(id) not found") }
                status[id] = "running"
            }
            return (0, "", "")
        case "stop":
            for id in a.dropFirst() where status[id] != nil { status[id] = "stopped" }
            return (0, "", "")
        case "delete", "rm":
            for id in a.dropFirst() where status[id] != nil {
                status[id] = nil
                order.removeAll { $0 == id }
            }
            return (0, "", "")
        case "run":
            guard let nameIndex = a.firstIndex(of: "--name"), nameIndex + 1 < a.count else { return (1, "", "missing --name") }
            let id = a[nameIndex + 1]
            if status[id] != nil { return (1, "", "container \(id) already exists") }
            order.append(id)
            status[id] = oneShotJobs.contains(id) ? "stopped" : "running"
            composeLabels[id] = a.enumerated().compactMap { index, value in
                value == "--label" && index + 1 < a.count ? a[index + 1] : nil
            }
            return (0, id, "")
        case "image":
            switch a.dropFirst().first {
            case "list": return (0, "[" + images.map { "{\"reference\":\"\($0)\"}" }.joined(separator: ",") + "]", "")
            case "pull": images.append(a.last ?? "")
            case "delete": images.removeAll { $0 == a.last }
            default: break
            }
            return (0, "", "")
        case "volume":
            switch a.dropFirst().first {
            case "list": return (0, "[" + volumes.map { "{\"name\":\"\($0)\",\"driver\":\"local\"}" }.joined(separator: ",") + "]", "")
            case "create":
                if volumes.contains(a.last ?? "") { return (1, "", "volume already exists") }
                volumes.append(a.last ?? "")
            case "delete": volumes.removeAll { $0 == a.last }
            default: break
            }
            return (0, "", "")
        case "network":
            switch a.dropFirst().first {
            case "list": return (0, "[" + networks.map { "{\"id\":\"\($0)\",\"config\":{\"mode\":\"nat\"}}" }.joined(separator: ",") + "]", "")
            case "create":
                if networks.contains(a.last ?? "") { return (1, "", "network already exists") }
                networks.append(a.last ?? "")
            case "delete": networks.removeAll { $0 == a.last }
            default: break
            }
            return (0, "", "")
        case "stats":
            statsCalls += 1
            let entries = order.filter { status[$0] == "running" }.map { id in
                "{\"id\":\"\(id)\",\"memoryUsageBytes\":10485760,\"memoryLimitBytes\":536870912,\"cpuUsageUsec\":\(statsCalls * 400_000),\"networkRxBytes\":\(statsCalls * 5000),\"networkTxBytes\":0,\"blockReadBytes\":0,\"blockWriteBytes\":0,\"numProcesses\":3}"
            }
            return (0, "[" + entries.joined(separator: ",") + "]", "")
        case "exec":
            if unhealthyProbes > 0 {
                unhealthyProbes -= 1
                return (1, "", "connection refused")
            }
            return (0, "ran: " + a.dropFirst(2).joined(separator: "|") + "\n", "")
        case "inspect":
            if backend == .dockerEngine {
                let entries = a.dropFirst().map { id in
                    "{\"Name\":\"/\(id)\",\"State\":{\"Status\":\"\(status[id] == "running" ? "running" : "exited")\"},\"Config\":{\"Image\":\"nginx\",\"Labels\":{\(labelsJSON(for: id))}}}"
                }
                return (0, "[" + entries.joined(separator: ",") + "]", "")
            }
            return (0, "[{\"real\":\"inspect of \(a.last ?? "")\"}]\n", "")
        case "compose":
            if a.last == "down", let index = a.firstIndex(of: "--project-name"), index + 1 < a.count {
                let project = a[index + 1]
                for id in order where (composeLabels[id] ?? []).contains("com.docker.compose.project=\(project)") {
                    status[id] = nil
                }
                order.removeAll { status[$0] == nil }
            }
            return (0, "", "")
        case "logs":
            return (0, "started\nWARN disk almost full\n", "")
        default:
            return (0, "", "")
        }
    }

    private var composeLabels: [String: [String]] = [:]

    private func labelsJSON(for id: String) -> String {
        (composeLabels[id] ?? []).compactMap { label -> String? in
            let parts = label.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? "\"\(parts[0])\":\"\(parts[1])\"" : nil
        }.joined(separator: ",")
    }
}

@MainActor
private func makeSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: "vessel-tests-\(UUID().uuidString)")!)
}

@MainActor
private func makeLiveStore(
    _ engine: FakeEngine,
    docker: (any ContainerRuntime)? = nil,
    settings: AppSettings? = nil
) async -> ContainerStore {
    let store = ContainerStore(
        settings: settings ?? makeSettings(),
        appleRuntime: engine,
        dockerRuntime: docker ?? UnavailableRuntime(backend: .dockerEngine),
        enableBackgroundServices: false
    )
    store.portProbe = { _ in }          // unit tests never open sockets
    store.probeSettleNanoseconds = 0
    store.healthPollNanoseconds = 0
    store.isAppActive = { true }
    await store.refreshFromLiveCLI(userInitiated: true)
    return store
}

@MainActor
private func writeComposeFile(_ yaml: String, folder: String = "shop") throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vessel-\(UUID().uuidString)/\(folder)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("docker-compose.yml")
    try yaml.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@MainActor
@Suite struct LiveStoreTests {
    @Test func liveModeShowsOnlyWhatTheCLIReports() async {
        let engine = FakeEngine(containers: [("web", "running"), ("db", "stopped")])
        let store = await makeLiveStore(engine)

        #expect(store.containers.map { $0.name } == ["web", "db"])
        #expect(store.containers.map { $0.state } == [.running, .stopped])
        #expect(store.images.map { $0.fullReference } == ["docker.io/library/nginx:alpine"])
        #expect(store.networks.map { $0.name } == ["default"])
        #expect(store.volumes.isEmpty)
        #expect(store.engineState == .running)
        #expect(store.engineVersion == "container CLI version 9.9.9 (test)")

        // Nothing is invented.
        #expect(store.stacks.isEmpty)
        #expect(store.containers.allSatisfy { $0.macAddress.isEmpty && $0.logs.isEmpty && $0.metricsHistory.isEmpty && $0.fileEntries.isEmpty })
    }

    @Test func emptyEngineMeansEmptyList() async {
        let store = await makeLiveStore(FakeEngine())
        #expect(store.containers.isEmpty)
        #expect(store.selectedContainer == nil)
        #expect(store.clusterMetricsHistory.isEmpty)
    }

    @Test func failedStartDoesNotChangeState() async {
        let engine = FakeEngine(containers: [("db", "stopped")])
        engine.fail("start", with: "insufficient memory for VM")
        let store = await makeLiveStore(engine)

        await store.startContainer(id: "db").value

        #expect(store.containers.first?.state == .stopped)
        #expect(store.containers.first?.startedAt == nil)
        #expect(store.containers.first?.logs.isEmpty == true)
        #expect(store.errorBanner?.contains("container start db") == true)
        #expect(store.errorBanner?.contains("insufficient memory for VM") == true)
        #expect(store.commandLog.first?.exitCode == 1)
    }

    @Test func lifecycleCommandsReachTheEngineAndStateIsReadBack() async {
        let engine = FakeEngine(containers: [("web", "running"), ("db", "stopped")])
        let store = await makeLiveStore(engine)

        await store.startContainer(id: "db").value
        #expect(engine.state(of: "db") == "running")
        #expect(store.containers.first { $0.id == "db" }?.state == .running)

        await store.stopContainer(id: "web").value
        #expect(engine.state(of: "web") == "stopped")
        #expect(store.containers.first { $0.id == "web" }?.state == .stopped)
        #expect(store.errorBanner == nil)

        await store.deleteContainer(id: "web").value
        #expect(engine.state(of: "web") == nil)
        #expect(store.containers.map { $0.id } == ["db"])
        #expect(engine.calls(startingWith: "delete") == [["delete", "--force", "web"]])
    }

    @Test func restartIsARealStopThenStart() async {
        let engine = FakeEngine(containers: [("web", "running")])
        let store = await makeLiveStore(engine)

        await store.restartContainer(id: "web").value

        let lifecycle = engine.calls.filter { $0.first == "stop" || $0.first == "start" }
        #expect(lifecycle == [["stop", "web"], ["start", "web"]])
        #expect(store.containers.first?.state == .running)
    }

    @Test func failedDeleteKeepsTheContainer() async {
        let engine = FakeEngine(containers: [("web", "running")])
        engine.fail("delete", with: "permission denied")
        let store = await makeLiveStore(engine)

        await store.deleteContainer(id: "web").value
        #expect(store.containers.map { $0.id } == ["web"])
        #expect(store.errorBanner != nil)
    }

    @Test func runBuildsARealCommandAndSelectsTheNewContainer() async {
        let engine = FakeEngine()
        let store = await makeLiveStore(engine)

        await store.createAndRunContainer(
            name: "api", image: "ghcr.io/org/api:1", cpus: 2, memoryMB: 512, hostPort: 18080, containerPort: 80,
            portProtocol: .http, mountSource: "/tmp/my data", mountDest: "/data",
            envPairs: ["GREETING": "hello world"], network: "backend", command: "serve --port 80"
        ).value

        #expect(engine.calls(startingWith: "run") == [[
            "run", "--detach", "--name", "api", "--cpus", "2", "--memory", "512M", "--network", "backend",
            "--publish", "18080:80", "--volume", "/tmp/my data:/data", "--env", "GREETING=hello world",
            "ghcr.io/org/api:1", "serve", "--port", "80"
        ]])
        #expect(store.containers.map { $0.name } == ["api"])
        #expect(store.selectedContainerID == "api")
        #expect(store.containers[0].ports[0].isHTTPService)
    }

    @Test func resourceActionsRunRealCommands() async {
        let engine = FakeEngine()
        let store = await makeLiveStore(engine)

        await store.createVolume(name: " data ", sizeGB: 5).value
        #expect(engine.calls(startingWith: "volume", "create") == [["volume", "create", "-s", "5G", "data"]])
        #expect(store.volumes.map { $0.name } == ["data"])

        await store.createNetwork(name: "backend", subnet: "192.168.70.0/24").value
        #expect(engine.calls(startingWith: "network", "create") == [["network", "create", "--subnet", "192.168.70.0/24", "backend"]])
        #expect(store.networks.map { $0.name } == ["default", "backend"])

        await store.pullImage(reference: "redis:7").value
        #expect(engine.calls(startingWith: "image", "pull") == [["image", "pull", "redis:7"]])
        #expect(store.images.count == 2)
        #expect(store.busyLabels.isEmpty)

        await store.deleteImage(store.images[1]).value
        await store.deleteVolume(store.volumes[0]).value
        await store.deleteNetwork(store.networks[1]).value
        #expect(engine.calls(startingWith: "image", "delete") == [["image", "delete", "redis:7"]])
        #expect(engine.calls(startingWith: "volume", "delete") == [["volume", "delete", "data"]])
        #expect(engine.calls(startingWith: "network", "delete") == [["network", "delete", "backend"]])
        #expect(store.images.count == 1 && store.volumes.isEmpty && store.networks.map { $0.name } == ["default"])

        // The default network is never deleted.
        await store.deleteNetwork(store.networks[0]).value
        #expect(engine.calls(startingWith: "network", "delete").count == 1)
    }

    @Test func failedResourceActionChangesNothing() async {
        let engine = FakeEngine()
        engine.fail("volume create", with: "disk full")
        let store = await makeLiveStore(engine)

        await store.createVolume(name: "data", sizeGB: 5).value
        #expect(store.volumes.isEmpty)
        #expect(store.errorBanner?.contains("disk full") == true)
    }

    @Test func engineControlsRunRealCommands() async {
        let engine = FakeEngine(containers: [("web", "running")])
        let store = await makeLiveStore(engine)

        await store.toggleSystemEngine().value
        #expect(engine.calls(startingWith: "system", "stop").count == 1)
        #expect(store.engineState == .stopped)
        #expect(store.containers.isEmpty)

        await store.toggleSystemEngine().value
        #expect(engine.calls(startingWith: "system", "start") == [["system", "start", "--enable-kernel-install"]])
        #expect(store.engineState == .running)
        #expect(store.containers.map { $0.name } == ["web"])

    }

    @Test func failedEngineStopKeepsEngineRunning() async {
        let engine = FakeEngine()
        engine.fail("system stop", with: "apiserver busy")
        let store = await makeLiveStore(engine)

        await store.toggleSystemEngine().value
        #expect(store.engineState == .running)
        #expect(store.errorBanner?.contains("apiserver busy") == true)
    }

    @Test func execKeepsQuotedArgumentsTogether() async {
        let engine = FakeEngine(containers: [("web", "running")])
        let store = await makeLiveStore(engine)

        await store.runQuickExec(for: store.containers[0], command: "sh -c 'echo a b' \"x y\"").value

        #expect(engine.calls(startingWith: "exec") == [["exec", "web", "sh", "-c", "echo a b", "x y"]])
        #expect(store.execOutputHistory.last == "$ container exec web sh -c 'echo a b' 'x y'\nran: sh|-c|echo a b|x y")
    }

    @Test func detailTabsShowRealOutput() async {
        let engine = FakeEngine(containers: [("web", "running")])
        let store = await makeLiveStore(engine)
        store.selectedSidebar = .containers
        store.selectedContainerID = "web"

        store.selectedDetailTab = .rawJSON
        await store.fetchVisibleDetails()
        #expect(store.inspectJSONByContainerID["web"] == "[{\"real\":\"inspect of web\"}]")

        store.selectedDetailTab = .logs
        await store.fetchVisibleDetails()
        #expect(store.containers[0].logs.map { $0.message } == ["started", "WARN disk almost full"])
        #expect(store.containers[0].logs[1].level == .warn)
        let firstIDs = store.containers[0].logs.map { $0.id }
        await store.fetchVisibleDetails()
        #expect(store.containers[0].logs.map { $0.id } == firstIDs)      // unchanged output is not re-published
    }

    @Test func statsUseElapsedTimeAndSurviveARefresh() async throws {
        let engine = FakeEngine(containers: [("web", "running"), ("db", "stopped")])
        let store = await makeLiveStore(engine)

        await store.pollLiveStats()
        try await Task.sleep(nanoseconds: 400_000_000)
        await store.pollLiveStats()

        let web = try #require(store.containers.first { $0.id == "web" })
        #expect(web.metricsHistory.count == 2)
        #expect(web.metricsHistory[0].cpuPercent == 0)                 // no previous sample: no rate yet
        // 400 000 µs of CPU over ~0.4 s of wall time is roughly one core, never the old fixed "/ 2 s".
        #expect((15...100).contains(web.metricsHistory[1].cpuPercent))
        #expect((1_800...12_500).contains(web.metricsHistory[1].netRxBytesPerSec))
        #expect(web.memoryUsageBytes == 10_485_760)
        #expect(store.containers.first { $0.id == "db" }?.metricsHistory.isEmpty == true)

        await store.refreshFromLiveCLI(userInitiated: false)
        #expect(store.containers.first { $0.id == "web" }?.metricsHistory.count == 2)
    }

    @Test func refreshRequestedDuringARefreshIsNotLost() async {
        let engine = FakeEngine(containers: [("web", "running")])
        let store = await makeLiveStore(engine)
        let before = engine.calls(startingWith: "list").count

        async let first: Void = store.refreshFromLiveCLI(userInitiated: false)
        async let second: Void = store.refreshFromLiveCLI(userInitiated: false)
        _ = await (first, second)

        #expect(engine.calls(startingWith: "list").count == before + 2)
    }
}

@MainActor
@Suite struct ComposeStoreTests {
    static let yaml = """
    services:
      web:
        image: nginx:alpine
        ports:
          - "18080:80/http"
        depends_on: [db]
      db:
        image: postgres:17
        volumes:
          - pgdata:/var/lib/postgresql/data
    """

    @Test func stackUpOnAppleContainerExecutesThePlan() async throws {
        let engine = FakeEngine()
        let store = await makeLiveStore(engine)
        store.importComposeFile(at: try writeComposeFile(Self.yaml))
        let stack = try #require(store.stacks.first)
        #expect(stack.name == "shop" && stack.status == .stopped)

        await store.deployStack(stack).value

        let commands = engine.calls.filter { ["network", "volume", "run"].contains($0.first ?? "") && $0.dropFirst().first != "list" }
        #expect(commands.map { $0.prefix(2).joined(separator: " ") } == ["network create", "volume create", "run --detach", "run --detach"])
        #expect(commands[2].contains("shop-db-1") && commands[3].contains("shop-web-1"))     // dependency order
        #expect(commands[3].contains("18080:80"))                                            // "/http" hint is not sent to the CLI
        #expect(commands[1] == ["volume", "create", "shop_pgdata"])

        #expect(store.stacks[0].status == .running)
        #expect(Set(store.containers(in: store.stacks[0]).map { $0.name }) == ["shop-db-1", "shop-web-1"])
        #expect(store.container(for: store.stacks[0].services[1], in: store.stacks[0])?.ports.first?.isHTTPService == true)
        #expect(store.errorBanner == nil)

        // Deploying again replaces the stale containers instead of colliding on --name.
        await store.deployStack(store.stacks[0]).value
        #expect(engine.calls(startingWith: "delete").last == ["delete", "--force", "shop-db-1", "shop-web-1"])
        #expect(store.errorBanner == nil)
        #expect(store.stacks[0].status == .running)

        await store.stopStack(store.stacks[0]).value
        #expect(engine.calls(startingWith: "stop").last == ["stop", "shop-web-1", "shop-db-1"])
        #expect(engine.calls(startingWith: "network", "delete") == [["network", "delete", "shop_default"]])
        #expect(store.stacks[0].status == .stopped)
        #expect(store.containers.isEmpty)
    }

    static let gatedYAML = """
    services:
      app:
        image: app
        depends_on:
          db:
            condition: service_healthy
          migrate:
            condition: service_completed_successfully
      db:
        image: postgres
        healthcheck:
          test: ["CMD", "pg_isready"]
          interval: 1s
          timeout: 1s
          retries: 2
      migrate:
        image: migrator
        depends_on:
          db:
            condition: service_healthy
    networks:
      backbone:
        external: true
    """

    @Test func startupWaitsForHealthAndCompletionAndUsesTheDNSDomain() async throws {
        let engine = FakeEngine()
        engine.setDNSDomains(["vnext.test"])
        engine.setOneShotJobs(["shop-migrate-1"])
        engine.failNextProbes(3)                       // the database needs a moment
        let store = await makeLiveStore(engine)
        #expect(store.dnsDomain == "vnext.test")
        store.importComposeFile(at: try writeComposeFile(Self.gatedYAML))
        #expect(store.stacks[0].networkName == "backbone" && store.stacks[0].networkIsExternal)
        #expect(!store.stacks[0].warnings.contains { $0.contains("DNS") })

        await store.deployStack(store.stacks[0]).value

        #expect(store.errorBanner == nil, "\(store.errorBanner ?? "")")
        #expect(store.stacks[0].status == .running)
        let runs = engine.calls(startingWith: "run").map { $0[$0.firstIndex(of: "--name")! + 1] }
        #expect(runs == ["shop-db-1", "shop-migrate-1", "shop-app-1"])
        #expect(engine.calls(startingWith: "exec", "shop-db-1", "pg_isready").count >= 4)       // retried until healthy
        let dbRun = try #require(engine.calls(startingWith: "run").first)
        #expect(dbRun.contains("backbone,alias=db.backbone.vnext.test,alias=shop-db-1.backbone.vnext.test"))
        #expect(store.busyLabels.isEmpty)

        // The external network survives "Stack Down".
        await store.stopStack(store.stacks[0]).value
        #expect(engine.calls(startingWith: "network", "delete").isEmpty)
    }

    @Test func unhealthyDependencyStopsTheDeployment() async throws {
        let engine = FakeEngine()
        engine.fail("exec", with: "connection refused")        // the database never becomes healthy
        let store = await makeLiveStore(engine)
        store.healthPollNanoseconds = 100_000_000
        store.importComposeFile(at: try writeComposeFile(Self.gatedYAML))
        #expect(store.stacks[0].warnings.contains { $0.contains("sudo container system dns create") })   // no DNS domain

        await store.deployStack(store.stacks[0]).value

        #expect(engine.calls(startingWith: "run").count == 1)                 // only the database was started
        #expect(store.errorBanner?.contains("did not become healthy") == true)
        #expect(store.stacks[0].status != .running || store.containers.count == 1)
    }

    @Test func failingStepAbortsThePlanAndIsReported() async throws {
        let engine = FakeEngine()
        engine.fail("run", with: "image not found: postgres:17")
        let store = await makeLiveStore(engine)
        store.importComposeFile(at: try writeComposeFile(Self.yaml))

        await store.deployStack(store.stacks[0]).value

        #expect(engine.calls(startingWith: "run").count == 1)        // the second service is never attempted
        #expect(store.stacks[0].status == .stopped)
        #expect(store.stacks[0].lastDeployedAt == nil)
        #expect(store.containers.isEmpty)
        #expect(store.errorBanner?.contains("image not found") == true)
    }

    @Test func dockerTargetRunsComposeUpAndDown() async throws {
        let docker = FakeEngine(backend: .dockerEngine)
        let store = await makeLiveStore(FakeEngine(), docker: docker)
        let source = try writeComposeFile(Self.yaml, folder: "My Shop")
        store.importComposeFile(at: source)
        store.updateStackBackend(stackID: store.stacks[0].id, backend: .dockerEngine)

        await store.deployStack(store.stacks[0]).value

        let up = try #require(docker.calls(startingWith: "compose").first)
        #expect(Array(up.prefix(3)) == ["compose", "--project-name", "my-shop"])
        #expect(Array(up.suffix(2)) == ["up", "--detach"])
        let projectDirectory = up[up.firstIndex(of: "--project-directory")! + 1]
        #expect(projectDirectory == source.deletingLastPathComponent().path)
        let written = try String(contentsOfFile: up[up.firstIndex(of: "--file")! + 1], encoding: .utf8)
        #expect(written.contains("\"18080:80\"") && !written.contains("/http"))
        #expect(store.commandLog.contains { $0.command.hasPrefix("docker compose") })

        await store.stopStack(store.stacks[0]).value
        #expect(docker.calls(startingWith: "compose").last == ["compose", "--project-name", "my-shop", "down"])
        #expect(store.stacks[0].status == .stopped)
    }

    @Test func failedComposeDownKeepsTheStackRunning() async throws {
        let docker = FakeEngine(backend: .dockerEngine)
        let store = await makeLiveStore(FakeEngine(), docker: docker)
        store.importComposeFile(at: try writeComposeFile(Self.yaml))
        store.updateStackBackend(stackID: store.stacks[0].id, backend: .dockerEngine)
        await store.deployStack(store.stacks[0]).value
        store.stacks[0].status = .running

        docker.fail("compose", with: "daemon not reachable")
        await store.stopStack(store.stacks[0]).value
        #expect(store.errorBanner?.contains("daemon not reachable") == true)
    }

    @Test func warningsAndPersistence() async throws {
        let settings = makeSettings()
        let store = await makeLiveStore(FakeEngine(), settings: settings)
        store.importComposeFile(at: try writeComposeFile("""
        services:
          app:
            image: "app:${VESSEL_TEST_UNSET_VARIABLE}"
            restart: always
        """))
        #expect(store.stacks[0].warnings.count == 2)

        store.language = .tr
        let reopened = await makeLiveStore(FakeEngine(), settings: settings)
        #expect(reopened.language == .tr)
        #expect(reopened.stacks.map { $0.name } == ["shop"])
        #expect(reopened.stacks[0].services.map { $0.name } == ["app"])

        reopened.removeStack(reopened.stacks[0])
        #expect(settings.stacks.isEmpty)
    }
}

@MainActor
@Suite struct GroupTests {
    private func makeStore() async -> (ContainerStore, FakeEngine) {
        let engine = FakeEngine(containers: [("web", "running"), ("db", "running"), ("worker", "stopped")], project: "shop")
        _ = await engine.run(["run", "--detach", "--name", "solo", "alpine"], workingDirectory: nil, timeout: 1)
        return (await makeLiveStore(engine), engine)
    }

    @Test func containersAreGroupedByComposeProject() async {
        let (store, _) = await makeStore()
        let groups = store.filteredContainerGroups
        #expect(groups.map { $0.name } == ["shop"])
        #expect(groups[0].id == "apple/container|shop")
        #expect(groups[0].containers.map { $0.name } == ["web", "db", "worker"])
        #expect(groups[0].runningCount == 2 && groups[0].state == .paused)       // partially running
        #expect(store.filteredStandaloneContainers.map { $0.name } == ["solo"])

        // The list filter narrows the rows, the group itself stays complete.
        store.containerFilter = .stopped
        #expect(store.filteredContainerGroups[0].containers.map { $0.name } == ["worker"])
        #expect(store.group(id: "apple/container|shop")?.containers.count == 3)
    }

    @Test func groupUsageIsTheSumOfItsMembers() async throws {
        let (store, _) = await makeStore()
        await store.pollLiveStats()
        try await Task.sleep(nanoseconds: 300_000_000)
        await store.pollLiveStats()

        let group = try #require(store.group(id: "apple/container|shop"))
        let running = group.containers.filter { $0.state == .running }
        #expect(group.memoryUsageBytes == 2 * 10_485_760)
        #expect(group.memoryLimitBytes == 3 * 536_870_912)
        #expect(group.cpuPercent == running.reduce(0) { $0 + $1.cpuPercentDisplay })
        #expect(group.cpuPercent > 0)

        let history = group.metricsHistory
        #expect(history.count == 2)                       // one aggregate sample per poll, not per member
        #expect(history[1].cpuPercent == running.reduce(0) { $0 + $1.metricsHistory[1].cpuPercent })
        #expect(history[1].memoryUsageBytes == 2 * 10_485_760)
        #expect(history[1].numProcesses == 6)
    }

    @Test func stopStartRestartAndDeleteTheWholeGroup() async {
        let (store, engine) = await makeStore()
        let id = "apple/container|shop"

        await store.stopGroup(id).value
        #expect(engine.calls(startingWith: "stop").last == ["stop", "db", "web"])     // one command, running members only
        #expect(store.group(id: id)?.runningCount == 0)
        #expect(engine.state(of: "solo") == "running")                               // other containers untouched

        await store.startGroup(id).value
        #expect(engine.calls(startingWith: "start").map { $0[1] } == ["web", "db", "worker"])
        #expect(store.group(id: id)?.state == .running)

        await store.restartGroup(id).value
        #expect(engine.calls(startingWith: "stop").last == ["stop", "worker", "db", "web"])
        #expect(store.group(id: id)?.runningCount == 3)

        store.selectGroup(id)
        await store.deleteGroup(id).value
        #expect(engine.calls(startingWith: "delete").last == ["delete", "--force", "web", "db", "worker"])
        #expect(store.group(id: id) == nil)
        #expect(store.selectedGroupID == nil)
        #expect(store.containers.map { $0.name } == ["solo"])
        #expect(store.errorBanner == nil)
    }

    @Test func failedGroupStopLeavesMembersRunning() async {
        let (store, engine) = await makeStore()
        engine.fail("stop", with: "timeout waiting for VM")

        await store.stopGroup("apple/container|shop").value
        #expect(store.group(id: "apple/container|shop")?.runningCount == 2)
        #expect(store.errorBanner?.contains("timeout waiting for VM") == true)
    }

    @Test func dockerGroupsUseDockerCommands() async {
        let docker = FakeEngine(backend: .dockerEngine, containers: [("shop-web-1", "running"), ("shop-db-1", "exited")], project: "shop")
        let store = await makeLiveStore(FakeEngine(), docker: docker)
        let id = "docker|shop"
        #expect(store.group(id: id)?.containers.count == 2)

        await store.startGroup(id).value
        #expect(docker.calls(startingWith: "start") == [["start", "shop-db-1"]])
        await store.restartGroup(id).value
        #expect(docker.calls(startingWith: "restart") == [["restart", "shop-web-1", "shop-db-1"]])
        await store.deleteGroup(id).value
        #expect(docker.calls(startingWith: "compose") == [["compose", "--project-name", "shop", "down"]])
        #expect(store.group(id: id) == nil)
    }

    @Test func stackDeploymentShowsUpAsAGroupInDependencyOrder() async throws {
        let engine = FakeEngine()
        let store = await makeLiveStore(engine)
        store.importComposeFile(at: try writeComposeFile(ComposeStoreTests.yaml))
        await store.deployStack(store.stacks[0]).value

        let group = try #require(store.filteredContainerGroups.first)
        #expect(group.name == "shop" && group.containers.count == 2)
        #expect(store.stack(for: group)?.id == store.stacks[0].id)

        await store.stopGroup(group.id).value
        await store.startGroup(group.id).value
        #expect(engine.calls(startingWith: "start").map { $0[1] } == ["shop-db-1", "shop-web-1"])   // db before web

        await store.deleteGroup(group.id).value
        #expect(engine.calls(startingWith: "network", "delete") == [["network", "delete", "shop_default"]])
        #expect(store.stacks[0].status == .stopped)
    }

    @Test func localNetworkDenialIsDetectedProactivelyAndClearsAfterTheGrant() async {
        let (store, engine) = await makeStore()
        var probedPorts: [Int] = []
        store.portProbe = { probedPorts.append($0) }
        let denied = """
        Error container-runtime-linux: backend - connect failed: connect(descriptor:addr:size:): No route to host) (errno: 65) [uuid=web] [proxy=[IPv4]127.0.0.1:18080]
        Error container-runtime-linux: backend - connect failed: connect(descriptor:addr:size:): No route to host) (errno: 65) [uuid=deleted-long-ago]
        """

        // Vessel probes each running container's published port itself — no browser attempt needed.
        engine.setSystemLog(denied)
        await store.verifyPublishedPorts()
        #expect(probedPorts.count == 3)                                   // web, db, solo (worker is stopped)
        #expect(store.localNetworkBlockedContainers == ["web"])           // only containers that exist and run

        // Already verified containers are not probed again on every tick…
        await store.verifyPublishedPorts()
        #expect(probedPorts.count == 3)
        #expect(store.localNetworkBlockedContainers == ["web"])           // …and the warning does not fade by itself

        // …but flagged ones are re-probed periodically, which clears the warning after the grant.
        engine.setSystemLog("")
        await store.verifyPublishedPorts(recheckBlocked: true)
        #expect(probedPorts.count == 4)
        #expect(store.localNetworkBlockedContainers.isEmpty)

        // A restarted container is probed again.
        await store.stopContainer(id: "web").value
        await store.startContainer(id: "web").value
        await store.verifyPublishedPorts()
        #expect(probedPorts.count == 4 || probedPorts.count == 5)
    }

    @Test func destructiveActionsAskFirst() async {
        let (store, engine) = await makeStore()

        store.requestDeleteContainer(store.containers.first { $0.id == "web" }!)      // running: ask
        #expect(store.pendingConfirmation != nil)
        #expect(engine.calls(startingWith: "delete").isEmpty)
        store.pendingConfirmation = nil

        store.requestDeleteGroup("apple/container|shop")
        #expect(store.pendingConfirmation?.title.contains("shop") == true)
        store.pendingConfirmation = nil

        store.requestToggleSystemEngine()                                              // containers are running: ask
        #expect(store.pendingConfirmation != nil)
        #expect(engine.calls(startingWith: "system", "stop").isEmpty)
        store.pendingConfirmation?.action()
        store.pendingConfirmation = nil
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(engine.calls(startingWith: "system", "stop").count == 1)
    }

    @Test func backgroundPollingIsThrottled() async {
        let (store, engine) = await makeStore()
        store.isAppActive = { false }
        let before = engine.calls(startingWith: "stats").count
        for _ in 0..<10 { await store.tickTelemetry() }
        #expect(engine.calls(startingWith: "stats").count == before + 1)               // every 10 s instead of every 2 s

        store.isAppActive = { true }
        for _ in 0..<10 { await store.tickTelemetry() }
        #expect(engine.calls(startingWith: "stats").count == before + 6)
    }

    @Test func httpProbeReportsTheRealConnectionFailure() async throws {
        let (store, _) = await makeStore()
        let container = try #require(store.containers.first)
        let port = PortMapping(hostIP: "0.0.0.0", hostPort: 18473, containerPort: 80, protocolType: "http")

        await store.testHTTPOutput(for: container, port: port).value
        #expect(store.httpTestResponsePreview.contains("curl: (7)"))
        #expect(store.commandLog.first?.exitCode == 7)
    }

    @Test func missingCLIIsReportedInsteadOfShowingSampleData() async {
        let store = ContainerStore(
            settings: makeSettings(),
            appleRuntime: UnavailableRuntime(backend: .appleContainer),
            dockerRuntime: UnavailableRuntime(backend: .dockerEngine),
            enableBackgroundServices: false
        )
        await store.refreshFromLiveCLI(userInitiated: true)
        #expect(!store.isContainerCLIAvailable)
        #expect(store.containers.isEmpty && store.images.isEmpty && store.stacks.isEmpty)
        #expect(store.engineState == .stopped)
        #expect(store.errorBanner?.contains("not found") == true)
    }
}

/// Read-only checks against the real `container` binary, when one is installed.
/// Nothing here starts services, pulls images or creates containers.
@MainActor
@Suite(.enabled(if: ContainerCLIService.detectBinaryPath() != nil))
struct RealCLITests {
    @Test func storeReflectsTheRealEngineWithoutInventingData() async throws {
        let path = try #require(ContainerCLIService.detectBinaryPath())
        let runtime = LiveCLIRuntime(backend: .appleContainer, path: path)
        let store = ContainerStore(
            settings: makeSettings(),
            appleRuntime: runtime,
            dockerRuntime: UnavailableRuntime(backend: .dockerEngine),
            enableBackgroundServices: false
        )
        await store.refreshFromLiveCLI(userInitiated: true)

        #expect(store.engineVersion.hasPrefix("container CLI version"))
        #expect(store.engineState == .running || store.engineState == .stopped)
        #expect(store.commandLog.allSatisfy { $0.command.hasPrefix("container ") })

        if store.engineState == .running {
            // Whatever the CLI lists as running must be running, with an address, in the store.
            let quiet = await runtime.run(["list", "--quiet"])
            let runningIDs = quiet.stdout.split(whereSeparator: \.isNewline).map(String.init)
            for id in runningIDs {
                let item = store.containers.first { $0.id == id }
                #expect(item?.state == .running, "\(id) should be running")
                #expect(item?.ipAddress.isEmpty == false, "\(id) should have an IP address")
            }
            #expect(store.networks.contains { $0.name == "default" && !$0.subnet.isEmpty })
            await store.pollLiveStats()
            #expect(store.containers.filter { $0.state == .running }.allSatisfy { $0.metricsHistory.count == 1 })
        }

        if store.engineState == .stopped {
            #expect(store.containers.isEmpty && store.images.isEmpty && store.volumes.isEmpty && store.networks.isEmpty)
            #expect(store.errorBanner == nil)       // a stopped engine is a state, not an error
        }
    }
}

/// End-to-end run against the real `container` engine: deploys a tiny Compose stack, drives it
/// as a group and removes everything again. It creates real containers, so it only runs when
/// asked for: `VESSEL_E2E=1 ./scripts/test.sh`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VESSEL_E2E"] == "1" && ContainerCLIService.detectBinaryPath() != nil))
struct EndToEndTests {
    @Test func composeStackLifecycleOnTheRealEngine() async throws {
        let path = try #require(ContainerCLIService.detectBinaryPath())
        let store = ContainerStore(
            settings: makeSettings(),
            appleRuntime: LiveCLIRuntime(backend: .appleContainer, path: path),
            dockerRuntime: UnavailableRuntime(backend: .dockerEngine),
            enableBackgroundServices: false
        )
        await store.refreshFromLiveCLI(userInitiated: true)
        try #require(store.engineState == .running, "start the container system first")

        let folder = "vessel-e2e-\(Int.random(in: 1000...9999))"
        store.importComposeFile(at: try writeComposeFile("""
        services:
          one:
            image: alpine:3.21
            command: sleep 600
            cpus: 1
            mem_limit: 256m
          two:
            image: alpine:3.21
            command: ["sleep", "600"]
            cpus: 1
            mem_limit: 256m
            environment:
              GREETING: hello world
            depends_on: [one]
        """, folder: folder))
        let stackName = store.stacks[0].name
        let groupID = "apple/container|\(stackName)"

        await store.deployStack(store.stacks[0]).value
        #expect(store.errorBanner == nil, "\(store.errorBanner ?? "")")
        #expect(store.stacks[0].status == .running)

        // Whatever happens next, leave nothing behind.
        defer {
            let names = store.stacks.first.map { stack in stack.services.map { ComposeOrchestrator.containerName(stackName: stack.name, service: $0) } } ?? []
            Task {
                _ = await store.appleRuntime.run(["delete", "--force"] + names)
                _ = await store.appleRuntime.run(["network", "delete", "\(stackName)_default"])
            }
        }

        let group = try #require(store.group(id: groupID), "containers must be grouped by the compose label")
        #expect(group.containers.count == 2 && group.runningCount == 2)
        #expect(group.containers.allSatisfy { !$0.ipAddress.isEmpty && $0.networkName == "\(stackName)_default" })
        #expect(group.containers.first { $0.name.hasSuffix("-two-1") }?.env["GREETING"] == "hello world")

        await store.pollLiveStats()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await store.pollLiveStats()
        let measured = try #require(store.group(id: groupID))
        #expect(measured.memoryUsageBytes > 0)
        #expect(measured.metricsHistory.count == 2)

        // Detail tabs show real data.
        let member = measured.containers[0]
        store.selectedSidebar = .containers
        store.selectContainer(member.id)
        store.selectedDetailTab = .rawJSON
        await store.fetchVisibleDetails()
        #expect(store.inspectJSONByContainerID[member.id]?.contains(member.name) == true)
        store.selectedDetailTab = .files
        await store.fetchVisibleDetails()
        #expect(store.containers.first { $0.id == member.id }?.fileEntries.contains { $0.name == "etc" } == true)
        await store.runQuickExec(for: member, command: #"sh -c "echo 'a  b'""#).value
        #expect(store.execOutputHistory.last?.hasSuffix("a  b") == true)

        await store.stopGroup(groupID).value
        #expect(store.group(id: groupID)?.runningCount == 0)
        await store.startGroup(groupID).value
        #expect(store.group(id: groupID)?.runningCount == 2)
        await store.restartGroup(groupID).value
        #expect(store.group(id: groupID)?.runningCount == 2)

        await store.deleteGroup(groupID).value
        #expect(store.group(id: groupID) == nil)
        #expect(store.stacks[0].status == .stopped)
        #expect(!store.networks.contains { $0.name == "\(stackName)_default" })
        #expect(store.errorBanner == nil, "\(store.errorBanner ?? "")")
    }
}

/// Headless "Stack Up": imports a Compose file into Vessel's own settings and deploys it on the
/// real engine through the same code path as the UI. Used by `scripts/stack-up.sh <compose-file>`.
/// The containers keep running and the stack shows up in the Vessel app (restart it to reload).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VESSEL_STACK_UP"] != nil))
struct StackUpTool {
    @Test func stackUp() async throws {
        let composePath = try #require(ProcessInfo.processInfo.environment["VESSEL_STACK_UP"])
        let binary = try #require(ContainerCLIService.detectBinaryPath())
        let defaults = try #require(UserDefaults(suiteName: "com.vessel.applecontainer.studio"))
        let store = ContainerStore(
            settings: AppSettings(defaults: defaults),
            appleRuntime: LiveCLIRuntime(backend: .appleContainer, path: binary),
            dockerRuntime: UnavailableRuntime(backend: .dockerEngine),
            enableBackgroundServices: false
        )
        await store.refreshFromLiveCLI(userInitiated: true)
        try #require(store.engineState == .running, "start the container system first")

        if let existing = store.stacks.first(where: { $0.filePath == composePath }) {
            // Deploy what is on disk now, not the copy stored at import time.
            store.updateStackYAML(stackID: existing.id, newYAML: try String(contentsOfFile: composePath, encoding: .utf8))
        } else {
            store.importComposeFile(at: URL(fileURLWithPath: composePath))
        }
        let stack = try #require(store.stacks.first { $0.filePath == composePath })
        print("== stack \(stack.name): \(stack.services.count) services on network \(stack.networkName), DNS domain \(store.dnsDomain ?? "none")")
        for warning in stack.warnings { print("   warning: \(warning)") }

        await store.deployStack(stack).value

        for entry in store.commandLog.reversed() where entry.command.hasPrefix("container run") || entry.command.hasPrefix("#") || entry.command.contains(" exec ") || entry.exitCode != 0 {
            let name = entry.command.components(separatedBy: " --name ").dropFirst().first?.components(separatedBy: " ").first ?? ""
            print("   [exit \(entry.exitCode), \(entry.durationMs / 1000)s] \(name.isEmpty ? String(entry.command.prefix(110)) : "run " + name) \(entry.exitCode == 0 ? "" : "-> " + entry.outputPreview)")
        }
        #expect(store.errorBanner == nil, "\(store.errorBanner ?? "")")
        #expect(store.stacks.first { $0.filePath == composePath }?.status == .running)
    }
}
