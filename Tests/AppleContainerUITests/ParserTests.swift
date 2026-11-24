import Foundation
import Testing
@testable import AppleContainerUI

@Suite struct AppleContainerParserTests {
    static let listJSON = """
    [
      {
        "status": "running",
        "startedDate": 784000000.5,
        "configuration": {
          "id": "web",
          "image": { "reference": "docker.io/library/nginx:alpine", "descriptor": { "digest": "sha256:abc", "size": 1234 } },
          "platform": { "os": "linux", "architecture": "arm64" },
          "resources": { "cpus": 4, "memoryInBytes": 1073741824 },
          "labels": { "com.docker.compose.project": "shop", "com.docker.compose.service": "web" },
          "initProcess": { "executable": "nginx", "arguments": ["-g", "daemon off;"], "environment": ["PATH=/bin", "EMPTY=", "FLAG"] },
          "publishedPorts": [
            { "hostAddress": "0.0.0.0", "hostPort": 8080, "containerPort": 80, "proto": "tcp" },
            { "hostAddress": "127.0.0.1", "hostPort": 5353, "containerPort": 53, "proto": "udp" }
          ],
          "mounts": [
            { "type": { "virtiofs": {} }, "source": "/Users/me/site", "destination": "/usr/share/nginx/html", "options": ["ro"] }
          ]
        },
        "networks": [
          { "network": "default", "hostname": "web", "address": "192.168.64.5/24", "gateway": "192.168.64.1" }
        ]
      },
      { "status": "stopped", "configuration": { "id": "bare" }, "networks": [] }
    ]
    """

    @Test func parsesContainerList() throws {
        let items = try #require(AppleContainerParser.containers(fromJSON: Data(Self.listJSON.utf8)))
        #expect(items.count == 2)

        let web = items[0]
        #expect(web.id == "web" && web.state == .running && web.backend == .appleContainer)
        #expect(web.image == "docker.io/library/nginx:alpine")
        #expect(web.arch == "arm64")
        #expect(web.cpuLimitCores == 4)
        #expect(web.memoryLimitBytes == 1_073_741_824)
        #expect(web.ipAddress == "192.168.64.5")
        #expect(web.networkName == "default")
        #expect(web.domainName == "web")
        #expect(web.command == "nginx -g 'daemon off;'")
        #expect(web.env == ["PATH": "/bin", "EMPTY": "", "FLAG": ""])
        #expect(web.composeProject == "shop")
        #expect(web.ports.map { $0.publishArgument } == ["8080:80", "127.0.0.1:5353:53/udp"])
        #expect(web.ports[0].isHTTPService)            // inferred from the well-known port
        #expect(web.mounts == [VolumeMount(type: "virtiofs", source: "/Users/me/site", destination: "/usr/share/nginx/html", readOnly: true)])
        #expect(web.startedAt != nil)
    }

    @Test func unknownFieldsStayEmptyInsteadOfBeingInvented() throws {
        let bare = try #require(AppleContainerParser.containers(fromJSON: Data(Self.listJSON.utf8)))[1]
        #expect(bare.state == .stopped)
        #expect(bare.ipAddress.isEmpty && bare.macAddress.isEmpty && bare.image.isEmpty && bare.domainName.isEmpty)
        #expect(bare.cpuLimitCores == 0 && bare.memoryLimitBytes == 0)
        #expect(bare.ports.isEmpty && bare.env.isEmpty && bare.logs.isEmpty && bare.fileEntries.isEmpty && bare.metricsHistory.isEmpty)
        #expect(bare.startedAt == nil)
    }

    @Test func systemStatus() {
        // Real output of container 1.7.1 with the services stopped: exit code 0.
        #expect(!AppleContainerParser.isSystemRunning(statusOutput: #"{"status":"unregistered"}"#, exitCode: 0))
        #expect(AppleContainerParser.isSystemRunning(statusOutput: #"{"status":"running","appRoot":"/x"}"#, exitCode: 0))
        #expect(!AppleContainerParser.isSystemRunning(statusOutput: #"{"status":"running"}"#, exitCode: 1))
        #expect(!AppleContainerParser.isSystemRunning(statusOutput: "apiserver is not running and not registered with launchd", exitCode: 0))
        #expect(AppleContainerParser.isSystemRunning(statusOutput: "apiserver is running", exitCode: 0))
        #expect(!AppleContainerParser.isSystemRunning(statusOutput: "", exitCode: 0))
    }

