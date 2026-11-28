import SwiftUI

@main
struct StudioPortalApp: App {
    @State private var configured: Bool
    @StateObject private var downloads = Downloads()
    @Environment(\.scenePhase) private var phase

    init() {
        #if DEBUG
        // Simulator test: SIMCTL_CHILD_STUDIOPORTAL_TOKEN=… xcrun simctl launch … (keeps the token out of logs)
        if let t = ProcessInfo.processInfo.environment["STUDIOPORTAL_TOKEN"], !t.isEmpty { API.token = t }
        #endif
        _configured = State(initialValue: !API.token.isEmpty)
    }

    var body: some Scene {
        WindowGroup {
            if configured {
                TabView {
                    Tab("Erstellen", systemImage: "sparkles") { CreateView() }
                    Tab("Chat", systemImage: "text.bubble") { ChatView() }
                    Tab("Bibliothek", systemImage: "square.grid.2x2") { LibraryView() }
                    Tab("Werkzeuge", systemImage: "wrench.and.screwdriver") { ToolsView() }
                    Tab("Rechner", systemImage: "cpu") { MachineView() }
                }
                .environmentObject(downloads)
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        await downloads.sync()
                        try? await Task.sleep(for: .seconds(90))
                    }
                }
            } else {
                SetupView { configured = true }
            }
        }
    }
}
