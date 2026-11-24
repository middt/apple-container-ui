import Foundation
import Testing
@testable import AppleContainerUI

@Suite struct MiniYAMLTests {
    @Test func parsesNestedMapsAndListsAtAnyIndentation() {
        let yaml = """
        services:
            web:
                image: nginx
                ports:
                    - "8080:80"
                    - 9090:90
        """
        let root = MiniYAML.parse(yaml)
        #expect(root["services"]?["web"]?["image"]?.string == "nginx")
        #expect(root["services"]?["web"]?["ports"]?.list?.compactMap { $0.string } == ["8080:80", "9090:90"])
    }

    @Test func listAtSameIndentAsParentKey() {
        let root = MiniYAML.parse("ports:\n- a\n- b\nname: x\n")
        #expect(root["ports"]?.list?.count == 2)
        #expect(root["name"]?.string == "x")
    }

    @Test func commentsAreQuoteAware() {
        let root = MiniYAML.parse("""
        a: "value # not a comment"   # real comment
        b: repo#tag
        c: 'it''s # fine'
        d: plain # comment
        """)
        #expect(root["a"]?.string == "value # not a comment")
        #expect(root["b"]?.string == "repo#tag")
        #expect(root["c"]?.string == "it's # fine")
        #expect(root["d"]?.string == "plain")
    }

    @Test func flowCollectionsAndListOfMaps() {
        let root = MiniYAML.parse("""
        cmd: ["sh", "-c", "echo a, b"]
        limits: {cpus: "0.5", memory: 256M}
        ports:
          - target: 80
            published: 8080
          - target: 443
            published: 8443
        """)
        #expect(root["cmd"]?.list?.compactMap { $0.string } == ["sh", "-c", "echo a, b"])
        #expect(root["limits"]?["memory"]?.string == "256M")
        #expect(root["ports"]?.list?.count == 2)
        #expect(root["ports"]?.list?[1]["published"]?.string == "8443")
    }

    @Test func blockScalarsAnchorsAndMergeKeys() {
        let root = MiniYAML.parse("""
        x-base: &base
          restart: always
          image: base
        svc:
          <<: *base
          image: override
        script: |
          line one
          # not a comment
          line two
        next: after
        """)
        #expect(root["svc"]?["restart"]?.string == "always")
        #expect(root["svc"]?["image"]?.string == "override")
        #expect(root["script"]?.string == "line one\n# not a comment\nline two")
        #expect(root["next"]?.string == "after")
    }

    @Test func multiLineFlowCollections() {
        let root = MiniYAML.parse("""
        command: [
          "./daprd",
          "--app-id", "app [1]",   # comment
          "--port", "5000"
        ]
        test:
          [
            "CMD",
            "wget"
          ]
        after: x
        """)
        #expect(root["command"]?.list?.compactMap { $0.string } == ["./daprd", "--app-id", "app [1]", "--port", "5000"])
        #expect(root["test"]?.list?.compactMap { $0.string } == ["CMD", "wget"])
        #expect(root["after"]?.string == "x")
    }

    @Test func blockScalarAsListItem() {
        let root = MiniYAML.parse("""
        command:
          - |
            echo "one"
            run --url "$$URL"
          - second
        after: x
        """)
        #expect(root["command"]?.list?.compactMap { $0.string } == ["echo \"one\"\nrun --url \"$$URL\"", "second"])
        #expect(root["after"]?.string == "x")
    }

    @Test func duplicateKeysDoNotCrash() {
        let root = MiniYAML.parse("a: 1\na: 2\n")
        #expect(root["a"]?.string == "2")
        #expect(root.map?.keys == ["a"])
    }

    @Test func garbageInputDoesNotCrash() {
        for text in ["", "\n\n", ":", "- - -", "a:\n\t- b", "{", "key: [unterminated", "::::", "- a: b\n   c: d\n e"] {
            _ = MiniYAML.parse(text)
        }
    }
}

@Suite struct ComposeParsingTests {
    @Test func fourSpaceIndentedFileParses() {
        let services = ComposeOrchestrator.parseServices(from: """
        services:
            db:
                image: postgres:17
                ports:
                    - "5432:5432"
        """)
        #expect(services.map { $0.name } == ["db"])
        #expect(services[0].image == "postgres:17")
        #expect(services[0].ports.first?.hostPort == 5432)
    }

