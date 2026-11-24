import SwiftUI
import AppKit

// MARK: - Group header row (container list)

/// Header of a Compose project group in the container list: aggregate state and usage,
/// collapse toggle, and bulk actions on hover.
struct ContainerGroupHeaderRow: View {
    @ObservedObject var store: ContainerStore
    let group: ContainerGroup
    let isSelected: Bool
    let isCollapsed: Bool
    @ObservedObject var hover: HoverState

    private var isHovered: Bool { hover.id == "group:\(group.id)" }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.toggleGroupCollapsed(group.id)
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)

            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 13))
                .foregroundStyle(group.state.color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Text(group.backend.shortBadge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(group.backend == .appleContainer ? .cyan : .blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((group.backend == .appleContainer ? Color.cyan : Color.blue).opacity(0.14), in: Capsule())
                }
                Text(store.t(
                    "\(group.runningCount)/\(group.containers.count) running",
                    "\(group.runningCount)/\(group.containers.count) çalışıyor"
                ))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if group.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if isHovered {
                GroupActionButtons(store: store, group: group, compact: true)
            } else if group.runningCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f%%", group.cpuPercent))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                    Text(ByteFormat.string(group.memoryUsageBytes))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.purple)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovered ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectGroup(group.id)
        }
        .onHover { hovering in
            if hovering {
                hover.id = "group:\(group.id)"
            } else if hover.id == "group:\(group.id)" {
                hover.id = nil
            }
        }
        .contextMenu {
            Button(store.t("Start all", "Tümünü başlat")) { store.startGroup(group.id) }
                .disabled(group.runningCount == group.containers.count)
            Button(store.t("Stop all", "Tümünü durdur")) { store.stopGroup(group.id) }
                .disabled(group.runningCount == 0)
            Button(store.t("Restart all", "Tümünü yeniden başlat")) { store.restartGroup(group.id) }
            Divider()
            Button(store.t("Delete group…", "Grubu sil…"), role: .destructive) {
                store.requestDeleteGroup(group.id)
            }
        }
        .padding(.top, 4)
    }
}

/// Start / stop / restart / delete for a whole group. Deleting always asks for confirmation.
struct GroupActionButtons: View {
    @ObservedObject var store: ContainerStore
    let group: ContainerGroup
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            if group.runningCount < group.containers.count {
                button(store.t("Start All", "Tümünü Başlat"), icon: "play.fill", tint: .green) {
                    store.startGroup(group.id)
                }
            }
            if group.runningCount > 0 {
                button(store.t("Stop All", "Tümünü Durdur"), icon: "stop.fill", tint: .orange) {
                    store.stopGroup(group.id)
                }
            }
            button(store.t("Restart", "Yeniden Başlat"), icon: "arrow.clockwise", tint: nil) {
                store.restartGroup(group.id)
            }
            button(store.t("Delete", "Sil"), icon: "trash", tint: .red) {
                store.requestDeleteGroup(group.id)
            }
        }
        .disabled(group.isBusy)
    }

    @ViewBuilder
    private func button(_ title: String, icon: String, tint: Color?, action: @escaping () -> Void) -> some View {
        if compact {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint ?? .primary)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(title)
        } else {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint == .red ? Color.red : Color.primary)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Group dashboard (detail pane)

/// Dashboard for one Compose project: aggregate KPIs and charts, per-container breakdown,
/// and the member list with per-container controls.
struct ContainerGroupDashboardView: View {
    @ObservedObject var store: ContainerStore
    let group: ContainerGroup