    /// Captured from `container list --all --format json` (container 1.7.1), trimmed.
    static let realListJSON = """
    [{"configuration":{"creationDate":"2026-11-13T18:37:38Z","id":"httpbin","image":{"descriptor":{"digest":"sha256:2452","mediaType":"application/vnd.oci.image.index.v1+json","size":1609},"reference":"docker.io/mccutchen/go-httpbin:v2.15.0"},"initProcess":{"arguments":[],"environment":["PATH=/usr/local/sbin:/bin","SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"],"executable":"/bin/go-httpbin","workingDirectory":"/"},"labels":{},"mounts":[],"networks":[{"network":"default","options":{"hostname":"httpbin","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux"},"publishedPorts":[{"containerPort":8080,"count":1,"hostAddress":"0.0.0.0","hostPort":8090,"proto":"tcp"}],"resources":{"cpuOverhead":1,"cpus":2,"memoryInBytes":536870912}},"id":"httpbin","status":{"networks":[{"hostname":"httpbin","ipv4Address":"192.168.64.2/24","ipv4Gateway":"192.168.64.1","ipv6Address":"fd21::6067/64","macAddress":"f6:c1:33:16:60:67","mtu":1280,"network":"default"}],"startedDate":"2026-11-13T18:37:39Z","state":"running"}}]
    """

    @Test func parsesRealContainer1xListOutput() throws {
        let item = try #require(AppleContainerParser.containers(fromJSON: Data(Self.realListJSON.utf8))?.first)
        #expect(item.id == "httpbin" && item.state == .running)
        #expect(item.image == "docker.io/mccutchen/go-httpbin:v2.15.0")
        #expect(item.ipAddress == "192.168.64.2")
        #expect(item.macAddress == "f6:c1:33:16:60:67")
        #expect(item.domainName == "httpbin" && item.networkName == "default")
        #expect(item.cpuLimitCores == 2 && item.memoryLimitBytes == 536_870_912)
        #expect(item.command == "/bin/go-httpbin")
        #expect(item.ports.map { $0.publishArgument } == ["8090:8080"])
        #expect(item.ports[0].isHTTPService)
        #expect(item.startedAt == ISO8601DateFormatter().date(from: "2026-11-13T18:37:39Z"))
        #expect(item.createdAt == ISO8601DateFormatter().date(from: "2026-11-13T18:37:38Z"))
    }

