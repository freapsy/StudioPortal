import SwiftUI
import AppKit
import UserNotifications

enum Tool: String, CaseIterable, Identifiable {
    case image, music, speech, video, threeD, blender, llm, phone, importer, library, machine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .image: "Bild-Generator"; case .music: "Musik"; case .speech: "Sprache"; case .video: "Video"; case .threeD: "Bild zu 3D"; case .blender: "Blender"; case .llm: "LLM-Chat"; case .phone: "Telefon-Test"; case .importer: "Modell importieren"
        case .library: "Bibliothek"; case .machine: "Rechner"
        }
    }
    var icon: String {
        switch self {
        case .image: "sparkles"; case .music: "music.note"; case .speech: "waveform.and.mic"; case .video: "film"; case .threeD: "cube.transparent"; case .blender: "rotate.3d"; case .llm: "text.bubble"; case .phone: "phone.connection"; case .importer: "square.and.arrow.down"
        case .library: "square.grid.2x2"; case .machine: "cpu"
        }
    }
}

@MainActor
final class Portal: ObservableObject {
    @Published var tool: Tool = .image
    @Published var machine = MachineStatus()
    @Published var libraryVersion = 0
    let images = ImageStudio()
    let music = MusicStudio()
    let speech = SpeechStudio()
    let video = VideoStudio()
    let threeD = ThreeDJob()
    let importer = DownloadManager()
    let blender = BlenderMonitor()
    let llm = LLMStudio()
    let phone = PhoneCallStudio()
    let livekitPhone = LiveKitPhoneStudio()
    let sync = SyncEngine.shared

    init() {
        moveLegacyFoldersToStori()
        let finished: () -> Void = { [weak self] in
            self?.libraryVersion += 1
            self?.sync.schedule()
        }
        images.onFinish = finished; music.onFinish = finished; speech.onFinish = finished; video.onFinish = finished
        threeD.manager.onFinish = finished; importer.onFinish = finished; threeD.figure.onFinish = finished
        sync.onReceived = { [weak self] in
            self?.libraryVersion += 1
            self?.images.refreshHistory(); self?.music.refresh(); self?.speech.refresh(); self?.video.refresh()
        }
    }

    func useFor3D(_ url: URL) {
        threeD.images["front"] = url
        tool = .threeD
    }

    func open(_ item: LibraryItem) {
        switch item.kind {
        case .image: images.refreshHistory(select: item.url); tool = .image
        case .music: music.refresh(select: item.url); tool = .music
        case .speech: speech.refresh(select: item.url); tool = .speech
        case .video: video.refresh(select: item.url); tool = .video
        case .model:
            let source = Library.models().first { $0.url == item.url }?.source
            if source == "hunyuan3d-omni" { threeD.mode = "figur" }
            tool = source == "import" ? .importer : .threeD
        }
    }

    func trash(_ item: LibraryItem) {
        switch item.kind {
        case .image: images.trash(HistoryItem(url: item.url, metadata: nil, date: item.date))
        case .music: music.trash(Song.load(item.url, measureLength: false))
        case .speech: speech.trash(SpeechClip.load(item.url))
        case .video: video.trash(VideoItem(url: item.url, info: nil, date: item.date))
        case .model: try? trashLibraryFiles([item.url, ModelRecord.metaFolder(for: item.url)])
        }
        libraryVersion += 1
    }

    func refreshStatus() async {
        let current = await Task.detached(priority: .utility) { MachineStatus.fetch() }.value
        if !Task.isCancelled { machine = current }
    }
}

struct RootView: View {
    @ObservedObject var portal: Portal
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            Sidebar(portal: portal)
                .navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 270)
        } detail: {
            Group {
                switch portal.tool {
                case .image: ImageToolView(studio: portal.images, useFor3D: portal.useFor3D)
                case .music: MusicToolView(studio: portal.music)
                case .speech: SpeechToolView(studio: portal.speech)
                case .video: VideoToolView(studio: portal.video)
                case .threeD: ThreeDToolView(job: portal.threeD, manager: portal.threeD.manager)
                case .blender: BlenderTabView(monitor: portal.blender)
                case .llm: LLMToolView(studio: portal.llm)
                case .phone: PhoneCallView(studio: portal.phone, livekit: portal.livekitPhone)
                case .importer: ImportToolView(manager: portal.importer)
                case .library: LibraryView(portal: portal)
                case .machine: MachineView(portal: portal)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { GlobalPlayer(music: portal.music) }
        }
        .navigationTitle(portal.tool.title)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            portal.sync.schedule()
            while !Task.isCancelled {
                if portal.tool != .machine { await portal.refreshStatus() }
                try? await Task.sleep(for: .seconds(portal.machine.ownJobs > 0 || !portal.machine.queue.isEmpty ? 6 : 30))
            }
        }
    }
}