    @Test func hashInValuesIsKept() {
        let services = ComposeOrchestrator.parseServices(from: """
        services:
          app:
            image: repo/app
            environment:
              - PASSWORD=p#ss
              - "URL=http://x/#anchor"
            command: sh -c "echo '# hi'"
        """)
        #expect(services[0].environment["PASSWORD"] == "p#ss")
        #expect(services[0].environment["URL"] == "http://x/#anchor")
        #expect(services[0].command == ["sh", "-c", "echo '# hi'"])
    }

    @Test func portForms() {
        #expect(ComposeOrchestrator.parsePortMappings("127.0.0.1:8080:80").first?.hostIP == "127.0.0.1")
        #expect(ComposeOrchestrator.parsePortMappings("127.0.0.1:8080:80").first?.publishArgument == "127.0.0.1:8080:80")
        #expect(ComposeOrchestrator.parsePortMappings("[::1]:8080:80").first?.publishArgument == "[::1]:8080:80")
        #expect(ComposeOrchestrator.parsePortMappings("5353:53/udp").first?.publishArgument == "5353:53/udp")
        #expect(ComposeOrchestrator.parsePortMappings("8090:8080/http").first?.publishArgument == "8090:8080")
        #expect(ComposeOrchestrator.parsePortMappings("8090:8080/http").first?.isHTTPService == true)
        #expect(ComposeOrchestrator.parsePortMappings("5432:5432").first?.isHTTPService == false)
        #expect(ComposeOrchestrator.parsePortMappings("8000-8002:9000-9002").map { $0.containerPort } == [9000, 9001, 9002])
        #expect(ComposeOrchestrator.parsePortMappings("80").isEmpty)
        #expect(ComposeOrchestrator.parsePortMappings("abc:def").isEmpty)
    }

    @Test func fullFeaturedService() {
        let result = ComposeOrchestrator.parse(yaml: """
        services:
          api:
            build:
              context: ./api
              dockerfile: Dockerfile.dev
              args:
                VERSION: "1.2"
            container_name: my-api
            command: ["node", "server.js"]
            entrypoint: /entry.sh --flag
            working_dir: /srv
            user: "1000:1000"
            restart: unless-stopped
            deploy:
              resources:
                limits:
                  cpus: "1.5"
                  memory: 1G
            environment:
              NODE_ENV: production
              EMPTY:
            ports:
              - target: 3000
                published: 3001
                host_ip: 127.0.0.1
            volumes:
              - type: bind
                source: ./data
                target: /data
                read_only: true
              - cache:/cache
            depends_on:
              db:
                condition: service_healthy
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost:3000/healthz"]
              interval: 10s
              retries: 3
          db:
            image: postgres:17
            mem_limit: 512m
        volumes:
          cache:
          unused:
        """, environment: [:])

        #expect(result.services.map { $0.name } == ["db", "api"])   // dependency order
        let api = result.services[1]
        #expect(api.build == ComposeBuild(context: "./api", dockerfile: "Dockerfile.dev", args: ["VERSION": "1.2"], target: nil))
        #expect(api.image == "api:latest")
        #expect(api.containerName == "my-api")
        #expect(api.command == ["node", "server.js"])
        #expect(api.entrypoint == ["/entry.sh", "--flag"])
        #expect(api.cpus == 2)
        #expect(api.memoryMB == 1024)
        #expect(api.environment == ["NODE_ENV": "production", "EMPTY": ""])
        #expect(api.ports == [PortMapping(hostIP: "127.0.0.1", hostPort: 3001, containerPort: 3000, protocolType: "http")])
        #expect(api.volumes == ["./data:/data:ro", "cache:/cache"])
        #expect(api.dependsOn == ["db"])
        #expect(api.healthcheck?.test == ["CMD", "curl", "-f", "http://localhost:3000/healthz"])
        #expect(api.healthcheck?.retries == 3)
        #expect(api.restart == "unless-stopped")
        #expect(result.services[0].memoryMB == 512)
        #expect(result.namedVolumes == ["cache", "unused"])
    }

