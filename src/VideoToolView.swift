import SwiftUI
import AppKit
import AVKit

struct VideoItem: Identifiable, Equatable {
    var url: URL
    var info: MediaInfo?
    var date: Date
    var id: String { url.path }
    var poster: URL? { let p = url.deletingPathExtension().appendingPathExtension("jpg"); return FileManager.default.fileExists(atPath: p.path) ? p : nil }
    var title: String { info?.title ?? url.deletingPathExtension().lastPathComponent }
    static func == (a: VideoItem, b: VideoItem) -> Bool { a.url == b.url && a.date == b.date }
}

@MainActor
final class VideoStudio: ObservableObject {
    @Published var settings = VideoSettings()
    @Published var seedLocked = false
    @Published var videos: [VideoItem] = []
    @Published var selected: VideoItem?
    @Published var running = false
    @Published var started = Date()
    @Published var progress = VideoProgress()
    @Published var errorMessage: String?
    var onFinish: (() -> Void)?
    private var control: RunControl?

    init() {
        settings.prompt = UserDefaults.standard.string(forKey: "videoPrompt") ?? ""
        refresh()
    }

    func refresh(select url: URL? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(at: videosDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        videos = files.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }.map { url in
            let info = (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json"))).flatMap { try? jsonDecoder().decode(MediaInfo.self, from: $0) }
            return VideoItem(url: url, info: info, date: info?.date ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.date > $1.date }
        if let url { selected = videos.first { $0.url == url } }
        else if let s = selected { selected = videos.first { $0.url == s.url } }
    }

    func start() {
        guard !running else { return }
        UserDefaults.standard.set(settings.prompt, forKey: "videoPrompt")
        if !seedLocked { settings.seed = Int64.random(in: 1...2_147_483_646) }
        let current = settings, newControl = RunControl()
        control = newControl; running = true; started = Date(); progress = VideoProgress()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try VideoBackend.generate(current, control: newControl) { state in Task { @MainActor [weak self] in self?.progress = state } }
                await MainActor.run { [weak self] in
                    self?.running = false; self?.control = nil; self?.refresh(select: url)
                    Notifier.finished("Video fertig", "Das Video ist bereit.")
                    self?.onFinish?()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.running = false; self.control = nil
                    if error.localizedDescription != "Abgebrochen." { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    func cancel() { progress.waiting = "Wird abgebrochen …"; control?.cancel() }

    func useSettings(_ item: VideoItem) {
        guard let info = item.info, info.kind == "h3-video" else { return }
        settings.prompt = info.title
        if let seed = info.seed { settings.seed = Int64(seed); seedLocked = true }
        if let frames = info.settings?["frames"].flatMap(Int.init) { settings.frames = frames }
        if let steps = info.settings?["steps"].flatMap(Int.init) { settings.steps = steps }
        if let cards = info.settings?["cards"].flatMap(Int.init) { settings.cards = cards }
        let size = (info.settings?["size"] ?? item.info?.detail.components(separatedBy: " · ").first ?? "")
            .replacingOccurrences(of: "×", with: "x").split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if size.count == 2 { settings.width = size[0]; settings.height = size[1] }
    }

    /// Same description and settings, new seed – starts right away.
    func vary(_ item: VideoItem) {
        useSettings(item)
        seedLocked = false
        start()
    }

    func trash(_ item: VideoItem) {
        let base = item.url.deletingPathExtension()
        do { try trashLibraryFiles([item.url, base.appendingPathExtension("json"), base.appendingPathExtension("jpg")]) }
        catch { errorMessage = "Das Video konnte nicht in den Papierkorb gelegt werden: \(error.localizedDescription)" }
        if selected?.url == item.url { selected = nil }
        refresh()
    }
}

struct VideoToolView: View {
    @ObservedObject var studio: VideoStudio

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Video", subtitle: "MiniMax H3 Turbo4 · Bild und Ton · bigki · nur privat (nicht in der EU veröffentlichen, nicht für Werbung)", icon: "film") {
                if let item = studio.selected {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Im Finder zeigen")
                }
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    VideoStage(studio: studio)
                    VideoComposer(studio: studio)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                VideoFeed(studio: studio)
            }
        }
        .onAppear { studio.refresh() }
        .alert("Hinweis", isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })) {
            Button("OK", role: .cancel) { studio.errorMessage = nil }
        } message: { Text(studio.errorMessage ?? "") }
    }
}

private func videoChips(_ item: VideoItem) -> some View {
    ChipFlow(spacing: 4) {
        if let info = item.info {
            if info.kind != "h3-video" { MetaChip(text: "Blender", icon: "cube") }
            if !info.detail.isEmpty { MetaChip(text: info.detail, icon: "film") }
            if let steps = info.settings?["steps"] { MetaChip(text: "\(steps) Schritte", icon: "stairs") }
            if let seed = info.seed { MetaChip(text: "\(seed)", icon: "dice") }
            if let seconds = info.seconds { MetaChip(text: elapsedText(TimeInterval(seconds)), icon: "clock") }
            if let origin = info.origin, !origin.isEmpty { let o = originDisplay(origin); MetaChip(text: o.text, icon: o.icon) }
        }
        MetaChip(text: item.date.formatted(date: .abbreviated, time: .shortened), icon: "calendar")
    }
}

