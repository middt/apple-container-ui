import SwiftUI
import AppKit

struct ContainersSplitView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        HSplitView {
            // LEFT MASTER LIST
            VStack(spacing: 0) {
                masterHeaderBar
                Divider()

                if store.filteredContainers.isEmpty {
                    emptyContainerListPlaceholder
                } else {
                    let groups = store.filteredContainerGroups
                    let standalone = store.filteredStandaloneContainers
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(groups) { group in
                                ContainerGroupHeaderRow(
                                    store: store,
                                    group: group,
                                    isSelected: store.selectedGroupID == group.id,
                                    isCollapsed: store.collapsedGroupIDs.contains(group.id),
                                    hover: store.listHover
                                )
                                if !store.collapsedGroupIDs.contains(group.id) {
                                    ForEach(group.containers) { container in
                                        containerRow(container)
                                            .padding(.leading, 16)
                                    }
                                }
                            }

                            if !groups.isEmpty && !standalone.isEmpty {
                                Text(store.t("Standalone containers", "Bağımsız konteynerler"))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }
                            ForEach(standalone) { container in
                                containerRow(container)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
            .background(Color(nsColor: .windowBackgroundColor))

            // RIGHT DETAIL INSPECTOR PANE
            if let group = store.selectedGroup {
                ContainerGroupDashboardView(store: store, group: group)
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            } else if let selected = store.selectedContainer {
                VStack(spacing: 0) {
                    containerDetailHeader(for: selected)
                    Divider()
                    containerTabSelector
                    Divider()

                    Group {
                        switch store.selectedDetailTab {
                        case .stats:
                            containerStatsTab(for: selected)
                        case .logs:
                            containerLogsTab(for: selected)
                        case .terminal:
                            containerExecTab(for: selected)
                        case .info:
                            containerInfoTab(for: selected)
                        case .files:
                            containerFilesTab(for: selected)
                        case .rawJSON:
                            containerRawJSONTab(for: selected)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Select a Container MicroVM")
                        .font(.headline)
                    Text("Inspect real-time Virtualization.framework telemetry, logs, files, and vmnet networking.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func containerRow(_ container: ContainerItem) -> some View {
        ContainerRowView(
            container: container,
            isSelected: store.selectedGroupID == nil && store.selectedContainer?.id == container.id,
            hover: store.listHover,
            onSelect: {
                store.selectContainer(container.id)
            },
            onToggleState: {
                store.toggleContainerState(container)
            },
            onRestart: {
                store.restartContainer(id: container.id)
            },
            onOpenShell: {
                store.openShell(for: container)
            },
            onDelete: {
                store.requestDeleteContainer(container)
            }
        )
    }

    // MARK: - Master Header Bar

    private var masterHeaderBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    TextField(store.t("Filter containers, images, IPs…", "Konteyner, imaj veya IP ara…"), text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

                Button {
                    store.showNewContainerSheet = true
                } label: {
                    Label(store.t("Run", "Başlat"), systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(store.t("Run a new Linux container microVM (container run)", "Yeni bir Linux konteyner microVM çalıştır (container run)"))
            }

            HStack {
                Picker("", selection: $store.containerFilter) {
                    ForEach(ContainerFilterState.allCases) { f in
                        Text(f.title(in: store.language)).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                Spacer()

                Text(store.t(
                    "\(store.runningContainersCount) running / \(store.containers.count) total",
                    "\(store.runningContainersCount) çalışan / \(store.containers.count) toplam"
                ))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var emptyContainerListPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cube.transparent")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No matching containers")
                .font(.system(size: 14, weight: .semibold))
            Text("Create a lightweight Linux microVM with `container run` or clear your search filter.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("New Container MicroVM…") {
                store.showNewContainerSheet = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Detail Header

    private func containerDetailHeader(for container: ContainerItem) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(container.state.color.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(container.state.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(container.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(container.state.color)
                            .frame(width: 7, height: 7)
                        Text(container.state.localizedLabel(in: store.language))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(container.state.color)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(container.state.color.opacity(0.12), in: Capsule())
                    .fixedSize()

                    Text("\(container.os)/\(container.arch)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .fixedSize()
                }

                HStack(spacing: 12) {
                    Label(container.image, systemImage: "square.stack.3d.up")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !container.ipAddress.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(container.ipAddress, forType: .string)
                            store.showCopiedToast("Copied \(container.ipAddress)")
                        } label: {
                            Label(container.ipAddress, systemImage: "network")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.cyan)
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy container vmnet IP")
                    }

                    Text(container.domainName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let toast = store.copiedToast {
                        Text(toast)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                            .fixedSize()
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if let firstWebPort = container.ports.first(where: { $0.isHTTPService }),
                   let url = firstWebPort.browserURL,
                   container.state == .running {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(":\(String(firstWebPort.hostPort))", systemImage: "safari")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.bordered)
                    .help("Open \(url.absoluteString) in Browser")
                }

                Button {
                    store.openShell(for: container)
                } label: {
                    Label(store.t("Shell", "Kabuk"), systemImage: "apple.terminal")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help(store.t("Open interactive shell in macOS Terminal.app (container exec -it)", "macOS Terminal.app içinde interaktif kabuk aç (container exec -it)"))

                Button {
                    store.toggleContainerState(container)
                } label: {
                    Label(
                        container.state == .running ? store.t("Stop", "Durdur") : store.t("Start", "Başlat"),
                        systemImage: container.state == .running ? "stop.fill" : "play.fill"
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(container.state == .running ? .orange : .green)

                Button {
                    store.restartContainer(id: container.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Restart MicroVM")

                Button(role: .destructive) {
                    store.requestDeleteContainer(container)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .help("Delete container (container delete --force)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Detail Tab Bar

    private var containerTabSelector: some View {
        HStack(spacing: 6) {
            ForEach(ContainerDetailTab.allCases) { tab in
                let isSelected = store.selectedDetailTab == tab
                Button {
                    store.selectedDetailTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.title(in: store.language))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    // MARK: - TAB 1: Real-Time Telemetry & Swift Charts

    private func containerStatsTab(for container: ContainerItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    kpiPill(title: "vCPU Load", value: String(format: "%.1f%%", container.cpuPercentDisplay), sub: "\(container.cpuLimitCores) cores allocated", color: .cyan)
                    kpiPill(title: "Memory", value: String(format: "%.0f MB", container.memoryUsageMBDisplay), sub: String(format: "of %.0f MB (%.0f%%)", container.memoryLimitMBDisplay, container.memoryPercentDisplay), color: .purple)
                    kpiPill(title: "Net Traffic", value: ByteFormat.string(container.networkRxBytes), sub: "TX: \(ByteFormat.string(container.networkTxBytes))", color: .green)
                    kpiPill(title: "Block Disk I/O", value: ByteFormat.string(container.blockReadBytes), sub: "W: \(ByteFormat.string(container.blockWriteBytes))", color: .orange)
                    kpiPill(title: "Processes & Uptime", value: "\(container.numProcesses) PIDs", sub: "Up: \(container.uptimeString)", color: .blue)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    MetricChartCard(
                        title: store.t("CPU Utilization", "CPU Kullanımı"),
                        subtitle: store.t("Apple Virtualization.framework vCPU usage (%)", "Apple Virtualization.framework vCPU kullanımı (%)"),
                        currentValueText: String(format: "%.1f%%", container.cpuPercentDisplay),
                        secondaryBadgeText: "\(container.cpuLimitCores) vCPU",
                        icon: "cpu",
                        accentColor: .cyan,
                        samples: container.metricsHistory,
                        valueExtractor: { $0.cpuPercent },
                        maxYHint: 100.0
                    )

                    MetricChartCard(
                        title: store.t("Memory Usage", "Bellek Kullanımı"),
                        subtitle: store.t("Resident MicroVM Memory (MB)", "Yerleşik MicroVM Belleği (MB)"),
                        currentValueText: String(format: "%.0f MB", container.memoryUsageMBDisplay),
                        secondaryBadgeText: String(format: "Limit %.0f MB", container.memoryLimitMBDisplay),
                        icon: "memorychip",
                        accentColor: .purple,
                        samples: container.metricsHistory,
                        valueExtractor: { $0.memoryUsageMB },
                        maxYHint: container.memoryLimitMBDisplay
                    )

                    DualMetricChartCard(
                        title: store.t("Network Throughput (vmnet)", "Ağ Akışı (vmnet)"),
                        subtitle: store.t("Real-time RX / TX packet rate (KB/s)", "Anlık RX / TX paket hızı (KB/s)"),
                        icon: "network",
                        primaryLabel: "RX",
                        secondaryLabel: "TX",
                        primaryValueText: String(format: "%.1f KB/s", container.latestMetric?.netRxKBps ?? 0),
                        secondaryValueText: String(format: "%.1f KB/s", container.latestMetric?.netTxKBps ?? 0),
                        primaryColor: .green,
                        secondaryColor: .blue,
                        samples: container.metricsHistory,
                        primaryExtractor: { $0.netRxKBps },
                        secondaryExtractor: { $0.netTxKBps }
                    )

                    DualMetricChartCard(
                        title: store.t("Block Storage I/O (VirtioBlk)", "Disk Blok I/O (VirtioBlk)"),
                        subtitle: store.t("Real-time Disk Read / Write rate (KB/s)", "Anlık Disk Okuma / Yazma hızı (KB/s)"),
                        icon: "internaldrive",
                        primaryLabel: store.t("Read", "Okuma"),
                        secondaryLabel: store.t("Write", "Yazma"),
                        primaryValueText: String(format: "%.1f KB/s", container.latestMetric?.diskReadKBps ?? 0),
                        secondaryValueText: String(format: "%.1f KB/s", container.latestMetric?.diskWriteKBps ?? 0),
                        primaryColor: .orange,
                        secondaryColor: .pink,
                        samples: container.metricsHistory,
                        primaryExtractor: { $0.diskReadKBps },
                        secondaryExtractor: { $0.diskWriteKBps }
                    )
                }
            }
            .padding(16)
        }
    }

    private func kpiPill(title: String, value: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(sub)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - TAB 2: Live Logs Viewer

    private func containerLogsTab(for container: ContainerItem) -> some View {
        let filteredLogs = container.logs.filter {
            store.logSearchText.isEmpty || $0.message.localizedCaseInsensitiveContains(store.logSearchText)
        }

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search container logs…", text: $store.logSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                Spacer()

                Text("\(container.backend.toolName) logs \(container.cliID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    let allText = filteredLogs.map { "[\($0.timestamp.formatted(date: .omitted, time: .standard))] [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(allText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(filteredLogs) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Text(entry.level.rawValue)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(entry.level.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(entry.level.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))

                            Text(entry.message)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.22))
        }
    }

    // MARK: - TAB 3: Interactive Exec / Shell Runner

    private func containerExecTab(for container: ContainerItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Quick Presets:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(["uname -a", "ps aux", "ip addr", "df -h", "env", "cat /etc/os-release"], id: \.self) { preset in
                    Button(preset) {
                        store.execCommandInput = preset
                        store.runQuickExec(for: container, command: preset)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 11, design: .monospaced))
                }

                Spacer()

                Button {
                    store.openShell(for: container)
                } label: {
                    Label("Open in macOS Terminal.app", systemImage: "apple.terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            HStack(spacing: 8) {
                Text("\(container.backend.toolName) exec \(container.cliID)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)

                TextField("Command to run inside container (e.g. ls -la /etc)", text: $store.execCommandInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        store.runQuickExec(for: container, command: store.execCommandInput)
                    }

                Button("Execute") {
                    store.runQuickExec(for: container, command: store.execCommandInput)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.execOutputHistory.isEmpty {
                        Text("# Ready to execute commands inside \(container.name) (\(container.ipAddress))\n# Click a preset chip above or type a command and press Return.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(store.execOutputHistory.enumerated()), id: \.offset) { _, block in
                            Text(block)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.green)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.25))
        }
    }

    // MARK: - TAB 4: Inspect & Mounts

    private func containerInfoTab(for container: ContainerItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Apple Virtualization.framework & vmnet Networking") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        infoRow("Container ID", container.id)
                        infoRow("OCI Image", container.image)
                        infoRow("Entrypoint / Cmd", container.command)
                        infoRow("Guest OS / Arch", "\(container.os) / \(container.arch) (Hardware Virtualized)")
                        infoRow("vmnet IPv4 Address", container.ipAddress)
                        infoRow("DNS Hostname", container.domainName)
                        infoRow("MAC Address", container.macAddress)
                        infoRow("Network Bridge", container.networkName)
                        infoRow("Engine", container.backend.displayName)
                        infoRow("Resources", container.cpuLimitCores > 0 || container.memoryLimitBytes > 0
                                ? "\(container.cpuLimitCores > 0 ? "\(container.cpuLimitCores) vCPU" : "— vCPU")  •  \(ByteFormat.stringOrDash(container.memoryLimitBytes)) RAM"
                                : "")
                    }
                    .padding(8)
                }

                GroupBox("Published Port Forwards") {
                    if container.ports.isEmpty {
                        Text(container.ipAddress.isEmpty
                             ? "No host ports published"
                             : "No host ports published — accessible directly via vmnet IP \(container.ipAddress)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(container.ports) { port in
                                HStack(spacing: 10) {
                                    Text(port.appProtocol.rawValue.uppercased())
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(port.isHTTPService ? .green : .orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background((port.isHTTPService ? Color.green : Color.orange).opacity(0.15), in: Capsule())

                                    Label(port.displayString, systemImage: port.isHTTPService ? "globe" : "point.3.connected.trianglepath.dotted")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))

                                    Spacer()

                                    if port.isHTTPService, let url = port.browserURL {
                                        Button {
                                            store.testHTTPOutput(for: container, port: port)
                                        } label: {
                                            Label("Test HTTP Output", systemImage: "waveform.path.ecg")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button {
                                            NSWorkspace.shared.open(url)
                                        } label: {
                                            Label("Open \(url.absoluteString)", systemImage: "safari")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    } else {
                                        Text("Raw \(port.appProtocol.rawValue.uppercased()) Socket")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)

                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(port.tcpEndpointString, forType: .string)
                                            store.showCopiedToast("Copied \(port.tcpEndpointString)")
                                        } label: {
                                            Label("Copy \(port.tcpEndpointString)", systemImage: "doc.on.doc")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }

                            if !store.httpTestResponsePreview.isEmpty && container.ports.contains(where: { $0.isHTTPService }) {
                                Divider()
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(store.t("HTTP response (real request):", "HTTP yanıtı (gerçek istek):"))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.green)
                                        Spacer()
                                        Button("Clear") {
                                            store.httpTestResponsePreview = ""
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    }
                                    Text(store.httpTestResponsePreview)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.cyan)
                                        .textSelection(.enabled)
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                GroupBox("VirtioFS & Persistent Volume Mounts") {
                    if container.mounts.isEmpty {
                        Text("Root filesystem only (ephemeral ext4 block device)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(container.mounts) { m in
                                HStack {
                                    Text(m.type.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.cyan.opacity(0.15), in: Capsule())
                                    Text("\(m.source)  →  \(m.destination)")
                                        .font(.system(size: 12, design: .monospaced))
                                    Spacer()
                                    Text(m.readOnly ? "RO" : "RW")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(container.env.keys.sorted(), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.cyan)
                                Spacer()
                                Text(store.showEnvValues ? (container.env[key] ?? "") : "••••••••••••")
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Divider()
                        }
                    }
                    .padding(8)
                } label: {
                    HStack {
                        Text("Environment Variables")
                        Spacer()
                        Button(store.showEnvValues ? "Hide Values" : "Show Values") {
                            store.showEnvValues.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }

    private func infoRow(_ key: String, _ val: String) -> some View {
        GridRow {
            Text(key)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(val.isEmpty ? "—" : val)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: - TAB 5: RootFS File Explorer

    private func containerFilesTab(for container: ContainerItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.cyan)
                Text("\(container.name):/")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text("\(container.backend.toolName) exec \(container.cliID) ls -la /")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if container.fileEntries.isEmpty {
                Text(container.state == .running
                     ? (store.fileListingAttempted.contains(container.id)
                        ? store.t("`ls -la /` returned nothing (the image may not ship `ls`).", "`ls -la /` sonuç döndürmedi (imajda `ls` olmayabilir).")
                        : store.t("Reading `ls -la /` from the container…", "Konteynerden `ls -la /` okunuyor…"))
                     : store.t("Start the container to browse its root filesystem.", "Kök dosya sistemini görmek için konteyneri başlatın."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            List(container.fileEntries) { file in
                HStack(spacing: 12) {
                    Image(systemName: file.isDirectory ? "folder.fill" : "doc.text.fill")
                        .foregroundStyle(file.isDirectory ? .cyan : .secondary)
                        .frame(width: 18)

                    Text(file.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))

                    Spacer()

                    Text(file.permissions)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(file.owner)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(file.size)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 70, alignment: .trailing)

                    Text(file.modified)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 95, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - TAB 6: Raw `container inspect` JSON

    private func containerRawJSONTab(for container: ContainerItem) -> some View {
        let jsonString = store.inspectJSONByContainerID[container.id] ?? store.t("Loading inspect output…", "Inspect çıktısı yükleniyor…")

        return VStack(spacing: 0) {
            HStack {
                Text("\(container.backend.toolName) inspect \(container.cliID)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jsonString, forType: .string)
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)
            Divider()
            ScrollView {
                Text(jsonString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color.black.opacity(0.28))
        }
    }
}

// MARK: - Container Row Item

struct ContainerRowView: View {
    let container: ContainerItem
    let isSelected: Bool
    @ObservedObject var hover: HoverState
    let onSelect: () -> Void
    let onToggleState: () -> Void
    let onRestart: () -> Void
    let onOpenShell: () -> Void
    let onDelete: () -> Void

    private var isHovered: Bool { hover.id == container.id }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if container.state == .running {
                    Circle()
                        .fill(container.state.color.opacity(0.3))
                        .frame(width: 16, height: 16)
                }
                Circle()
                    .fill(container.state.color)
                    .frame(width: 9, height: 9)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(container.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let firstPort = container.ports.first {
                        Text(":\(String(firstPort.hostPort))/\(firstPort.appProtocol.rawValue)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(firstPort.isHTTPService ? .cyan : .orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((firstPort.isHTTPService ? Color.cyan : Color.orange).opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(container.image)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(container.ipAddress)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isHovered {
                HStack(spacing: 4) {
                    Button(action: onToggleState) {
                        Image(systemName: container.state == .running ? "stop.fill" : "play.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(container.state == .running ? "Stop" : "Start")

                    Button(action: onOpenShell) {
                        Image(systemName: "apple.terminal")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Open Shell")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Delete")
                }
            } else if container.state == .running {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f%%", container.cpuPercentDisplay))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                    Text(String(format: "%.0f MB", container.memoryUsageMBDisplay))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(container.state.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            if hovering {
                hover.id = container.id
            } else if hover.id == container.id {
                hover.id = nil
            }
        }
    }
}
