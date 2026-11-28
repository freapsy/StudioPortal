import SwiftUI
import AppKit

/// Everything StudioPortal has made on this Mac (and, with sync, on the other one): images, songs, 3D models.
enum ItemKind: String, CaseIterable, Codable {
    case image, music, speech, video, model
    var title: String { switch self { case .image: "Bilder"; case .music: "Musik"; case .speech: "Sprache"; case .video: "Video"; case .model: "3D" } }
    var icon: String { switch self { case .image: "photo"; case .music: "music.note"; case .speech: "waveform.and.mic"; case .video: "film"; case .model: "cube" } }
}

struct LibraryItem: Identifiable, Hashable {
    var kind: ItemKind
    var url: URL
    var date: Date
    var title: String
    var detail: String
    var preview: URL?
    var origin: String?
    /// music: description and melody seed for the cover
    var caption: String? = nil
    var seed: Int64? = nil
    var instrumental = false
    var id: String { url.path }
}

/// Information stored next to a .blend in <folder>/.studioportal/<name>/ (written by from_images.mjs / download.mjs).
struct ModelRecord: Identifiable, Hashable {
    var url: URL
    var date: Date
    var size: Int64
    var source: String          // "images", "import" or "" for older files
    var model: String?
    var resolution: Int?
    var color: Bool
    var person: Bool
    var link: String?
    var origin: String?
    var durationSeconds: Int?
    var preview: URL?
    var inputs: [String: URL]
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var metaFolder: URL { Self.metaFolder(for: url) }