    @Test func interpolation() {
        var missing: [String] = []
        let vars = ["TAG": "1.2", "EMPTY": ""]
        func run(_ text: String) -> String { ComposeOrchestrator.interpolate(text, variables: vars, missing: &missing) }
        #expect(run("img:${TAG}") == "img:1.2")
        #expect(run("img:$TAG-x") == "img:1.2-x")
        #expect(run("${NOPE:-fallback}") == "fallback")
        #expect(run("${EMPTY:-fallback}") == "fallback")
        #expect(run("${EMPTY-fallback}") == "")
        #expect(run("${TAG:+set}") == "set")
        #expect(run("${NOPE:-${TAG}}") == "1.2")
        #expect(run("cost: $$5") == "cost: $5")
        #expect(run("${UNSET}") == "")
        #expect(missing == ["UNSET"])
    }

    @Test func envFileAndDotEnvAreRead() throws {
        let dir = NSTemporaryDirectory() + "vessel-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "TAG=9.9\n".write(toFile: dir + "/.env", atomically: true, encoding: .utf8)
        try "# comment\nexport A=1\nB=\"two words\"\nC=x # trailing\nOVERRIDE=file\n".write(toFile: dir + "/app.env", atomically: true, encoding: .utf8)

        let result = ComposeOrchestrator.parse(yaml: """
        services:
          app:
            image: "app:${TAG}"
            env_file: app.env
            environment:
              - OVERRIDE=inline
        """, baseDirectory: dir, environment: [:])

        #expect(result.services[0].image == "app:9.9")
        #expect(result.services[0].environment == ["A": "1", "B": "two words", "C": "x", "OVERRIDE": "inline"])
        #expect(result.warnings.isEmpty)

        let missing = ComposeOrchestrator.parse(yaml: "services:\n  app:\n    image: a\n    env_file: nope.env\n", baseDirectory: dir, environment: [:])
        #expect(missing.warnings.count == 1)
    }

    @Test func duplicateServiceNamesAndCyclesDoNotCrash() {
        let services = ComposeOrchestrator.parseServices(from: """
        services:
          a:
            image: one
            depends_on: [b]
          b:
            image: two
            depends_on: [a, ghost]
          a:
            image: three
            depends_on: [b]
        """)
        #expect(services.count == 2)
        #expect(services.first { $0.name == "a" }?.image == "three")

        let dup = ComposeServiceDefinition(name: "x", image: "i", ports: [], environment: [:], volumes: [], dependsOn: [], cpus: 1, memoryMB: 64)
        #expect(ComposeOrchestrator.sortServicesByDependencies([dup, dup]).count == 1)
    }

    @Test func memoryValues() {
        #expect(ComposeOrchestrator.parseMemoryMB("512m") == 512)
        #expect(ComposeOrchestrator.parseMemoryMB("1g") == 1024)
        #expect(ComposeOrchestrator.parseMemoryMB("1.5GB") == 1536)
        #expect(ComposeOrchestrator.parseMemoryMB("268435456") == 256)
        #expect(ComposeOrchestrator.parseMemoryMB("lots") == nil)
    }

    @Test func vnextRuntimeExamplesProduceAValidPlan() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let env = [
            "VNEXT_DOCKER_DIR": "/vnext/docker", "DOMAIN_NAME": "core", "VNEXT_VERSION": "1.2.3",
            "VNEXT_APP_PORT": "4201", "VNEXT_EXECUTION_PORT": "4202", "VNEXT_INBOX_PORT": "4203", "VNEXT_OUTBOX_PORT": "4204",
            "VNEXT_INIT_PORT": "3005", "DAPR_ORCHESTRATION_HTTP_PORT": "42110", "DAPR_ORCHESTRATION_GRPC_PORT": "42111",
            "DAPR_EXECUTION_HTTP_PORT": "43110", "DAPR_EXECUTION_GRPC_PORT": "43111", "DAPR_INBOX_HTTP_PORT": "44110",
            "DAPR_INBOX_GRPC_PORT": "44111", "DAPR_OUTBOX_HTTP_PORT": "45110", "DAPR_OUTBOX_GRPC_PORT": "45111",
            "DAPR_DBMIGRATOR_HTTP_PORT": "46110", "DAPR_DBMIGRATOR_GRPC_PORT": "46111"
        ]
        func load(_ folder: String) throws -> ComposeStackItem {
            let yaml = try String(contentsOf: root.appendingPathComponent("examples/vnext-runtime/\(folder)/docker-compose.yml"), encoding: .utf8)
            let parsed = ComposeOrchestrator.parse(yaml: yaml, environment: env)
            #expect(parsed.networkKey == "vnext-development" && parsed.networkIsExternal)
            #expect(!parsed.warnings.contains { $0.contains("is not set") }, "\(parsed.warnings)")
            return ComposeStackItem(
                id: folder, name: folder, filePath: "/x/\(folder)/docker-compose.yml", yamlContent: yaml, targetBackend: .appleContainer,
                status: .stopped, services: parsed.services, networkName: "vnext-development", lastDeployedAt: nil,
                networkIsExternal: true
            )
        }

