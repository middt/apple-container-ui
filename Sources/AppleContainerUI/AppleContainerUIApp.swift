import SwiftUI
import AppKit

@main
struct AppleContainerUIApp: App {
    @StateObject private var store = ContainerStore()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Vessel — Apple Container Studio") {
            MainWindowView(store: store)
                .frame(minWidth: 1080, idealWidth: 1280, minHeight: 680, idealHeight: 800)
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandMenu("Containers") {
                Button("Run New Container MicroVM…") {
                    store.showNewContainerSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Refresh Containers & Telemetry") {
                    Task {
                        await store.refreshAll()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    Button("Switch to \(item.rawValue)") {
                        store.selectedSidebar = item
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                }
            }
        }

        MenuBarExtra("Vessel", systemImage: "shippingbox.fill") {
            MenuBarTrayView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
