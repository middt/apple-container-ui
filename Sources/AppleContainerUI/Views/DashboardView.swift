import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Hero Banner (Engine & Virtualization status)
                engineHeroCard

                // 4 Top Cluster Summary Cards
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    summaryCard(
                        title: store.t("Linux MicroVMs", "Linux MicroVM'ler"),
                        value: "\(store.runningContainersCount) / \(store.containers.count)",
                        subtitle: store.t("Hardware isolated via Virtualization.framework", "Virtualization.framework ile donanım izoleli"),
                        icon: "shippingbox.fill",
                        color: .green
                    )
                    summaryCard(
                        title: store.t("Cluster CPU Load", "Küme CPU Yükü"),
                        value: String(format: "%.1f%%", store.totalCPUPercent),
                        subtitle: store.t("Across Apple Silicon Performance/Efficiency cores", "Apple Silicon çekirdekleri genelinde"),
                        icon: "cpu.fill",
                        color: .cyan
                    )
                    summaryCard(
                        title: store.t("Allocated VM Memory", "Ayrılan VM Belleği"),
                        value: ByteFormat.string(store.totalMemoryBytes),
                        subtitle: store.t("of \(ByteFormat.string(store.totalMemoryLimitBytes)) active limit", "\(ByteFormat.string(store.totalMemoryLimitBytes)) aktif limit içinden"),
                        icon: "memorychip.fill",
                        color: .purple
                    )
                    summaryCard(
                        title: store.t("OCI Images & Volumes", "OCI İmajlar & Diskler"),
                        value: "\(store.images.count) img • \(store.volumes.count) vol",
                        subtitle: store.t("\(ByteFormat.string(store.totalImagesSizeBytes)) cached on APFS", "APFS üzerinde \(ByteFormat.string(store.totalImagesSizeBytes)) önbellekte"),
                        icon: "square.stack.3d.up.fill",
                        color: .orange
                    )
                }

                // Real-time Aggregate Charts
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    MetricChartCard(
                        title: store.t("Aggregate Cluster CPU (%)", "Toplam Küme CPU (%)"),
                        subtitle: store.t("Real-time CPU utilization across all running container microVMs", "Çalışan tüm konteyner microVM'lerinin anlık CPU kullanımı"),
                        currentValueText: String(format: "%.1f%%", store.totalCPUPercent),
                        secondaryBadgeText: store.t("sampled every 2 s", "2 sn'de bir örneklenir"),
                        icon: "cpu",
                        accentColor: .cyan,
                        samples: store.clusterMetricsHistory,
                        valueExtractor: { $0.cpuPercent },
                        maxYHint: 150.0
                    )

                    MetricChartCard(
                        title: store.t("Aggregate Cluster Memory (MB)", "Toplam Küme Belleği (MB)"),
                        subtitle: store.t("Combined resident footprint of running Linux VMs", "Çalışan Linux sanal makinelerinin toplam bellek kullanımı"),
                        currentValueText: ByteFormat.string(store.totalMemoryBytes),
                        secondaryBadgeText: nil,
                        icon: "memorychip",
                        accentColor: .purple,
                        samples: store.clusterMetricsHistory,
                        valueExtractor: { $0.memoryUsageMB },
                        maxYHint: Double(max(store.totalMemoryLimitBytes, 1024 * 1024 * 1024)) / (1024.0 * 1024.0)
                    )

                    DualMetricChartCard(
                        title: store.t("Cluster Network Traffic (vmnet Bridge)", "Küme Ağ Trafiği (vmnet Köprüsü)"),
                        subtitle: store.t("Combined RX / TX throughput across bridge100 & isolated networks", "bridge100 ve izole ağlar üzerindeki toplam RX / TX akışı"),
                        icon: "network",
                        primaryLabel: "RX",
                        secondaryLabel: "TX",
                        primaryValueText: String(format: "%.1f KB/s", store.totalNetRxKBps),
                        secondaryValueText: String(format: "%.1f KB/s", store.totalNetTxKBps),
                        primaryColor: .green,
                        secondaryColor: .blue,
                        samples: store.clusterMetricsHistory,
                        primaryExtractor: { $0.netRxKBps },
                        secondaryExtractor: { $0.netTxKBps }
                    )

                    DualMetricChartCard(
                        title: store.t("Cluster Block Storage I/O", "Küme Disk Blok I/O"),
                        subtitle: store.t("Combined VirtioBlk & VirtioFS read/write throughput", "Toplam VirtioBlk & VirtioFS okuma/yazma hızı"),
                        icon: "internaldrive",
                        primaryLabel: store.t("Read", "Okuma"),
                        secondaryLabel: store.t("Write", "Yazma"),
                        primaryValueText: String(format: "%.1f KB/s", store.clusterMetricsHistory.last?.diskReadKBps ?? 0),
                        secondaryValueText: String(format: "%.1f KB/s", store.clusterMetricsHistory.last?.diskWriteKBps ?? 0),
                        primaryColor: .orange,
                        secondaryColor: .pink,
                        samples: store.clusterMetricsHistory,
                        primaryExtractor: { $0.diskReadKBps },
                        secondaryExtractor: { $0.diskWriteKBps }
                    )
                }

                // Per-Container Resource Bar Chart
                ContainerBreakdownBarChart(containers: store.containers)

                // 1-Click Quick Launch Templates
                quickLaunchTemplatesSection
            }
            .padding(18)
        }
    }

    private var engineHeroCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(0.35), .blue.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                Image(systemName: "apple.logo")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Apple Container Engine (github.com/apple/container)")
                        .font(.system(size: 16, weight: .bold))

                    HStack(spacing: 5) {
                        Circle()
                            .fill(store.engineState.color)
                            .frame(width: 7, height: 7)
                        Text(store.engineState == .running ? store.t("APIServer Active", "APIServer Aktif") : store.t("Stopped", "Durduruldu"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(store.engineState.color)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(store.engineState.color.opacity(0.14), in: Capsule())

                }

                Text(store.t(
                    "Lightweight Linux microVMs on Apple Silicon • One vmnet IP per container",
                    "Apple Silicon üzerinde hafif Linux microVM'ler • Her konteynere özel vmnet IP"
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    store.showNewContainerSheet = true
                } label: {
                    Label(store.t("Run Container", "Yeni Konteyner"), systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    store.requestToggleSystemEngine()
                } label: {
                    Label(
                        store.engineState == .running ? store.t("Stop Engine", "Motoru Durdur") : store.t("Start Engine", "Motoru Başlat"),
                        systemImage: store.engineState == .running ? "power" : "bolt.fill"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.22), lineWidth: 1)
        )
    }

    private func summaryCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
            }

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var quickLaunchTemplatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(.yellow)
                Text(store.t("1-Click Quick MicroVM Templates", "1-Tıkla Hazır MicroVM Şablonları"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(store.t("Instantly launches an isolated Linux VM via `container run -d`", "`container run -d` ile anında izole Linux VM başlatır"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                templateCard(name: "httpbin", image: "mccutchen/go-httpbin:v2.15.0", port: 8090, targetPort: 8080, desc: "HTTP REST request & response service")
                templateCard(name: "nginx-web", image: "nginx:1.27-alpine", port: 8088, targetPort: 80, desc: "Ultra-fast HTTP proxy")
                templateCard(name: "redis-fast", image: "valkey/valkey:8.0-alpine", port: 6380, targetPort: 6379, desc: "In-memory KV store")
                templateCard(name: "postgres-dev", image: "postgres:17.2-alpine", port: 5433, targetPort: 5432, desc: "Relational SQL DB")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func templateCard(name: String, image: String, port: Int?, targetPort: Int?, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Button("Launch") {
                    store.createAndRunContainer(
                        name: "\(name)-\(Int.random(in: 10...99))",
                        image: image,
                        cpus: 2,
                        memoryMB: 512,
                        hostPort: port,
                        containerPort: targetPort,
                        mountSource: "",
                        mountDest: "",
                        envPairs: [:],
                        network: "default",
                        command: ""
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            Text(image)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.cyan)
                .lineLimit(1)
            Text(desc)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}

