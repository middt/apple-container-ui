import SwiftUI

struct NewContainerSheet: View {
    @ObservedObject var store: ContainerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run New Apple Container MicroVM")
                        .font(.system(size: 16, weight: .bold))
                    Text("Spawns an isolated Linux virtual machine via Apple Virtualization.framework")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Form {
                Section("Container Identity & OCI Image") {
                    TextField("Container Name", text: $store.newContainerName)
                        .font(.system(size: 12, design: .monospaced))
                    TextField("OCI Image Reference", text: $store.newContainerImage)
                        .font(.system(size: 12, design: .monospaced))

                    HStack(spacing: 6) {
                        Text("Presets:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ForEach(["nginx:1.27-alpine", "postgres:17.2-alpine", "valkey/valkey:8.0-alpine", "ubuntu:24.04", "python:3.13-slim"], id: \.self) { preset in
                            Button(preset) {
                                store.newContainerImage = preset
                                store.newContainerName = preset.split(separator: ":").first?.split(separator: "/").last.map { "\($0)-\(Int.random(in: 10...99))" } ?? "container-vm"
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }

                Section("Hardware MicroVM Allocation") {
                    Stepper("Allocated vCPUs: \(store.newContainerCPUs) Cores", value: $store.newContainerCPUs, in: 1...16)
                    Picker("Memory Limit", selection: $store.newContainerMemoryMB) {
                        Text("256 MB").tag(256)
                        Text("512 MB").tag(512)
                        Text("1024 MB (1 GB)").tag(1024)
                        Text("2048 MB (2 GB)").tag(2048)
                        Text("4096 MB (4 GB)").tag(4096)
                        Text("8192 MB (8 GB)").tag(8192)
                    }
                }

                Section("Networking & Port Publishing (vmnet)") {
                    HStack {
                        TextField("Host Port (e.g. 8090)", text: $store.newContainerHostPort)
                        Text("→")
                        TextField("Container Port (e.g. 80)", text: $store.newContainerTargetPort)
                        Picker("Protocol", selection: $store.newContainerPortProtocol) {
                            ForEach(PortAppProtocol.allCases) { proto in
                                Text(proto.rawValue.uppercased()).tag(proto)
                            }
                        }
                        .frame(width: 110)
                    }
                    Picker("vmnet Bridge Network", selection: $store.newContainerNetwork) {
                        ForEach(store.networks) { net in
                            Text("\(net.name) (\(net.subnet))").tag(net.name)
                        }
                    }
                }

                Section("VirtioFS Host Directory Mount & Environment") {
                    HStack {
                        TextField("Host Path (optional, e.g. ~/projects/app)", text: $store.newContainerMountSource)
                        Text("→")
                        TextField("Guest Path", text: $store.newContainerMountDest)
                    }
                    HStack {
                        TextField("ENV Key", text: $store.newContainerEnvKey)
                        Text("=")
                        TextField("ENV Value", text: $store.newContainerEnvValue)
                    }
                    TextField("Custom Entrypoint Command (optional)", text: $store.newContainerCommand)
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 4) {
                Text("Equivalent CLI Command:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(store.previewRunCommand)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    var envDict: [String: String] = [:]
                    if !store.newContainerEnvKey.isEmpty {
                        envDict[store.newContainerEnvKey] = store.newContainerEnvValue
                    }
                    store.createAndRunContainer(
                        name: store.newContainerName,
                        image: store.newContainerImage,
                        cpus: store.newContainerCPUs,
                        memoryMB: store.newContainerMemoryMB,
                        hostPort: Int(store.newContainerHostPort),
                        containerPort: Int(store.newContainerTargetPort),
                        portProtocol: store.newContainerPortProtocol,
                        mountSource: store.newContainerMountSource,
                        mountDest: store.newContainerMountDest,
                        envPairs: envDict,
                        network: store.newContainerNetwork,
                        command: store.newContainerCommand
                    )
                    dismiss()
                } label: {
                    Label("Create & Boot MicroVM", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 610)
    }
}