        let infra = ComposeOrchestrator.buildAppleContainerPlan(for: try load("vnext-infra"), dnsDomain: "vnext.test")
        let infraRuns = infra.filter { $0.arguments.first == "run" }.map { $0.arguments[3] }
        #expect(Set(infraRuns) == ["dapr-placement", "dapr-scheduler", "vnext-redis", "vnext-postgres", "vnext-vault", "vault-prepopulate", "vnext-openobserve", "vnext-otel-collector"])
        #expect(infra.contains { $0.arguments == ["volume", "create", "vnext-infra_postgres"] })
        let postgres = infra.first { $0.arguments.contains("vnext-postgres") && $0.arguments.first == "run" }!.arguments
        #expect(postgres.contains("vnext-development,alias=postgres.vnext-development.vnext.test,alias=vnext-postgres.vnext-development.vnext.test"))

        let core = ComposeOrchestrator.buildAppleContainerPlan(for: try load("vnext-core"), dnsDomain: "vnext.test")
        let coreRuns = core.filter { $0.arguments.first == "run" }.map { $0.arguments[3] }
        #expect(coreRuns.count == 12)
        #expect(coreRuns.first == "vnext-db-migrator-core")
        // The orchestrator only starts once the migrator has finished; init waits for a healthy orchestrator.
        let appIndex = core.firstIndex { $0.arguments.first == "run" && $0.arguments[3] == "vnext-app-core" }!
        #expect(core[..<appIndex].contains { $0.kind == .waitExited(container: "vnext-db-migrator-core", timeoutSeconds: 900) })
        let initIndex = core.firstIndex { $0.arguments.first == "run" && $0.arguments[3] == "vnext-init-core" }!
        #expect(core[..<initIndex].contains { if case .waitHealthy(let c, _) = $0.kind { return c == "vnext-app-core" } else { return false } })
        let sidecar = core.first { $0.arguments.first == "run" && $0.arguments[3] == "vnext-app-core-dapr" }!.arguments
        #expect(sidecar.contains("--app-channel-address") && sidecar.contains("vnext-app-core"))
        #expect(sidecar.contains("/x/dapr:/dapr-config:ro") && sidecar.contains("--dapr-internal-grpc-port"))
        let publisher = core.first { $0.arguments.first == "run" && $0.arguments[3] == "vnext-component-publisher-core" }!.arguments
        #expect(publisher.last?.contains("publish-component.sh --skip-health --url \"$VNEXT_INIT_URL\"") == true)
        #expect(Array(publisher[publisher.firstIndex(of: "--entrypoint")!...].prefix(2)) == ["--entrypoint", "/bin/sh"])
    }

    @Test func bundledExamplesParse() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (path, expected) in [("examples/httpbin-gateway/docker-compose.yml", 3), ("examples/postgres-stack/docker-compose.yml", 2)] {
            let yaml = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(ComposeOrchestrator.parseServices(from: yaml).count == expected)
        }
    }
}

@Suite struct ComposePlanTests {
    private func stack(_ yaml: String, name: String = "shop", network: String = "shop_default", path: String = "/proj/docker-compose.yml") -> ComposeStackItem {
        ComposeStackItem(
            id: name, name: name, filePath: path, yamlContent: yaml, targetBackend: .appleContainer,
            status: .stopped, services: ComposeOrchestrator.parse(yaml: yaml, environment: [:]).services,
            networkName: network, lastDeployedAt: nil
        )
    }