private struct GlobalPlayer: View {
    @ObservedObject var music: MusicStudio
    var body: some View {
        if music.playing != nil {
            VStack(spacing: 0) { Divider(); PlayerBar(studio: music) }
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var portal: Portal
    @ObservedObject private var images: ImageStudio
    @ObservedObject private var music: MusicStudio
    @ObservedObject private var speech: SpeechStudio
    @ObservedObject private var video: VideoStudio
    @ObservedObject private var threeD: DownloadManager
    @ObservedObject private var importer: DownloadManager
    @ObservedObject private var sync: SyncEngine
    @ObservedObject private var llm: LLMStudio
    @ObservedObject private var phone: PhoneCallStudio

    init(portal: Portal) {
        self.portal = portal
        images = portal.images; music = portal.music; speech = portal.speech; video = portal.video; threeD = portal.threeD.manager; importer = portal.importer; sync = portal.sync; llm = portal.llm; phone = portal.phone
    }

    private func busy(_ tool: Tool) -> Bool {
        switch tool {
        case .image: images.running; case .music: music.running; case .speech: speech.running; case .video: video.running; case .threeD: threeD.working; case .blender: false; case .llm: llm.running; case .phone: phone.callActive || phone.phase == .startingStack; case .importer: importer.working
        case .library: sync.running; case .machine: false
        }
    }

    var body: some View {
        List(selection: Binding(get: { portal.tool }, set: { if let value = $0 { portal.tool = value } })) {
            Section("Erstellen") { row(.image); row(.music); row(.speech); row(.video); row(.threeD); row(.blender) }
            Section("Sprachmodell") { row(.llm); row(.phone) }
            Section("Importieren") { row(.importer) }
            Section("Ablage") { row(.library); row(.machine) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(LinearGradient(colors: [.indigo, .accentColor], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 7))
                Text("StudioPortal").font(.title3.weight(.semibold))
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Einstellungen (⌘,)")
            }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if sync.enabled { SyncBadge(sync: sync) }
                MachineCard(machine: portal.machine) { portal.tool = .machine }
            }.padding(10)
        }
    }

    private func row(_ tool: Tool) -> some View {
        HStack {
            Label(tool.title, systemImage: tool.icon)
            Spacer()
            if busy(tool) { ProgressView().controlSize(.mini) }
        }.tag(tool)
    }
}

private struct SyncBadge: View {
    @ObservedObject var sync: SyncEngine
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: sync.running ? "arrow.triangle.2.circlepath" : sync.lastError == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                .foregroundStyle(sync.lastError == nil ? Color.secondary : Color.orange)
            Text(sync.shortStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }.padding(.horizontal, 4)
    }
}

/// Posts a notification when a job finishes while StudioPortal is in the background.
enum Notifier {
    static func setup() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    @MainActor static func finished(_ title: String, _ body: String) {
        guard NSApp != nil, !NSApp.isActive, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Notifier.setup() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct StudioPortalApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var appDelegate
    @StateObject private var portal = Portal()

    var body: some Scene {
        Window("StudioPortal", id: "main") { RootView(portal: portal).frame(minWidth: 1080, minHeight: 700) }
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unifiedCompact)
            .commands {
                CommandGroup(after: .sidebar) {
                    ForEach(Array(Tool.allCases.prefix(9).enumerated()), id: \.element) { index, tool in
                        Button(tool.title) { portal.tool = tool }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
            }
        SwiftUI.Settings { SettingsView(portal: portal) }
    }
}

/// One binary: without arguments the app, with a command the agent interface (`studioportal …`, `studioportal mcp`).
@main
enum Main {
    static func main() {
        if AgentCLI.handles(CommandLine.arguments) {
            exit(AgentCLI.run(Array(CommandLine.arguments.dropFirst())))
        }
        StudioPortalApp.main()
    }
}