    static func metaFolder(for blend: URL) -> URL {
        blend.deletingLastPathComponent().appendingPathComponent(".studioportal", isDirectory: true)
            .appendingPathComponent(blend.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    var settingsText: String {
        var parts: [String] = []
        if source == "images" {
            if let model { parts.append(model == "turbo" ? "Turbo" : "Standard") }
            if let resolution { parts.append("\(resolution)") }
            parts.append(color ? (person ? "Farben · Person" : "Farben") : "ohne Farben")
        } else if source == "import", let link { parts.append(link.hasPrefix("/") ? URL(fileURLWithPath: link).lastPathComponent : link) }
        if let durationSeconds { parts.append(elapsedText(TimeInterval(durationSeconds))) }
        return parts.joined(separator: " · ")
    }
}

enum Library {
    static func models() -> [ModelRecord] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { ["blend", "glb"].contains($0.pathExtension.lowercased()) }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let folder = ModelRecord.metaFolder(for: url)
            let info = (try? Data(contentsOf: folder.appendingPathComponent("info.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var inputs: [String: URL] = [:]
            for (view, name) in info["inputs"] as? [String: String] ?? [:] where !name.contains("/") {
                inputs[view] = folder.appendingPathComponent(name)
            }
            let previewURL = folder.appendingPathComponent("preview.png")
            let date = (info["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? values?.contentModificationDate ?? .distantPast
            return ModelRecord(url: url, date: date, size: Int64(values?.fileSize ?? 0), source: info["source"] as? String ?? "",
                               model: info["model"] as? String, resolution: info["resolution"] as? Int,
                               color: info["color"] as? Bool ?? false, person: info["person"] as? Bool ?? false,
                               link: info["link"] as? String, origin: info["origin"] as? String,
                               durationSeconds: info["durationSeconds"] as? Int,
                               preview: FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : inputs["front"] ?? inputs.values.first,
                               inputs: inputs)
        }.sorted { $0.date > $1.date }
    }

    /// `models: false` skips the 3D folder – on the MacBook it is in ~/Downloads, where macOS may hold the first access
    /// until the user answers the privacy prompt; the page shows everything else first and adds the models afterwards.
    static func load(models includeModels: Bool = true) -> [LibraryItem] {
        var items: [LibraryItem] = []
        if (try? requireStori()) != nil {
            let files = (try? FileManager.default.contentsOfDirectory(at: picturesDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for url in files where url.pathExtension.lowercased() == "png" {
                let sidecar = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json"))
                let metadata = sidecar.flatMap { try? jsonDecoder().decode(RunMetadata.self, from: $0) }
                let media = metadata == nil ? sidecar.flatMap { try? jsonDecoder().decode(MediaInfo.self, from: $0) } : nil
                let date = metadata?.date ?? media?.date ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let prompt = (metadata?.settings.prompt ?? media?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let size = metadata.map { "\($0.settings.width)×\($0.settings.height)" } ?? media.map { "Blender · \($0.detail)" } ?? ""
                items.append(LibraryItem(kind: .image, url: url, date: date, title: prompt.isEmpty ? url.deletingPathExtension().lastPathComponent : prompt,
                                         detail: size, preview: url, origin: metadata?.origin ?? media?.origin))
            }
        }
        let songs = (try? FileManager.default.contentsOfDirectory(at: musicDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in songs where ["mp3", "wav"].contains(url.pathExtension.lowercased()) {
            let song = Song.load(url, measureLength: false)
            items.append(LibraryItem(kind: .music, url: url, date: song.date, title: song.title,
                                     detail: song.isPreview ? "Vorschau" : "Volle Qualität", preview: nil, origin: song.origin,
                                     caption: song.caption, seed: song.lmSeed, instrumental: song.isInstrumental))
        }
        let speeches = (try? FileManager.default.contentsOfDirectory(at: speechDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in speeches where url.pathExtension.lowercased() == "wav" {
            let clip = SpeechClip.load(url)
            let detail = clip.engine == "qwen3-tts" ? "Qwen3-TTS" : "Drama 3"
            items.append(LibraryItem(kind: .speech, url: url, date: clip.date, title: clip.title,
                                     detail: detail, preview: nil, origin: clip.origin))
        }
        let videos = (try? FileManager.default.contentsOfDirectory(at: videosDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in videos where ["mp4", "mov"].contains(url.pathExtension.lowercased()) {
            let info = (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json"))).flatMap { try? jsonDecoder().decode(MediaInfo.self, from: $0) }
            let poster = url.deletingPathExtension().appendingPathExtension("jpg")
            let date = info?.date ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            items.append(LibraryItem(kind: .video, url: url, date: date, title: info?.title ?? url.deletingPathExtension().lastPathComponent,
                                     detail: info.map { ($0.kind == "h3-video" ? "" : "Blender · ") + $0.detail } ?? "",
                                     preview: FileManager.default.fileExists(atPath: poster.path) ? poster : nil, origin: info?.origin))
        }
        if includeModels { items += modelItems() }
        return items.sorted { $0.date > $1.date }
    }

    static func modelItems(_ records: [ModelRecord]? = nil) -> [LibraryItem] {
        var items: [LibraryItem] = []
        for record in records ?? models() {
            items.append(LibraryItem(kind: .model, url: record.url, date: record.date, title: record.name,
                                     detail: record.source == "import" ? "Import" : record.source == "images" ? "Aus Bildern"
                                        : record.source == "hunyuan3d-omni" ? "Figur (Omni)" : record.url.pathExtension.lowercased() == "glb" ? "GLB" : "Blender-Datei",
                                     preview: record.preview, origin: record.origin))
        }
        return items
    }
}

/// Moves files to the Trash and remembers the deletion so sync removes them on the other Mac as well.
func trashLibraryFiles(_ urls: [URL]) throws {
    for url in urls where FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    SyncEngine.recordDeletion(urls)
}

// MARK: - Library page

/// Keeps the library list between tab switches; reloads only when something was made, synced or deleted (libraryVersion).
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published var items: [LibraryItem] = []
    @Published var loaded = false
    private var version: Int?

    func refresh(_ version: Int, force: Bool = false) {
        guard force || version != self.version else { return }
        self.version = version
        Task.detached(priority: .userInitiated) {
            let quick = Library.load(models: false)
            await MainActor.run { if !self.loaded { self.items = quick } }
            let records = Library.models()
            let all = (quick + Library.modelItems(records)).sorted { $0.date > $1.date }
            await MainActor.run { if all != self.items { self.items = all }; self.loaded = true }
            ModelPreviews.fill(records) { LibraryStore.shared.refresh(version, force: true) }
        }
    }
}

struct LibraryView: View {
    @ObservedObject var portal: Portal
    @ObservedObject private var store = LibraryStore.shared
    private var items: [LibraryItem] { store.items }
    @State private var filter: ItemKind?
    @State private var search = ""

    private var shown: [LibraryItem] {
        items.filter { item in
            (filter == nil || item.kind == filter) &&
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.url.lastPathComponent.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    Text("Alle").tag(ItemKind?.none)
                    ForEach(ItemKind.allCases, id: \.self) { kind in Label(kind.title, systemImage: kind.icon).tag(ItemKind?.some(kind)) }
                }.pickerStyle(.segmented).labelsHidden().frame(minWidth: 260, maxWidth: 400)
                Spacer()
                Text("\(shown.count) Einträge").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                TextField("Suchen", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 110, maxWidth: 220)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            if shown.isEmpty && !store.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                EmptyStateView(icon: "square.grid.2x2", title: items.isEmpty ? "Noch nichts erstellt" : "Nichts gefunden",
                               message: items.isEmpty ? "Bilder, Songs, Videos und 3D-Modelle erscheinen hier, sobald du sie erstellst – auch die vom anderen Mac, wenn die Synchronisation an ist." : "Ändere Filter oder Suchbegriff.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)], spacing: 18) {
                        ForEach(shown) { item in
                            LibraryTile(item: item, portal: portal, reload: reload)
                        }
                    }.padding(24).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { store.refresh(portal.libraryVersion) }
        .onChange(of: portal.libraryVersion) { _, version in store.refresh(version) }
    }

    private func reload() { store.refresh(portal.libraryVersion, force: true) }
}

private struct LibraryTile: View {
    var item: LibraryItem
    @ObservedObject var portal: Portal
    var reload: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let preview = item.preview {
                        // fixed square + overlay: a bare scaledToFill image reports its full width and pushed the grid
                        // under the sidebar in narrow windows
                        Color.clear.overlay { AsyncThumbnail(url: preview, size: 240) { Color.gray.opacity(0.12) } }
                    } else if item.kind == .music {
                        MusicCover(caption: item.caption ?? item.title, seed: item.seed, instrumental: item.instrumental, preview: item.detail == "Vorschau")
                    } else {
                        ZStack {
                            LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: item.kind.icon).font(.system(size: 42, weight: .light)).foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: hovering ? 2 : 1))
                Label(item.kind.title, systemImage: item.kind.icon).labelStyle(.iconOnly).font(.caption.weight(.semibold))
                    .padding(6).background(.ultraThinMaterial, in: Circle()).padding(8)
                if item.kind == .video {
                    Image(systemName: "play.circle.fill").font(.system(size: 38)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35)).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
                if item.kind == .music {
                    Button { portal.music.toggle(url: item.url) } label: {
                        Image(systemName: portal.music.isPlaying(item.url) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 38)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.35))
                    }
                    .buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if item.kind == .speech {
                    Button { portal.speech.togglePlay(SpeechClip.load(item.url)) } label: {
                        let playing = portal.speech.playingURL == item.url && portal.speech.isPlayingClip
                        Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 38)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.35))
                    }
                    .buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(item.title).font(.callout.weight(.medium)).lineLimit(2).frame(height: 36, alignment: .topLeading)
            HStack(spacing: 4) {
                Text(item.date.formatted(.relative(presentation: .named))).lineLimit(1)
                if !item.detail.isEmpty { Text("· \(item.detail)").lineLimit(1) }
                Spacer(minLength: 0)
                if let origin = item.origin, origin.contains("Agent") { Image(systemName: "sparkle").help(origin) }
                else if let origin = item.origin, !origin.hasPrefix(machineName) { Image(systemName: "laptopcomputer.and.arrow.down").help("Erstellt auf: \(origin)") }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { portal.open(item) }
        .contextMenu {
            Button("Öffnen") { portal.open(item) }
            if item.kind == .image { Button("Zu 3D …") { portal.useFor3D(item.url) } }
            if item.kind == .model { Button("In Blender öffnen") { openInBlender(item.url) }.disabled(blenderApplication() == nil) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("In den Papierkorb", role: .destructive) { portal.trash(item); reload() }
        }
    }
}

// MARK: - 3D history (Bild zu 3D and Import)

struct ModelHistory: View {
    var source: String
    var refresh: URL?
    var rerun: ((ModelRecord) -> Void)?
    @State private var records: [ModelRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VERLAUF").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                Button { NSWorkspace.shared.open(modelsDirectory) } label: { Label("Ordner öffnen", systemImage: "folder") }
                    .buttonStyle(.borderless).font(.caption).disabled(!FileManager.default.fileExists(atPath: modelsDirectory.path))
            }
            if records.isEmpty {
                Text(source == "import" ? "Noch keine importierten Modelle." : source == "figur" ? "Noch keine Figuren." : "Noch keine 3D-Modelle aus Bildern.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(records) { record in ModelRow(record: record, rerun: rerun, deleted: load) }
                }
            }
        }
        .task(id: refresh) { load() }
    }

    private func load() {
        records = Library.models().filter { record in
            switch source {
            case "import": record.source == "import"
            case "figur": record.source == "hunyuan3d-omni"
            default: record.source != "import" && record.source != "hunyuan3d-omni"
            }
        }
        ModelPreviews.fill(records) { load() }
    }
}

private struct ModelRow: View {
    var record: ModelRecord
    var rerun: ((ModelRecord) -> Void)?
    var deleted: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let preview = record.preview {
                    AsyncThumbnail(url: preview, size: 84, fill: false) { Color.clear }
                } else {
                    Image(systemName: "cube.fill").font(.system(size: 26)).foregroundStyle(Color.accentColor.opacity(0.7))
                }
            }
            .frame(width: 84, height: 84)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(record.date.formatted(date: .abbreviated, time: .shortened) + " · " + ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                if !record.settingsText.isEmpty { Text(record.settingsText).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if !record.inputs.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(["front", "left", "back", "right"], id: \.self) { view in
                            if let url = record.inputs[view] { thumbnail(url, size: 20) }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Blender") { openInBlender(record.url) }.disabled(blenderApplication() == nil)
                    if let rerun, record.source == "images", !record.inputs.isEmpty { Button("Erneut") { rerun(record) } }
                    Menu {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([record.url]) }
                        Button("In den Papierkorb", role: .destructive) {
                            try? trashLibraryFiles([record.url, record.metaFolder]); deleted()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openInBlender(record.url) }
    }
}

// MARK: - Missing 3D previews

/// Renders a small Workbench preview (512 px, ~3 s on the Mac's own Blender, no bigki) for every .blend that has none –
/// once, one at a time, at low priority. A failure is remembered (preview-failed) so it is not retried on every visit.
enum ModelPreviews {
    nonisolated(unsafe) private static var running = false
    private static let lock = NSLock()

    static func fill(_ records: [ModelRecord], done: @escaping @MainActor () -> Void) {
        let missing = records.filter { record in
            let folder = record.metaFolder
            return !FileManager.default.fileExists(atPath: folder.appendingPathComponent("preview.png").path)
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("preview-failed").path)
        }
        guard !missing.isEmpty, let blender = blenderApplication()?.appendingPathComponent("Contents/MacOS/Blender"),
              let script = Bundle.main.url(forResource: "convert", withExtension: "py") else { return }
        lock.lock(); if running { lock.unlock(); return }; running = true; lock.unlock()
        Task.detached(priority: .background) {
            defer { lock.lock(); running = false; lock.unlock() }
            var made = 0
            for record in missing {
                let folder = record.metaFolder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vorschau-\(UUID().uuidString).png")
                let process = Process()
                process.executableURL = blender
                let isBlend = record.url.pathExtension.lowercased() == "blend"
                process.arguments = ["--background", "--factory-startup", "--disable-autoexec"] + (isBlend ? [record.url.path] : [])
                    + ["--python-exit-code", "1", "--python", script.path, "--", "--thumbnail-only", temp.path] + (isBlend ? [] : [record.url.path])
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                process.qualityOfService = .background
                do { try process.run() } catch { return }
                let deadline = Date().addingTimeInterval(180)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
                if process.isRunning { process.terminate() }
                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: temp.path) {
                    try? FileManager.default.moveItem(at: temp, to: folder.appendingPathComponent("preview.png"))
                    made += 1
                } else {
                    try? Data("Blender konnte keine Vorschau rendern".utf8).write(to: folder.appendingPathComponent("preview-failed"))
                }
            }
            if made > 0 { await MainActor.run { done() } }
        }
    }
}