    @Test func planIsExecutableArgumentVectors() {
        let plan = ComposeOrchestrator.buildAppleContainerPlan(for: stack("""
        services:
          web:
            image: nginx:alpine
            command: nginx -g 'daemon off;'
            ports: ["127.0.0.1:8080:80", "5353:53/udp"]
            environment:
              GREETING: hello world
            volumes:
              - ./site:/usr/share/nginx/html:ro
              - data:/data
            depends_on: [db]
          db:
            image: postgres:17
            cpus: 4
            mem_limit: 2g
        """))

        #expect(plan.map { $0.arguments.prefix(2).joined(separator: " ") } == [
            "network create", "volume create", "run --detach", "run --detach"
        ])
        #expect(plan[0].allowFailure && plan[1].allowFailure)
        #expect(plan[1].arguments == ["volume", "create", "shop_data"])       // Compose naming: <project>_<volume>
        #expect(plan[3].arguments.contains("shop_data:/data"))

        let db = plan[2].arguments
        #expect(db == [
            "run", "--detach", "--name", "shop-db-1", "--network", "shop_default", "--cpus", "4", "--memory", "2048M",
            "--label", "com.docker.compose.project=shop", "--label", "com.docker.compose.service=db", "postgres:17"
        ])

        let web = plan[3].arguments
        #expect(web.contains("127.0.0.1:8080:80"))
        #expect(web.contains("5353:53/udp"))
        #expect(web.contains("/proj/site:/usr/share/nginx/html:ro"))
        #expect(web.contains("GREETING=hello world"))          // one argument, no shell splitting
        #expect(Array(web.suffix(4)) == ["nginx:alpine", "nginx", "-g", "daemon off;"])
        #expect(plan[3].displayCommand.contains("'GREETING=hello world'"))
    }

    @Test func buildEntrypointAndStaleContainers() {
        let item = stack("""
        services:
          api:
            build: ./api
            container_name: api
            entrypoint: ["/entry.sh", "--verbose"]
            command: ["serve"]
        """, network: "default")
        let plan = ComposeOrchestrator.buildAppleContainerPlan(for: item, existingContainerNames: ["api", "unrelated"])

        #expect(plan[0].arguments == ["delete", "--force", "api"])
        #expect(plan[1].arguments == ["build", "--tag", "api:latest", "/proj/api"])
        let run = plan[2].arguments
        #expect(!run.contains("--network"))                      // "default" network is implicit
        #expect(Array(run.suffix(5)) == ["--entrypoint", "/entry.sh", "api:latest", "--verbose", "serve"])
    }

    @Test func teardownStopsDeletesAndRemovesNetwork() {
        let item = stack("services:\n  a:\n    image: x\n  b:\n    image: y\n    depends_on: [a]\n")
        let plan = ComposeOrchestrator.buildAppleContainerTeardownPlan(for: item)
        #expect(plan.map { $0.arguments } == [
            ["stop", "shop-b-1", "shop-a-1"],
            ["delete", "--force", "shop-b-1", "shop-a-1"],
            ["network", "delete", "shop_default"]
        ])
    }

    @Test func servicesFindEachOtherThroughTheDNSDomain() {
        let item = stack("""
        services:
          redis:
            image: redis
          web_app:
            image: nginx
            container_name: shop-web
        """)
        let plan = ComposeOrchestrator.buildAppleContainerPlan(for: item, dnsDomain: "vnext.test")
        let redis = plan[1].arguments
        // Reachable as `redis` and as `shop-redis-1` inside the network's zone; short names resolve via the search domain.
        #expect(redis.contains("shop_default,alias=redis.shop-default.vnext.test,alias=shop-redis-1.shop-default.vnext.test"))
        #expect(Array(redis[redis.firstIndex(of: "--dns-search")!...].prefix(2)) == ["--dns-search", "shop-default.vnext.test"])
        // `web_app` is not a valid DNS label, so only the container name gets an alias.
        #expect(plan[2].arguments.contains("shop_default,alias=shop-web.shop-default.vnext.test"))

        // Without a DNS domain nothing changes.
        let plain = ComposeOrchestrator.buildAppleContainerPlan(for: item)
        #expect(plain[1].arguments.contains("shop_default") && !plain[1].arguments.contains("--dns-search"))
    }

    @Test func dependsOnConditionsBecomeWaitSteps() {
        let item = stack("""
        services:
          app:
            image: app
            depends_on:
              db:
                condition: service_healthy
              migrate:
                condition: service_completed_successfully
              cache:
                condition: service_started
          db:
            image: postgres
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 10s
              timeout: 5s
              retries: 5
              start_period: 10s
          migrate:
            image: migrator
          cache:
            image: redis
        """)
        let plan = ComposeOrchestrator.buildAppleContainerPlan(for: item)
        let kinds = plan.map { $0.kind }
        #expect(kinds.contains(.waitHealthy(container: "shop-db-1", timeoutSeconds: 85)))        // 10 + 5 × (10 + 5)
        #expect(kinds.contains(.waitExited(container: "shop-migrate-1", timeoutSeconds: 900)))
        let wait = plan.first { $0.kind == .waitHealthy(container: "shop-db-1", timeoutSeconds: 85) }!
        #expect(wait.arguments == ["exec", "shop-db-1", "sh", "-c", "pg_isready -U postgres"])
        // Waits come after the dependencies were started and right before the dependent service.
        let appRun = plan.firstIndex { $0.arguments.contains("shop-app-1") && $0.arguments.first == "run" }!
        #expect(plan[appRun - 1].kind != .command && plan[appRun - 2].kind != .command)
        #expect(plan.filter { $0.kind != .command }.count == 2)                                   // service_started needs no wait
    }

    @Test func networksVolumesProfilesAndRuntimeOptions() {
        let result = ComposeOrchestrator.parse(yaml: """
        services:
          app:
            image: app
            profiles: [vnext]
            network_mode: "service:other"
            cap_add: [IPC_LOCK]
            tmpfs: /run
            volumes:
              - type: tmpfs
                target: /data
              - shared:/shared
              - cache:/cache
          infra:
            image: redis
            profiles: [infra]
          always:
            image: alpine
        networks:
          vnext-development:
            external: true
        volumes:
          shared:
            external: true
          cache:
        """, environment: ["COMPOSE_PROFILES": "vnext, other"])

        #expect(result.services.map { $0.name } == ["app", "always"])                 // `infra` profile is not active
        #expect(result.warnings.contains { $0.contains("Skipped by profile") && $0.contains("infra") })
        #expect(result.warnings.contains { $0.contains("network_mode") })
        #expect(result.networkKey == "vnext-development" && result.networkIsExternal)
        #expect(result.fixedVolumeNames == ["shared": "shared"])
        let app = result.services[0]
        #expect(app.tmpfs == ["/run", "/data"] && app.capAdd == ["IPC_LOCK"])

        var item = ComposeStackItem(
            id: "core", name: "core", filePath: "/p/docker-compose.yml", yamlContent: "", targetBackend: .appleContainer,
            status: .stopped, services: result.services, networkName: "vnext-development", lastDeployedAt: nil
        )
        item.networkIsExternal = true
        item.volumeNames = result.fixedVolumeNames
        let plan = ComposeOrchestrator.buildAppleContainerPlan(for: item)
        #expect(plan.map { $0.arguments.prefix(3).joined(separator: " ") }.prefix(3) == [
            "network create vnext-development", "volume create shared", "volume create core_cache"
        ])
        let run = plan.first { $0.arguments.contains("core-app-1") }!.arguments
        #expect(run.contains("shared:/shared") && run.contains("core_cache:/cache"))
        #expect(Array(run[run.firstIndex(of: "--tmpfs")!...].prefix(4)) == ["--tmpfs", "/run", "--tmpfs", "/data"])
        #expect(Array(run[run.firstIndex(of: "--cap-add")!...].prefix(2)) == ["--cap-add", "IPC_LOCK"])

        // An external network is shared with other stacks: "Stack Down" leaves it alone.
        #expect(!ComposeOrchestrator.buildAppleContainerTeardownPlan(for: item).contains { $0.arguments.first == "network" })
    }

    @Test func durations() {
        #expect(ComposeOrchestrator.parseDurationSeconds("10s") == 10)
        #expect(ComposeOrchestrator.parseDurationSeconds("1m30s") == 90)
        #expect(ComposeOrchestrator.parseDurationSeconds("500ms") == 1)
        #expect(ComposeOrchestrator.parseDurationSeconds("2h") == 7200)
        #expect(ComposeOrchestrator.parseDurationSeconds("45") == 45)
        #expect(ComposeOrchestrator.parseDurationSeconds("soon") == nil)
        #expect(ComposeOrchestrator.parseDurationSeconds(nil) == nil)
    }

    @Test func limitationsAreReported() {
        let services = ComposeOrchestrator.parseServices(from: """
        services:
          a:
            image: x
            restart: always
            healthcheck:
              test: curl -f http://localhost
        """)
        #expect(ComposeOrchestrator.appleContainerLimitations(for: services).count == 2)
    }

    @Test func dockerCompatibleYAMLStripsOnlyPortHints() {
        let yaml = """
        services:
          web:
            ports:
              - "8090:8080/http"
              - 8443:443/https   # tls
              - "53:53/udp"
            environment:
              - URL=http://host:8080/http
        """
        let converted = ComposeOrchestrator.dockerCompatibleYAML(yaml)
        #expect(converted.contains("- \"8090:8080\"\n"))
        #expect(converted.contains("- 8443:443   # tls"))
        #expect(converted.contains("\"53:53/udp\""))
        #expect(converted.contains("URL=http://host:8080/http"))
    }
}

