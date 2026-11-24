import SwiftUI

struct MainWindowView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 225, ideal: 240, max: 270)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch store.selectedSidebar {
                    case .dashboard:
                        DashboardView(store: store)
                    case .containers:
                        ContainersSplitView(store: store)
                    case .stacks:
                        ComposeStacksView(store: store)
                    case .images:
                        ImagesListView(store: store)
                    case .volumes:
                        VolumesListView(store: store)
                    case .networks:
                        NetworksListView(store: store)
                    case .activity:
                        ActivityAndSettingsView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !store.localNetworkBlockedContainers.isEmpty {
                    localNetworkWarningView
                }
                if let error = store.errorBanner {
                    errorBannerView(error)
                }
                Divider()
                bottomCLIStatusBar
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(AppLanguage.allCases) { lang in
                        Button {
                            store.language = lang
                        } label: {
                            HStack {
                                Text("\(lang.displayName) (\(lang.shortCode))")
                                if store.language == lang {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                        Text(store.language.shortCode)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }
                .help(store.t("Language (Auto-detected from macOS)", "Dil (macOS sistem diline göre otomatik)"))

                Button {
                    Task {
                        await store.refreshAll()
                    }
                } label: {
                    Label(store.t("Refresh", "Yenile"), systemImage: "arrow.clockwise")
                }
                .help(store.t("Sync with `container list` & `container stats` (Cmd+R)", "`container list` & `container stats` ile eşitle (Cmd+R)"))

                Button {
                    store.showNewContainerSheet = true
                } label: {
                    Label(store.t("Run Container", "Yeni Konteyner"), systemImage: "plus")
                }
                .help(store.t("Run a new container microVM (Cmd+N)", "Yeni bir konteyner microVM başlat (Cmd+N)"))
            }
        }
        .sheet(isPresented: $store.showNewContainerSheet) {
            NewContainerSheet(store: store)
        }
        .confirmationDialog(
            store.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { store.pendingConfirmation != nil },
                set: { if !$0 { store.pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(store.pendingConfirmation?.confirmLabel ?? "OK", role: .destructive) {
                let action = store.pendingConfirmation?.action
                store.pendingConfirmation = nil
                action?()
            }
            Button(store.t("Cancel", "Vazgeç"), role: .cancel) {
                store.pendingConfirmation = nil
            }
        } message: {
            Text(store.pendingConfirmation?.message ?? "")
        }
    }

    // MARK: - Sidebar with Live Sparklines

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Engine Status Header Pill
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.cyan.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: "cube.box.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.cyan)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Vessel")
                        .font(.system(size: 14, weight: .bold))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(store.engineState.color)
                            .frame(width: 6, height: 6)
                        Text(store.engineState == .running
                             ? store.t("apple/container • Ready", "apple/container • Hazır")
                             : store.engineState.localizedLabel(in: store.language))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    store.requestToggleSystemEngine()
                } label: {
                    Image(systemName: store.engineState == .running ? "power.circle.fill" : "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(store.engineState == .running ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(store.engineState == .running ? store.t("Stop apple/container system", "apple/container sistemini durdur") : store.t("Start apple/container system", "apple/container sistemini başlat"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Navigation Items
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.t("Apple Container Runtime", "Apple Konteyner Çalışma Zamanı"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(SidebarItem.allCases) { item in
                        let isSelected = store.selectedSidebar == item
                        Button {
                            store.selectedSidebar = item
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(isSelected ? .cyan : .secondary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title(in: store.language))
                                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(.primary)
                                    Text(item.localizedSubtitle(in: store.language))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if let badge = badgeText(for: item) {
                                    Text(badge)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(isSelected ? .cyan : .secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider()

            // Sidebar Footer with Live CPU & RAM Sparklines
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("CPU")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", store.totalCPUPercent))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }
                    MiniSparklineView(
                        values: store.clusterMetricsHistory.suffix(24).map { $0.cpuPercent },
                        color: .cyan
                    )
                    .frame(height: 26)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("MEM")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ByteFormat.string(store.totalMemoryBytes))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.purple)
                    }
                    MiniSparklineView(
                        values: store.clusterMetricsHistory.suffix(24).map { $0.memoryUsageMB },
                        color: .purple
                    )
                    .frame(height: 26)
                }

                HStack {
                    Image(systemName: "network")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("↓ \(String(format: "%.0f KB/s", store.totalNetRxKBps))")
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    Text("↑ \(String(format: "%.0f KB/s", store.totalNetTxKBps))")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        }
    }

    private func badgeText(for item: SidebarItem) -> String? {
        switch item {
        case .dashboard: return nil
        case .containers: return "\(store.runningContainersCount)/\(store.containers.count)"
        case .stacks: return "\(store.stacks.count)"
        case .images: return "\(store.images.count)"
        case .volumes: return "\(store.volumes.count)"
        case .networks: return "\(store.networks.count)"
        case .activity: return "\(store.commandLog.count)"
        }
    }

    // MARK: - Local Network permission warning

    private var localNetworkWarningView: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "network.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.t(
                    "Published ports of \(store.localNetworkBlockedContainers.joined(separator: ", ")) are not reachable",
                    "\(store.localNetworkBlockedContainers.joined(separator: ", ")) için yayınlanan portlara erişilemiyor"
                ))
                    .font(.system(size: 12, weight: .semibold))
                Text(store.t(
                    "macOS is blocking `container-runtime-linux` from the local network, so localhost ports reset the connection. Allow it under Privacy & Security → Local Network.",
                    "macOS `container-runtime-linux` için yerel ağ erişimini engelliyor; bu yüzden localhost portları bağlantıyı sıfırlıyor. Gizlilik ve Güvenlik → Yerel Ağ altından izin verin."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(store.t("Open Settings", "Ayarları Aç")) {
                store.openLocalNetworkSettings()
            }
            .controlSize(.small)
            Button {
                store.localNetworkBlockedContainers = []
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(store.t("Dismiss", "Kapat"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
    }

    // MARK: - Command failure banner

    private func errorBannerView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.errorBanner = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(store.t("Dismiss", "Kapat"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.14))
    }

    // MARK: - Bottom CLI Status Bar

    private var bottomCLIStatusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.cyan)

            if let busy = store.busyLabels.last {
                ProgressView()
                    .controlSize(.mini)
                Text(busy)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let latest = store.commandLog.first {
                Text("$ \(latest.command)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("(\(latest.durationMs)ms)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text(store.t("Ready", "Hazır"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(store.engineVersion.isEmpty ? "Arch: \(store.hostArch)" : "\(store.engineVersion)  •  \(store.hostArch)")
                .lineLimit(1)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }
}

// MARK: - MenuBarExtra Tray Popover

struct MenuBarTrayView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.cyan)
                Text("Vessel — Container Studio")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(String(format: "%.1f%% CPU • %@", store.totalCPUPercent, ByteFormat.string(store.totalMemoryBytes)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            ForEach(store.containers) { container in
                HStack {
                    Circle()
                        .fill(container.state.color)
                        .frame(width: 7, height: 7)
                    Text(container.name)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(container.ipAddress)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button(container.state == .running ? "Stop" : "Start") {
                        store.toggleContainerState(container)
                    }
                    .controlSize(.mini)
                }
            }

            Divider()

            HStack {
                Button(store.engineState == .running ? store.t("Stop Engine", "Motoru Durdur") : store.t("Start Engine", "Motoru Başlat")) {
                    store.requestToggleSystemEngine()
                }
                Spacer()
                Button(store.t("Quit", "Çıkış")) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 310)
    }
}

