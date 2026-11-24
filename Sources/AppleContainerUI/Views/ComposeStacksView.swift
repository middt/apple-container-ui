import SwiftUI
import AppKit

struct ComposeStacksView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        HSplitView {
            // LEFT MASTER LIST OF COMPOSE STACKS
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.t("Compose Stacks", "Compose Yığınları"))
                            .font(.system(size: 14, weight: .bold))
                        Text(store.t("Run docker-compose.yml directly on Apple Container", "docker-compose.yml dosyalarını doğrudan çalıştırın"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.importComposeFileFromDisk()
                    } label: {
                        Label(store.t("Import YAML", "YAML İçe Aktar"), systemImage: "folder.badge.plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(12)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.stacks) { stack in
                            let isSelected = store.selectedStack?.id == stack.id
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(stack.status.color)
                                    .frame(width: 9, height: 9)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(stack.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(stack.targetBackend.shortBadge)
                                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(stack.targetBackend == .appleContainer ? .cyan : .blue)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background((stack.targetBackend == .appleContainer ? Color.cyan : Color.blue).opacity(0.14), in: Capsule())
                                    }
                                    Text("\(stack.services.count) services • \(stack.filePath.split(separator: "/").suffix(2).joined(separator: "/"))")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if stack.status == .starting || stack.status == .stopping {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Button {
                                        if stack.status == .running {
                                            store.stopStack(stack)
                                        } else {
                                            store.deployStack(stack)
                                        }
                                    } label: {
                                        Text(stack.status == .running ? "Down" : "Up")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(stack.status == .running ? .orange : .green)
                                    .controlSize(.small)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.selectedStackID = stack.id
                            }
                            .contextMenu {
                                Button(store.t("Remove from Vessel", "Vessel'den kaldır"), role: .destructive) {
                                    store.removeStack(stack)
                                }
                                .disabled(stack.status != .stopped)
                            }
                        }
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 330, idealWidth: 360, maxWidth: 420)
            .background(Color(nsColor: .windowBackgroundColor))

            // RIGHT STACK INSPECTOR
            if let stack = store.selectedStack {
                VStack(spacing: 0) {
                    stackHeader(for: stack)
                    Divider()
                    stackTabBar
                    Divider()

                    Group {
                        switch store.selectedStackTab {
                        case .topology:
                            stackTopologyTab(for: stack)
                        case .yaml:
                            stackYAMLEditorTab(for: stack)
                        case .plan:
                            stackExecutionPlanTab(for: stack)
                        case .logs:
                            stackLogsTab(for: stack)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text(store.t("Select or import a docker-compose.yml stack", "Bir docker-compose.yml yığını seçin veya içe aktarın"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func stackHeader(for stack: ComposeStackItem) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: "square.stack.3d.down.right.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(stack.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    Text(stack.status.localizedLabel(in: store.language))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(stack.status.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(stack.status.color.opacity(0.14), in: Capsule())
                        .fixedSize()
                }
                Text(stack.filePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                store.deployStack(stack)
            } label: {
                Label(store.t("Stack Up", "Yığını Başlat"), systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(stack.status == .starting || stack.status == .stopping)

            if stack.status == .running {
                Button {
                    store.stopStack(stack)
                } label: {
                    Label(store.t("Stack Down", "Yığını Durdur"), systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stackTabBar: some View {
        HStack(spacing: 6) {
            ForEach(ComposeStackTab.allCases) { tab in
                let isSelected = store.selectedStackTab == tab
                Button {
                    store.selectedStackTab = tab
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

    // MARK: - TAB 1: Services & Topology

    private func stackTopologyTab(for stack: ComposeStackItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "bolt.shield.fill")
                        .foregroundStyle(.cyan)
                    Text(store.t(
                        "Zero-Conversion Mode: `docker-compose.yml` services run directly as isolated Apple Container Linux MicroVMs.",
                        "Sıfır Dönüştürme Modu: `docker-compose.yml` servisleri doğrudan izole Apple Container Linux MicroVM'leri olarak çalışır."
                    ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                ForEach(stack.services) { svc in
                    let liveContainer = store.container(for: svc, in: stack)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle()
                                .fill((liveContainer?.state ?? .stopped).color)
                                .frame(width: 9, height: 9)

                            Text(svc.name)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))

                            Text(svc.image)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.12), in: Capsule())

                            if !svc.dependsOn.isEmpty {
                                Text("depends_on: \(svc.dependsOn.joined(separator: ", "))")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                            }

                            Spacer()

                            Text("\(svc.cpus) vCPU • \(svc.memoryMB) MB")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)

                            if let liveContainer {
                                Button("Inspect VM") {
                                    store.selectContainer(liveContainer.id)
                                    store.selectedSidebar = .containers
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if !svc.ports.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(svc.ports) { p in
                                    HStack(spacing: 6) {
                                        Text(p.appProtocol.rawValue.uppercased())
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(p.isHTTPService ? .green : .orange)
                                        Text(p.displayString)
                                            .font(.system(size: 11.5, design: .monospaced))
                                        if p.isHTTPService, let url = p.browserURL {
                                            Button("Open \(url.absoluteString)") {
                                                NSWorkspace.shared.open(url)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.mini)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - TAB 2: Live `docker-compose.yml` Editor

    private func stackYAMLEditorTab(for stack: ComposeStackItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Standard `docker-compose.yml` — No manual conversion needed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.deployStack(stack)
                } label: {
                    Label(store.t("Apply YAML & Stack Up", "YAML Uygula & Başlat"), systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)

            Divider()

            TextEditor(text: Binding(
                get: { stack.yamlContent },
                set: { newVal in
                    store.updateStackYAML(stackID: stack.id, newYAML: newVal)
                }
            ))
            .font(.system(size: 12.5, design: .monospaced))
            .padding(10)
        }
    }

    // MARK: - TAB 3: Automatic Apple Container Execution Plan

    private func stackExecutionPlanTab(for stack: ComposeStackItem) -> some View {
        let steps = store.executionPlan(for: stack)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.t(
                    "How Vessel runs this Compose file on `apple/container`",
                    "Vessel bu Compose dosyasını `apple/container` üzerinde nasıl çalıştırır"
                ))
                    .font(.system(size: 14, weight: .bold))
                Text(store.t(
                    "'Stack Up' executes these native `apple/container` commands in dependency order. A step marked optional may fail without aborting the deployment.",
                    "'Stack Up' bu `apple/container` komutlarını bağımlılık sırasıyla çalıştırır. İsteğe bağlı işaretli bir adım başarısız olsa da dağıtım sürer."
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if !stack.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(stack.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("Step \(step.id + 1)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .frame(width: 55, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("$ \(step.displayCommand)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.green)
                                .textSelection(.enabled)
                            if let note = step.note {
                                Text((step.allowFailure ? store.t("Optional — ", "İsteğe bağlı — ") : "") + note)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
    }

    // MARK: - TAB 4: Combined Stack Logs

    private func stackLogsTab(for stack: ComposeStackItem) -> some View {
        let matchingContainers = store.containers(in: stack)

        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(matchingContainers) { c in
                    ForEach(c.logs) { log in
                        HStack(alignment: .top, spacing: 8) {
                            Text("[\(c.name)]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.cyan)
                                .frame(width: 165, alignment: .leading)
                            Text(log.message)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.opacity(0.24))
    }
}