// MARK: - Stage

private struct VideoStage: View {
    @ObservedObject var studio: VideoStudio
    @State private var player = AVPlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if studio.running { progressCard }
                if let item = studio.selected {
                    PlayerView(player: player)
                        .aspectRatio(aspect(item), contentMode: .fit)
                        .frame(maxHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) { StageCloseButton { player.pause(); studio.selected = nil }.padding(.top, -4) }
                        .onAppear { load(item) }
                        .onChange(of: item) { _, new in load(new) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.callout).textSelection(.enabled).lineLimit(6)
                        videoChips(item)
                        if item.info?.kind == "h3-video" {
                            HStack(spacing: 8) {
                                Button { studio.useSettings(item) } label: { Label("Übernehmen", systemImage: "arrow.uturn.backward") }
                                Button { studio.vary(item) } label: { Label("Variieren", systemImage: "dice") }.disabled(studio.running)
                            }.controlSize(.small)
                        }
                    }
                } else if !studio.running {
                    StartView(icon: "film", title: "Neues Video", steps: [
                        "Unten auf Englisch beschreiben: wer/was, was passiert, Kamera, Licht – und am Ende „Audio: …“ für die Geräusche.",
                        "Erst „Entwurf“ (2 s, ~3 min) wählen, um Bewegung und Ton zu prüfen.",
                        "Gefällt es: rechts „Übernehmen“, Voreinstellung „Clip“ oder „HD“ – gleicher Seed, gleiche Szene, länger und schärfer.",
                    ]) {
                        VStack(alignment: .leading, spacing: 6) {
                            PopoverTitle("Beispiel")
                            Button {
                                studio.settings.prompt = "A barista pours steamed milk into a cup of coffee, forming a leaf pattern. Slow dolly-in, 35mm, shallow depth of field. Warm morning light through a café window, natural colors. Audio: soft hiss of the milk, quiet café murmur; no music."
                            } label: {
                                Text("A barista pours steamed milk into a cup of coffee … Audio: soft hiss of the milk, quiet café murmur; no music.")
                                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).help("In die Eingabe übernehmen")
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .onDisappear { player.pause() }
    }

    private func aspect(_ item: VideoItem) -> CGFloat {
        let size = (item.info?.settings?["size"] ?? item.info?.detail.components(separatedBy: " · ").first ?? "")
            .replacingOccurrences(of: "×", with: "x").split(separator: "x").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return size.count == 2 && size[1] > 0 ? size[0] / size[1] : 16 / 9
    }

    private func load(_ item: VideoItem) {
        if (player.currentItem?.asset as? AVURLAsset)?.url != item.url { player.replaceCurrentItem(with: AVPlayerItem(url: item.url)) }
    }

    private var progressCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: studio.progress.waiting == nil ? "film" : "hourglass").foregroundStyle(Color.accentColor)
                    Text(studio.progress.text).font(.headline)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedText(context.date.timeIntervalSince(studio.started))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let step = studio.progress.step, let steps = studio.progress.steps, studio.progress.phase == "Rechnen" {
                    ProgressView(value: Double(step), total: Double(max(steps, 1))).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
                if !studio.progress.cards.isEmpty {
                    Text("Karten: " + studio.progress.cards.map { "GPU \($0)" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Composer

private struct VideoComposer: View {
    @ObservedObject var studio: VideoStudio
    private var activePreset: VideoPreset? { VideoPreset.all.first { $0.matches(studio.settings) } }
    private var sizeBinding: Binding<String> {
        Binding(get: { "\(studio.settings.width)x\(studio.settings.height)" },
                set: { value in
                    let parts = value.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { studio.settings.width = parts[0]; studio.settings.height = parts[1] }
                })
    }
    private var sizeTitle: String {
        VideoSettings.sizes.first { $0.1 == studio.settings.width && $0.2 == studio.settings.height }?.0 ?? "\(studio.settings.width)×\(studio.settings.height)"
    }

    var body: some View {
        Composer(text: $studio.settings.prompt,
                 placeholder: "Was passiert, Kamera, Licht … und am Ende: Audio: Geräusche, Musik oder Sprache (englisch).",
                 actionTitle: "Video erzeugen", actionIcon: "film", running: studio.running,
                 enabled: !studio.settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                 action: { studio.start() }, cancel: { studio.cancel() }) {
            EmptyView()
        } pills: {
            OptionPill(icon: activePreset?.choice.icon ?? "square.grid.2x2", title: activePreset?.choice.title ?? "Eigene Einstellung",
                       help: "Voreinstellung", highlighted: activePreset != nil, width: 360) {
                HStack {
                    PopoverTitle("Voreinstellung"); Spacer()
                    InfoButton(title: "Video – Regler erklärt", intro: "Turbo4 ist auf 4 Schritte destilliert; Sampler, Zeitplan, Shift und CFG sind auf die empfohlenen Werte fest eingestellt. Entscheidend sind Beschreibung, Länge und Format.",
                               items: VideoPreset.info, tips: VideoPreset.tips)
                }
                PresetGrid(presets: VideoPreset.all.map(\.choice), selected: activePreset?.choice.id) { choice in
                    VideoPreset.all.first { $0.choice.id == choice.id }?.apply(to: &studio.settings)
                }
            }
            OptionPill(icon: "clock", title: String(format: "%.1f s", Double(studio.settings.frames) / 24), help: "Länge", width: 320) {
                PopoverTitle("Länge")
                ChipPicker(options: VideoPreset.lengths, selection: $studio.settings.frames)
            }
            OptionPill(icon: "aspectratio", title: sizeTitle, help: "Format", width: 300) {
                PopoverTitle("Format")
                ChipPicker(options: VideoSettings.sizes.map { ($0.0, "\($0.1)x\($0.2)") }, selection: sizeBinding)
            }
            OptionPill(icon: "stairs", title: studio.settings.steps == 6 ? "6 Schritte" : "\(studio.settings.steps) · Entwurf", help: "Schritte", width: 280) {
                PopoverTitle("Schritte")
                ChipPicker(options: [("4 · Entwurf", 4), ("6 · Standard", 6)], selection: $studio.settings.steps)
                Text(studio.settings.steps == 6 ? "Standard – deutlich schärfer als 4 (5 s ≈ 8 min)." : "Schneller (5 s ≈ 5 min), aber weicher – gut zum Prüfen der Bewegung.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            OptionPill(icon: "cpu", title: "\(studio.settings.cards) Karten", help: "Grafikkarten", highlighted: studio.settings.cards == 3, width: 300) {
                PopoverTitle("Grafikkarten")
                ChipPicker(options: [("2 · empfohlen", 2), ("3 · Test", 3)], selection: $studio.settings.cards)
                Text(studio.settings.cards == 2
                     ? "Rechnet auf den zwei kühlsten MI50 – die dritte bleibt frei für Bilder, Musik oder Blender."
                     : "Alle drei Karten: kaum schneller, weil die Karten sich ständig abstimmen müssen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            OptionPill(icon: studio.seedLocked ? "lock.fill" : "dice", title: studio.seedLocked ? "Seed \(studio.settings.seed)" : "Seed zufällig",
                       help: "Seed", highlighted: studio.seedLocked, width: 280) {
                SeedEditor(seed: $studio.settings.seed, locked: $studio.seedLocked, range: 1...2_147_483_646,
                           note: "Gleicher Seed + gleiche Einstellungen = gleiches Video.")
            }
        }
    }
}

// MARK: - Feed

private struct VideoFeed: View {
    @ObservedObject var studio: VideoStudio
    var body: some View {
        VStack(spacing: 0) {
            FeedHeader(title: "Videos", count: studio.videos.count, folder: videosDirectory)
            if studio.videos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.title2).foregroundStyle(.tertiary)
                    Text("Deine Videos erscheinen hier – mit Beschreibung und Seed zum Wiederverwenden.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(studio.videos) { item in VideoCard(studio: studio, item: item) }
                    }.padding(10)
                }
            }
        }
        .frame(width: FeedMetrics.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct VideoCard: View {
    @ObservedObject var studio: VideoStudio
    var item: VideoItem
    @State private var hover = false
    private var selected: Bool { studio.selected?.url == item.url }
    private var h3: Bool { item.info?.kind == "h3-video" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                if let poster = item.poster {
                    FeedImage(url: poster)
                } else {
                    LinearGradient(colors: [.teal.opacity(0.6), .blue.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
            }
            Text(item.title).font(.system(size: 12)).lineLimit(3).help(item.title)
            videoChips(item)
            HStack(spacing: 6) {
                if h3 {
                    Button { studio.useSettings(item) } label: { Label("Übernehmen", systemImage: "arrow.uturn.backward") }
                        .help("Beschreibung, Länge, Format und Seed in die Eingabe übernehmen")
                    Button { studio.vary(item) } label: { Label("Variieren", systemImage: "dice") }
                        .help("Gleiche Einstellungen, neuer Seed – startet sofort").disabled(studio.running)
                }
                Spacer()
                Menu {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Divider()
                    Button("In den Papierkorb", role: .destructive) { studio.trash(item) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .controlSize(.small).buttonStyle(.bordered)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(hover ? 0.15 : 0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { studio.selected = selected ? nil : item }
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
    }
}

/// AppKit player instead of SwiftUI's VideoPlayer: the _AVKit_SwiftUI overlay crashes (missing superclass metadata)
/// in this swiftc-built app on macOS 27 as soon as the view is created.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