    @Test func parsesRealContainer1xImagesAndNetworks() throws {
        let images = try #require(AppleContainerParser.images(fromJSON: Data("""
        [{"configuration":{"creationDate":"2024-09-17T04:55:29Z","descriptor":{"digest":"sha256:2452","mediaType":"application/vnd.oci.image.index.v1+json","size":1609},"name":"docker.io/mccutchen/go-httpbin:v2.15.0"},"id":"2452","variants":[
          {"platform":{"architecture":"amd64","os":"linux"},"size":16000000,"config":{"config":{"Cmd":["/bin/go-httpbin"]},"rootfs":{"diff_ids":["a"]}}},
          {"platform":{"architecture":"arm64","os":"linux"},"size":15776818,"config":{"config":{"Cmd":["/bin/go-httpbin"],"ExposedPorts":{"8080/tcp":{}}},"rootfs":{"diff_ids":["a","b","c"]}}}]}]
        """.utf8)))
        #expect(images[0].fullReference == "docker.io/mccutchen/go-httpbin:v2.15.0")
        #expect(images[0].digest == "sha256:2452")
        #expect(images[0].sizeBytes == 15_776_818 && images[0].arch == "arm64")     // the arm64 variant, not the manifest size
        #expect(images[0].layersCount == 3 && images[0].exposedPorts == [8080])
        #expect(images[0].defaultCommand == "/bin/go-httpbin")

        let networks = try #require(AppleContainerParser.networks(fromJSON: Data("""
        [{"configuration":{"creationDate":"2026-11-13T18:35:50Z","labels":{},"mode":"nat","name":"default","options":{},"plugin":"container-network-vmnet"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24","ipv6Subnet":"fd21::/64"}}]
        """.utf8)))
        #expect(networks[0].name == "default" && networks[0].mode == "nat")
        #expect(networks[0].subnet == "192.168.64.0/24" && networks[0].gateway == "192.168.64.1" && networks[0].ipv6Enabled)

    }

    @Test func detectsDeniedLocalNetworkPermission() {
        // Real lines from `container system logs` (container 1.7.1).
        let log = """
        2026-11-13 21:37:39.599261+0300 0x3acb48   Info        0x0  19334  0  container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] creating forwarder for [uuid=httpbin] [proxy=[IPv4]0.0.0.0:8090] [protocol=tcp]
        2026-11-13 21:40:17.634799+0300 0x3acb42   Error       0x0  19334  0  container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] backend - connect failed: connect(descriptor:addr:size:): No route to host) (errno: 65) [uuid=httpbin] [server=[IPv4]127.0.0.1/127.0.0.1:53042] [proxy=[IPv4]127.0.0.1/127.0.0.1:8090]
        2026-11-13 21:40:17.634862+0300 0x3acb41   Error       0x0  19334  0  container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] backend - connect failed: connect(descriptor:addr:size:): No route to host) (errno: 65) [server=[IPv4]127.0.0.1/127.0.0.1:53041] [proxy=[IPv4]127.0.0.1/127.0.0.1:8090] [uuid=httpbin]
        2026-11-13 21:41:00.000000+0300 0x3acb41   Error       0x0  19400  0  container-runtime-linux: [com.apple.container:RuntimeLinuxHelper] backend - connect failed: connect(descriptor:addr:size:): Connection refused) (errno: 61) [uuid=slow-start]
        """
        #expect(AppleContainerParser.containersBlockedByLocalNetwork(systemLog: log) == ["httpbin"])
        #expect(AppleContainerParser.containersBlockedByLocalNetwork(systemLog: "") == [])

        // Errors logged before the probe (e.g. before the permission was granted) do not count.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        let afterErrors = formatter.date(from: "2026-11-13 21:40:30.000000+0300")!
        let beforeErrors = formatter.date(from: "2026-11-13 21:40:00.000000+0300")!
        #expect(AppleContainerParser.containersBlockedByLocalNetwork(systemLog: log, since: afterErrors) == [])
        #expect(AppleContainerParser.containersBlockedByLocalNetwork(systemLog: log, since: beforeErrors) == ["httpbin"])
    }

    @Test func rejectsNonJSONAndAcceptsEmptyList() {
        #expect(AppleContainerParser.containers(fromJSON: Data("Error: not running".utf8)) == nil)
        #expect(AppleContainerParser.containers(fromJSON: Data("[]".utf8)) == [])
        #expect(AppleContainerParser.containers(fromJSON: Data()) == nil)
    }

    @Test func parsesStatsImagesVolumesNetworks() throws {
        let stats = try #require(AppleContainerParser.stats(fromJSON: Data("""
        [{"id":"web","memoryUsageBytes":1048576,"memoryLimitBytes":1073741824,"cpuUsageUsec":5000000,"networkRxBytes":100,"networkTxBytes":200,"blockReadBytes":0,"blockWriteBytes":0,"numProcesses":3}]
        """.utf8)))
        #expect(stats[0].id == "web" && stats[0].cpuUsageUsec == 5_000_000 && stats[0].cpuUtilization == nil)

        let images = try #require(AppleContainerParser.images(fromJSON: Data("""
        [{"reference":"ghcr.io/org/app:1.2","descriptor":{"digest":"sha256:feed","size":999}},
         {"reference":"localhost:5000/tool"},
         {"reference":"alpine@sha256:beef"}]
        """.utf8)))
        #expect(images.map { $0.repository } == ["ghcr.io/org/app", "localhost:5000/tool", "alpine"])
        #expect(images.map { $0.tag } == ["1.2", "latest", "sha256:beef"])
        #expect(images[0].digest == "sha256:feed")
        #expect(images[0].sizeBytes == 0)              // only the manifest size is known: do not show it as the image size

        let volumes = try #require(AppleContainerParser.volumes(fromJSON: Data("""
        [{"name":"pgdata","driver":"local","format":"ext4","source":"/path/pgdata","sizeInBytes":5368709120}]
        """.utf8)))
        #expect(volumes == [VolumeItem(name: "pgdata", driver: "local", format: "ext4", mountpoint: "/path/pgdata", sizeBytes: 5_368_709_120, createdAt: volumes[0].createdAt, attachedContainers: [])])

        let networks = try #require(AppleContainerParser.networks(fromJSON: Data("""
        [{"id":"default","state":"running","config":{"id":"default","mode":"nat"},"status":{"address":"192.168.64.0/24","gateway":"192.168.64.1"}}]
        """.utf8)))
        #expect(networks[0].name == "default" && networks[0].mode == "nat")
        #expect(networks[0].subnet == "192.168.64.0/24" && networks[0].gateway == "192.168.64.1")
    }

    @Test func directoryListing() {
        let entries = ContainerStore.parseDirectoryListing("""
        total 64
        drwxr-xr-x    1 root     root          4096 Nov 13 10:00 .
        drwxr-xr-x    1 root     root          4096 Nov 13 10:00 ..
        lrwxrwxrwx    1 root     root             7 Oct  1 09:00 bin -> usr/bin
        drwxr-xr-x    2 root     root          4096 Nov 13 10:00 etc
        -rw-r--r--    1 app      staff          412 Nov 12 11:05 my file.txt
        """)
        #expect(entries.map { $0.name } == ["bin", "etc", "my file.txt"])
        #expect(entries[0].isSymlink && !entries[0].isDirectory)
        #expect(entries[1].isDirectory)
        #expect(entries[2].owner == "app:staff" && entries[2].size == "412 B")
    }
}

@Suite struct DockerParserTests {
    @Test func parsesInspectOutput() throws {
        let json = """
        [{
          "Id": "0123456789ab", "Name": "/shop-web-1", "Created": "2026-11-13T09:00:00.123456789Z",
          "Path": "/docker-entrypoint.sh", "Args": ["nginx", "-g", "daemon off;"], "Platform": "linux",
          "State": { "Status": "running", "Running": true, "StartedAt": "2026-11-13T09:00:01.5Z" },
          "Config": { "Image": "nginx:alpine", "Hostname": "0123456789ab", "Env": ["A=1", "B=x=y"],
                      "Labels": { "com.docker.compose.project": "shop" } },
          "HostConfig": { "NanoCpus": 1500000000, "Memory": 536870912 },
          "NetworkSettings": {
            "Ports": { "80/tcp": [ { "HostIp": "0.0.0.0", "HostPort": "8080" }, { "HostIp": "::", "HostPort": "8080" } ],
                       "53/udp": [ { "HostIp": "127.0.0.1", "HostPort": "5353" } ], "9000/tcp": null },
            "Networks": { "shop_default": { "IPAddress": "172.18.0.2", "MacAddress": "02:42:ac:12:00:02" } }
          },
          "Mounts": [ { "Type": "volume", "Name": "data", "Source": "/var/lib/docker/volumes/data/_data", "Destination": "/data", "RW": true },
                      { "Type": "bind", "Source": "/host/site", "Destination": "/site", "RW": false } ]
        }]
        """
        let item = try #require(DockerParser.containers(fromInspectJSON: Data(json.utf8))?.first)
        #expect(item.name == "shop-web-1" && item.cliID == "shop-web-1" && item.backend == .dockerEngine)
        #expect(item.state == .running && item.startedAt != nil)
        #expect(item.image == "nginx:alpine")
        #expect(item.env == ["A": "1", "B": "x=y"])
        #expect(item.cpuLimitCores == 2 && item.memoryLimitBytes == 536_870_912)
        #expect(item.ipAddress == "172.18.0.2" && item.networkName == "shop_default")
        #expect(item.composeProject == "shop")
        #expect(item.ports.map { $0.publishArgument } == ["127.0.0.1:5353:53/udp", "8080:80"])
        #expect(item.mounts.map { $0.source } == ["data", "/host/site"])
        #expect(item.mounts[1].readOnly)
        #expect(item.command == "/docker-entrypoint.sh nginx -g 'daemon off;'")
    }

    @Test func parsesStatsLines() {
        let stats = DockerParser.stats(fromJSONLines: """
        {"BlockIO":"1.2MB / 0B","CPUPerc":"12.50%","Container":"abc","ID":"abc","MemPerc":"0.05%","MemUsage":"3.9MiB / 7.75GiB","Name":"shop-web-1","NetIO":"1.05kB / 2kB","PIDs":"5"}
        not json
        """)
        #expect(stats == [DockerStatSample(
            name: "shop-web-1", cpuPercent: 12.5, memoryUsageBytes: 4_089_446, memoryLimitBytes: 8_321_499_136,
            networkRxBytes: 1050, networkTxBytes: 2000, blockReadBytes: 1_200_000, blockWriteBytes: 0, numProcesses: 5
        )])
        #expect(DockerParser.parseSize("0B") == 0)
        #expect(DockerParser.parseSize("garbage") == 0)
    }

    @Test func dates() {
        #expect(CLIDateParser.date(from: "2026-11-13T09:00:00Z") != nil)
        #expect(CLIDateParser.date(from: "2026-11-13T09:00:00.123456789Z") != nil)
        #expect(CLIDateParser.date(from: "0001-01-01T00:00:00Z") == nil)
        #expect(CLIDateParser.date(from: NSNumber(value: 1_800_000_000)) == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(CLIDateParser.date(from: NSNumber(value: 784_000_000)) == Date(timeIntervalSinceReferenceDate: 784_000_000))
        #expect(CLIDateParser.date(from: nil) == nil)
    }
}
