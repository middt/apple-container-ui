import SwiftUI
import AppKit

// MARK: - OCI Images View

struct ImagesListView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OCI Container Images")
                        .font(.system(size: 16, weight: .bold))
                    Text("\(store.images.count) images cached locally • Total \(ByteFormat.string(store.totalImagesSizeBytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    TextField("Registry reference (e.g. redis:alpine, ghcr.io/...)", text: $store.pullRefInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 260)

                    Button {
                        store.pullImage(reference: store.pullRefInput)
                    } label: {
                        Label("Pull Image", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)

            Divider()

            List {
                ForEach(store.images) { image in
                    HStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.cyan)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(image.repository)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Text(image.tag)
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.cyan)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.cyan.opacity(0.14), in: Capsule())
                                Text("\(image.os)/\(image.arch)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Text(image.layersCount > 0 ? "\(image.digest)  •  \(image.layersCount) OCI layers" : image.digest)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(ByteFormat.stringOrDash(image.sizeBytes))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 90, alignment: .trailing)

                        HStack(spacing: 6) {
                            Button {
                                store.createAndRunContainer(
                                    name: "\(image.repository.split(separator: "/").last ?? "app")-\(Int.random(in: 10...99))",
                                    image: image.fullReference,
                                    cpus: 2,
                                    memoryMB: 1024,
                                    hostPort: image.exposedPorts.first.map { $0 + 8000 },
                                    containerPort: image.exposedPorts.first,
                                    mountSource: "",
                                    mountDest: "",
                                    envPairs: [:],
                                    network: "default",
                                    command: ""
                                )
                            } label: {
                                Label("Run", systemImage: "play.fill")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button(role: .destructive) {
                                store.deleteImage(image)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Volumes View

struct VolumesListView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Persistent Volumes (VirtioFS & Block)")
                        .font(.system(size: 16, weight: .bold))
                    Text("Managed via `container volume` and shared into Linux microVMs")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    TextField("New volume name…", text: $store.newVolumeName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 180)

                    Button {
                        guard !store.newVolumeName.isEmpty else { return }
                        store.createVolume(name: store.newVolumeName, sizeGB: store.newVolumeSizeGB)
                        store.newVolumeName = ""
                    } label: {
                        Label("Create Volume", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)

            Divider()

            List {
                ForEach(store.volumes) { vol in
                    HStack(spacing: 14) {
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.purple)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(vol.name)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Text(vol.driver)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                            Text(vol.mountpoint)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !vol.attachedContainers.isEmpty {
                            Text("In use by: \(vol.attachedContainers.joined(separator: ", "))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.green)
                        } else {
                            Text("Unused")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Text(ByteFormat.stringOrDash(vol.sizeBytes))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 85, alignment: .trailing)

                        Button(role: .destructive) {
                            store.requestDeleteVolume(vol)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Networks View (`vmnet`)

struct NetworksListView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS vmnet Container Networks")
                        .font(.system(size: 16, weight: .bold))
                    Text("Dedicated virtual network bridges with automatic DNS resolution")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    TextField("Network name", text: $store.newNetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 140)

                    TextField("Subnet CIDR", text: $store.newNetSubnet)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 140)

                    Button {
                        guard !store.newNetName.isEmpty else { return }
                        store.createNetwork(name: store.newNetName, subnet: store.newNetSubnet)
                        store.newNetName = ""
                    } label: {
                        Label("Create Network", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)

            Divider()

            List {
                ForEach(store.networks) { net in
                    HStack(spacing: 14) {
                        Image(systemName: "network")
                            .font(.system(size: 18))
                            .foregroundStyle(.green)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(net.name)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Text(net.mode)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                                if !net.interfaceName.isEmpty {
                                    Text("Interface: \(net.interfaceName)")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text([
                                net.subnet.isEmpty ? nil : "Subnet: \(net.subnet)",
                                net.gateway.isEmpty ? nil : "Gateway: \(net.gateway)",
                                net.dnsDomain.isEmpty ? nil : "DNS: *.\(net.dnsDomain)"
                            ].compactMap { $0 }.joined(separator: "  •  "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text("\(net.connectedContainers.count) containers")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if net.name != "default" {
                            Button(role: .destructive) {
                                store.deleteNetwork(net)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - CLI Activity Log & Settings View

struct ActivityAndSettingsView: View {
    @ObservedObject var store: ContainerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(store.t("Language & Apple `container` CLI", "Dil & Apple `container` CLI")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Picker(store.t("Interface Language:", "Arayüz Dili:"), selection: $store.language) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text("\(lang.displayName) (\(lang.shortCode))").tag(lang)
                            }
                        }
                        .frame(width: 240)

                        Spacer()

                        if let path = store.detectedBinaryPath {
                            Label("Detected: \(path)", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.green)
                        } else {
                            Label(store.t("`container` binary not found", "`container` binary bulunamadı"), systemImage: "info.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Custom container binary path (e.g. /usr/local/bin/container)", text: $store.customBinaryPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        Button("Detect / Verify") {
                            store.recheckBinary()
                        }
                        .buttonStyle(.bordered)

                        Link(destination: URL(string: "https://github.com/apple/container/releases")!) {
                            Label("Official Releases", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let msg = store.statusBannerMessage {
                        Text(msg)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack {
                Text(store.t("Executed Apple Container CLI Commands", "Çalıştırılan Apple Container CLI Komutları"))
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button(store.t("Clear History", "Geçmişi Temizle")) {
                    store.commandLog.removeAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)

            List(store.commandLog) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("$ \(item.command)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan)
                        Spacer()
                        Text("\(item.durationMs) ms")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("exit \(item.exitCode)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(item.exitCode == 0 ? .green : .red)
                    }
                    if !item.outputPreview.isEmpty {
                        Text(item.outputPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}