    var body: some View {
        let history = group.metricsHistory
        let latest = history.last

        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        pill(
                            title: store.t("Containers", "Konteynerler"),
                            value: "\(group.runningCount) / \(group.containers.count)",
                            sub: store.t("running", "çalışıyor"),
                            color: .green
                        )
                        pill(
                            title: store.t("Group CPU", "Grup CPU"),
                            value: String(format: "%.1f%%", group.cpuPercent),
                            sub: group.cpuLimitCores > 0
                                ? store.t("of \(group.cpuLimitCores) cores (100% = 1 core)", "\(group.cpuLimitCores) çekirdekten (100% = 1 çekirdek)")
                                : store.t("100% = 1 core", "100% = 1 çekirdek"),
                            color: .cyan
                        )
                        pill(
                            title: store.t("Group Memory", "Grup Belleği"),
                            value: ByteFormat.string(group.memoryUsageBytes),
                            sub: group.memoryLimitBytes > 0
                                ? String(format: "%@ limit (%.0f%%)", ByteFormat.string(group.memoryLimitBytes), group.memoryPercent)
                                : store.t("no limit reported", "limit bildirilmedi"),
                            color: .purple
                        )
                        pill(
                            title: store.t("Network", "Ağ"),
                            value: "↓ " + ByteFormat.rateString(latest?.netRxBytesPerSec ?? 0),
                            sub: "↑ " + ByteFormat.rateString(latest?.netTxBytesPerSec ?? 0),
                            color: .green
                        )
                        pill(
                            title: store.t("Processes", "Süreçler"),
                            value: "\(group.numProcesses) PIDs",
                            sub: "R " + ByteFormat.rateString(latest?.blockReadBytesPerSec ?? 0),
                            color: .blue
                        )
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        MetricChartCard(
                            title: store.t("Group CPU (%)", "Grup CPU (%)"),
                            subtitle: store.t("Sum of all containers in this group", "Bu gruptaki tüm konteynerlerin toplamı"),
                            currentValueText: String(format: "%.1f%%", group.cpuPercent),
                            secondaryBadgeText: group.cpuLimitCores > 0 ? "\(group.cpuLimitCores) vCPU" : nil,
                            icon: "cpu",
                            accentColor: .cyan,
                            samples: history,
                            valueExtractor: { $0.cpuPercent },
                            maxYHint: Double(max(1, group.cpuLimitCores)) * 100
                        )

                        MetricChartCard(
                            title: store.t("Group Memory (MB)", "Grup Belleği (MB)"),
                            subtitle: store.t("Combined memory of the group's containers", "Grubun konteynerlerinin toplam belleği"),
                            currentValueText: ByteFormat.string(group.memoryUsageBytes),
                            secondaryBadgeText: group.memoryLimitBytes > 0 ? "Limit \(ByteFormat.string(group.memoryLimitBytes))" : nil,
                            icon: "memorychip",
                            accentColor: .purple,
                            samples: history,
                            valueExtractor: { $0.memoryUsageMB },
                            maxYHint: group.memoryLimitBytes > 0 ? Double(group.memoryLimitBytes) / (1024 * 1024) : nil
                        )

                        DualMetricChartCard(
                            title: store.t("Group Network", "Grup Ağ Trafiği"),
                            subtitle: store.t("Combined RX / TX rate (KB/s)", "Toplam RX / TX hızı (KB/s)"),
                            icon: "network",
                            primaryLabel: "RX",
                            secondaryLabel: "TX",
                            primaryValueText: String(format: "%.1f KB/s", latest?.netRxKBps ?? 0),
                            secondaryValueText: String(format: "%.1f KB/s", latest?.netTxKBps ?? 0),
                            primaryColor: .green,
                            secondaryColor: .blue,
                            samples: history,
                            primaryExtractor: { $0.netRxKBps },
                            secondaryExtractor: { $0.netTxKBps }
                        )

                        DualMetricChartCard(
                            title: store.t("Group Disk I/O", "Grup Disk I/O"),
                            subtitle: store.t("Combined read / write rate (KB/s)", "Toplam okuma / yazma hızı (KB/s)"),
                            icon: "internaldrive",
                            primaryLabel: store.t("Read", "Okuma"),
                            secondaryLabel: store.t("Write", "Yazma"),
                            primaryValueText: String(format: "%.1f KB/s", latest?.diskReadKBps ?? 0),
                            secondaryValueText: String(format: "%.1f KB/s", latest?.diskWriteKBps ?? 0),
                            primaryColor: .orange,
                            secondaryColor: .pink,
                            samples: history,
                            primaryExtractor: { $0.diskReadKBps },
                            secondaryExtractor: { $0.diskWriteKBps }
                        )
                    }

                    memberTable
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(group.state.color.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: "square.stack.3d.down.right.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(group.state.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(group.name)
                        .font(.system(size: 16, weight: .bold))
                    Text(store.t(
                        "\(group.runningCount) of \(group.containers.count) running",
                        "\(group.containers.count) konteynerden \(group.runningCount) tanesi çalışıyor"
                    ))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(group.state.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(group.state.color.opacity(0.12), in: Capsule())
                }
                Text(store.t("Compose project on \(group.backend.displayName)", "\(group.backend.displayName) üzerinde Compose projesi"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if group.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            if let stack = store.stack(for: group) {
                Button {
                    store.selectedStackID = stack.id
                    store.selectedSidebar = .stacks
                } label: {
                    Label(store.t("Compose File", "Compose Dosyası"), systemImage: "doc.text")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
            GroupActionButtons(store: store, group: group, compact: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Per-container share of the group's CPU and memory, with per-container controls.
    private var memberTable: some View {
        let maxCPU = max(group.containers.map { $0.cpuPercentDisplay }.max() ?? 0, 1)
        let maxMemory = max(group.containers.map { $0.memoryUsageBytes }.max() ?? 0, 1)

        return VStack(alignment: .leading, spacing: 8) {
            Text(store.t("Containers in this group", "Bu gruptaki konteynerler"))
                .font(.system(size: 13, weight: .semibold))

            ForEach(group.containers) { container in
                HStack(spacing: 12) {
                    Circle()
                        .fill(container.state.color)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.labels["com.docker.compose.service"] ?? container.name)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                        Text(container.image)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 190, alignment: .leading)

                    usageBar(
                        label: "CPU",
                        text: container.state == .running ? String(format: "%.1f%%", container.cpuPercentDisplay) : "—",
                        fraction: container.cpuPercentDisplay / maxCPU,
                        color: .cyan
                    )
                    usageBar(
                        label: "MEM",
                        text: container.state == .running ? ByteFormat.string(container.memoryUsageBytes) : "—",
                        fraction: container.state == .running ? Double(container.memoryUsageBytes) / Double(maxMemory) : 0,
                        color: .purple
                    )

                    Button {
                        store.toggleContainerState(container)
                    } label: {
                        Image(systemName: container.state == .running ? "stop.fill" : "play.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(container.state == .starting || container.state == .stopping)
                    .help(container.state == .running ? store.t("Stop", "Durdur") : store.t("Start", "Başlat"))

                    Button {
                        store.selectContainer(container.id)
                    } label: {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(store.t("Inspect this container", "Bu konteyneri incele"))
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func usageBar(label: String, text: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(text)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, min(1, fraction)) * proxy.size.width)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }

    private func pill(title: String, value: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
}