@Suite struct DockerCommandTranslatorTests {
    @Test func basicRun() {
        #expect(DockerCommandTranslator.translate("docker run -d -p 8090:8080 --name httpbin -e PORT=8080 mccutchen/go-httpbin:v2.15.0")
                == "container run --detach --publish 8090:8080 --name httpbin --env PORT=8080 mccutchen/go-httpbin:v2.15.0")
    }

    @Test func attachedValuesCombinedFlagsAndTrailingRm() {
        #expect(DockerCommandTranslator.translate("docker run -dit -p8080:80 --memory=512m nginx --rm")
                == "container run --detach --interactive --tty --publish 8080:80 --memory 512M nginx --rm")
        #expect(DockerCommandTranslator.translate("docker run nginx --rm").hasSuffix("nginx --rm"))   // image args untouched
        #expect(DockerCommandTranslator.translate("docker run --rm nginx") == "container run --rm nginx")
        #expect(DockerCommandTranslator.translate("docker run -itp 80:80 alpine sh") == "container run --interactive --tty --publish 80:80 alpine sh")
    }

    @Test func flagLikeTextInsideValuesIsNotRewritten() {
        #expect(DockerCommandTranslator.translate(#"docker run -e "ARGS=a -p b -v c" alpine echo " -e ""#)
                == #"container run --env 'ARGS=a -p b -v c' alpine echo ' -e '"#)
    }

    @Test func unsupportedFlagsAreDroppedAndReported() {
        let text = DockerCommandTranslator.translate("docker run --restart always --privileged -h box --health-cmd='curl x' -v /a:/b alpine")
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "container run --volume /a:/b alpine")
        #expect(lines[1].contains("--restart") && lines[1].contains("--privileged") && lines[1].contains("-h") && lines[1].contains("--health-cmd"))
    }

    @Test func otherSubcommands() {
        #expect(DockerCommandTranslator.translate("docker ps -a") == "container list -a")
        #expect(DockerCommandTranslator.translate("docker images") == "container image list")
        #expect(DockerCommandTranslator.translate("docker rmi nginx") == "container image delete nginx")
        #expect(DockerCommandTranslator.translate("docker image ls") == "container image list")
        #expect(DockerCommandTranslator.translate("docker pull redis:7") == "container image pull redis:7")
        #expect(DockerCommandTranslator.translate("docker rm -f web") == "container delete -f web")
        #expect(DockerCommandTranslator.translate("docker logs --tail 50 -f web") == "container logs -n 50 -f web")
        #expect(DockerCommandTranslator.translate("docker restart web") == "container stop web && container start web")
        #expect(DockerCommandTranslator.translate("docker container run alpine") == "container run alpine")
        #expect(DockerCommandTranslator.translate("sudo docker exec -it web sh") == "container exec -it web sh")
        #expect(DockerCommandTranslator.translate("docker compose up -d").hasPrefix("#"))
        #expect(DockerCommandTranslator.translate("docker-compose up").hasPrefix("#"))
        #expect(DockerCommandTranslator.translate("") == "")
    }
}
