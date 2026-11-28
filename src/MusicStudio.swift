import Foundation
import AppKit
import AVFoundation
import CryptoKit

let musicDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/StudioPortal", isDirectory: true)

struct MusicSettings: Codable, Equatable {
    var caption = ""
    var lyrics = ""
    var duration = 60.0
    var steps = 8
    var variants = 3
    var format = "mp3"
    var lmSeed: Int64 = Int64.random(in: 0...Int64(Int32.max))
    var seed: Int64 = Int64.random(in: 0...Int64(Int32.max))
    var seedLocked = false
    var lmCfg = 1.7
    var ditCfg = 1.7
    var topK = 50

    static let instrumental = "[intro]\n[instrumental]\n[solo]\n[instrumental]\n[outro]"  // [instrumental] alone often gives wordless humming

    func request() throws -> [String: Any] {
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.message("Bitte beschreibe den Song.") }
        guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.message("Bitte gib einen Songtext ein – oder „Ohne Gesang“ wählen.") }
        guard (5...360).contains(duration), (2...100).contains(steps), (1...3).contains(variants) else { throw StudioError.message("Bitte prüfe Länge, Qualität und Varianten.") }
        // [instrumental] alone often still hums – the description has to say it too
        let isInstrumental = lyrics.trimmingCharacters(in: .whitespacesAndNewlines) == MusicSettings.instrumental.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = isInstrumental && !self.caption.localizedCaseInsensitiveContains("no vocals")
            ? self.caption.trimmingCharacters(in: .whitespacesAndNewlines) + " No vocals. Purely instrumental." : self.caption
        return ["operation": "music", "caption": caption, "lyrics": lyrics, "duration": duration, "steps": steps,
                "variants": variants, "output_format": format == "mp3" ? "mp3" : "wav16", "lm_seed": lmSeed, "seed": seed,
                "lm_cfg": lmCfg, "dit_cfg": ditCfg, "lm_top_k": topK]
    }
}

struct MusicExample: Identifiable, Hashable {
    var name: String, caption: String, lyrics: String, duration: Double
    var id: String { name }
    var group: String { name.hasPrefix("vocal") ? "Gesang" : name.hasPrefix("instrumental") ? "Instrumental" : "Weitere" }
    /// short readable name from the description (genre and mood) instead of the file name
    var title: String {
        let words = caption.replacingOccurrences(of: "Global:", with: "").replacingOccurrences(of: "Basic Attributes:", with: "")
            .split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? name
        let first = words.split(whereSeparator: { ",.;".contains($0) }).prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        return first.isEmpty ? name : String(first.prefix(48))
    }
}

struct Song: Identifiable, Equatable {
    var url: URL
    var date: Date
    var caption: String
    var lyrics: String
    var steps: Int
    var lmSeed: Int64?
    var length: Double?
    var origin: String?
    var id: String { url.path }
    var replayURL: URL { url.deletingPathExtension().appendingPathExtension("json") }
    var isPreview: Bool { steps < 30 }
    var isInstrumental: Bool { lyrics.trimmingCharacters(in: .whitespacesAndNewlines) == MusicSettings.instrumental.trimmingCharacters(in: .whitespacesAndNewlines) }
    var title: String {
        let lines = caption.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let basic = lines.first(where: { $0.hasPrefix("Basic Attributes:") }) {
            let text = basic.dropFirst("Basic Attributes:".count).trimmingCharacters(in: .whitespaces)
            let parts = text.components(separatedBy: ". ").filter { !$0.isEmpty }
            return parts.suffix(1).joined().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) + " · " + parts.prefix(1).joined()
        }
        var first = lines.first { !$0.isEmpty && $0 != "Global Metadata" } ?? "Song"
        for prefix in ["Global:", "Global Metadata:", "Style:", "Genre:"] where first.hasPrefix(prefix) {
            first = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        // "indie pop, bedroom pop, 104 BPM, A minor, …" → the first three parts are the recognisable ones
        let parts = first.split(whereSeparator: { ",.".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let short = parts.prefix(3).joined(separator: " · ")
        let text = short.isEmpty ? first : short
        return text.count > 60 ? String(text.prefix(60)) + "…" : text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension Song {
    /// measured song lengths – opening every audio file on each tab switch made the music tab stutter
    nonisolated(unsafe) private static var lengths: [String: Double] = [:]
    private static let lengthsLock = NSLock()
    static func length(_ url: URL, date: Date) -> Double? {
        let key = url.path + "#\(date.timeIntervalSince1970)"
        lengthsLock.lock(); let known = lengths[key]; lengthsLock.unlock()
        if let known { return known }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let value = Double(file.length) / file.processingFormat.sampleRate
        lengthsLock.lock(); lengths[key] = value; lengthsLock.unlock()
        return value
    }

    static func load(_ url: URL, measureLength: Bool = true) -> Song {
        let replay = (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let info = replay["studioportal"] as? [String: Any] ?? [:]
        let date = (info["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let length = measureLength ? Song.length(url, date: date) : nil
        return Song(url: url, date: date, caption: replay["caption"] as? String ?? "", lyrics: replay["lyrics"] as? String ?? "",
                    steps: (replay["steps"] as? NSNumber)?.intValue ?? 30, lmSeed: (replay["lm_seed"] as? NSNumber)?.int64Value,
                    length: length, origin: info["origin"] as? String)
    }
}

/// Marks MP3s as AI-generated (MiniMax Music 3 licence) with a small ID3v2.3 tag: title and comment.
func tagMP3(_ url: URL, title: String) {
    guard url.pathExtension.lowercased() == "mp3", let data = try? Data(contentsOf: url), data.count > 10,
          !data.starts(with: Array("ID3".utf8)) else { return }
    func frame(_ id: String, _ body: Data) -> Data {
        var out = Data(id.utf8)
        let size = UInt32(body.count)
        out.append(contentsOf: [UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff), 0, 0])
        out.append(body); return out
    }
    func text(_ value: String) -> Data { var d = Data([1, 0xff, 0xfe]); d.append(value.data(using: .utf16LittleEndian) ?? Data()); return d }
    var frames = frame("TIT2", text(String(title.prefix(120))))
    frames.append(frame("TPE1", text("StudioPortal · KI")))
    var comment = Data([1]); comment.append(Data("deu".utf8)); comment.append(contentsOf: [0xff, 0xfe, 0, 0])
    comment.append("KI-erzeugt mit MiniMax Music 3 (StudioPortal)".data(using: .utf16LittleEndian) ?? Data())
    frames.append(frame("COMM", comment))
    let size = frames.count
    var tag = Data("ID3".utf8); tag.append(contentsOf: [3, 0, 0])
    tag.append(contentsOf: [UInt8(size >> 21 & 0x7f), UInt8(size >> 14 & 0x7f), UInt8(size >> 7 & 0x7f), UInt8(size & 0x7f)])
    tag.append(frames); tag.append(data)
    try? tag.write(to: url, options: .atomic)
}

struct VariantProgress: Equatable { var phase = "Start"; var current: Int?; var total: Int? }

struct MusicProgress: Equatable {
    var status = "Verbinde mit bigki"
    var waiting: String?
    var variants: [Int: VariantProgress] = [:]
}

final class MusicBackend {
    func examples() throws -> [MusicExample] {
        var result: [MusicExample] = []
        try runWorker(["operation": "music_examples"], timeout: 30) { event in
            guard event["type"] as? String == "examples", let items = event["items"] as? [[String: Any]] else { return }
            result = items.compactMap { item in
                guard let name = item["name"] as? String, let caption = item["caption"] as? String, let lyrics = item["lyrics"] as? String else { return nil }
                return MusicExample(name: name, caption: caption, lyrics: lyrics, duration: (item["duration"] as? NSNumber)?.doubleValue ?? 60)
            }
        }
        return result
    }

    /// Runs one music job and stores audio + replay JSON (same base name) in ~/Music/StudioPortal.
    /// `names`: target base names per variant (full renders keep the name of their preview plus "-voll").
    func generate(_ request: [String: Any], names: [String]? = nil, control: RunControl, update: @escaping (MusicProgress) -> Void) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        let stage = musicDirectory.appendingPathComponent(".auftrag-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stage) }
        var progress = MusicProgress(); update(progress)
        var received: [URL] = [], remoteError: String?, finished = false
        var handle: FileHandle?, current: URL?, expected = 0, bytes = 0, hasher = SHA256()
        try runWorker(request, control: control) { event in
            switch event["type"] as? String {
            case "status":
                progress.status = event["message"] as? String ?? progress.status; progress.waiting = nil; update(progress)
            case "waiting":
                progress.waiting = event["message"] as? String; progress.variants = [:]; update(progress)
            case "progress":
                guard let variant = event["variant"] as? Int else { return }
                progress.waiting = nil
                progress.variants[variant] = VariantProgress(phase: event["phase"] as? String ?? "", current: event["current"] as? Int, total: event["total"] as? Int)
                update(progress)
            case "begin":
                guard handle == nil, let name = event["name"] as? String, let size = event["size"] as? Int,
                      match(name, #"^song-[1-3]\.(mp3|wav|json)$"#, 0) != nil, size > 0, size < 2 * 1024 * 1024 * 1024 else {
                    throw StudioError.message("bigki hat ungültige Daten gesendet.")
                }
                let url = stage.appendingPathComponent(name)
                guard fileManager.createFile(atPath: url.path, contents: nil) else { throw StudioError.message("Der Song konnte nicht gespeichert werden.") }
                handle = try FileHandle(forWritingTo: url); current = url; expected = size; bytes = 0; hasher = SHA256()
            case "data":
                guard let handle, let text = event["data"] as? String, let data = Data(base64Encoded: text) else { throw StudioError.message("bigki hat ungültige Daten gesendet.") }
                bytes += data.count
                guard bytes <= expected else { throw StudioError.message("Eine Datei ist größer als angekündigt.") }
                try handle.write(contentsOf: data); hasher.update(data: data)
            case "filedone":
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard let file = handle, let url = current, bytes == expected, digest == event["sha256"] as? String else {
                    throw StudioError.message("Eine übertragene Datei ist beschädigt.")
                }
                try file.close(); handle = nil; current = nil; received.append(url)
            case "end": finished = true
            case "error": remoteError = event["message"] as? String ?? "bigki meldet einen Fehler."
            default: break
            }
        }
        try? handle?.close()
        if let remoteError { throw StudioError.message(remoteError) }
        guard finished else { throw StudioError.message("Die Verbindung zu bigki wurde unterbrochen, bevor der Song übertragen war.") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "song-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased())"
        var installed: [URL] = []
        for audio in received where audio.pathExtension != "json" {
            let replay = audio.deletingPathExtension().appendingPathExtension("json")
            guard received.contains(replay) else { throw StudioError.message("Die Replay-Datei fehlt.") }
            let variant = audio.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "song-", with: "")
            var name = "\(base)-v\(variant)"
            if let names, let index = Int(variant), index >= 1, index <= names.count { name = names[index - 1] }
            var target = musicDirectory.appendingPathComponent("\(name).\(audio.pathExtension)")
            var counter = 2
            while fileManager.fileExists(atPath: target.path) {
                target = musicDirectory.appendingPathComponent("\(name)-\(counter).\(audio.pathExtension)"); counter += 1
            }
            if var json = (try? Data(contentsOf: replay)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
                json["studioportal"] = ["origin": requestOrigin, "date": ISO8601DateFormatter().string(from: Date()),
                                        "note": "KI-erzeugt mit MiniMax Music 3"]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: replay) }
                let title = Song(url: audio, date: Date(), caption: json["caption"] as? String ?? "", lyrics: "", steps: 30).title
                tagMP3(audio, title: title)
            }
            try fileManager.linkItem(at: replay, to: target.deletingPathExtension().appendingPathExtension("json"))
            try fileManager.linkItem(at: audio, to: target)
            installed.append(target)
        }
        return installed.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

@MainActor
final class MusicStudio: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var settings = MusicSettings() { didSet { save() } }
    @Published var songs: [Song] = []
    @Published var selected: Song?
    @Published var running = false
    @Published var started = Date()
    @Published var progress = MusicProgress()
    @Published var errorMessage: String?
    @Published var examples: [MusicExample] = []
    @Published var playing: URL?
    @Published var player: AVAudioPlayer?
    var onFinish: (() -> Void)?
    private var control: RunControl?
    private let backend = MusicBackend()

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "musicSettings"), let saved = try? JSONDecoder().decode(MusicSettings.self, from: data) { settings = saved }
        refresh()
    }

    private func save() { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "musicSettings") } }

    func refresh(select url: URL? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(at: musicDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        songs = files.filter { ["mp3", "wav"].contains($0.pathExtension.lowercased()) }.map { url in
            Song.load(url)
        }.sorted { $0.date == $1.date ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.date > $1.date }
        if let url { selected = songs.first { $0.url == url } } else if let s = selected { selected = songs.first { $0.url == s.url } }
    }

    func loadExamples() {
        guard examples.isEmpty else { return }
        Task.detached(priority: .utility) { [backend] in
            let items = (try? backend.examples()) ?? []
            await MainActor.run { self.examples = items }
        }
    }

    func apply(_ example: MusicExample) {
        settings.caption = example.caption; settings.lyrics = example.lyrics; settings.duration = min(360, max(5, example.duration))
    }

    func start() {
        if !settings.seedLocked { settings.lmSeed = Int64.random(in: 0...Int64(Int32.max)); settings.seed = Int64.random(in: 0...Int64(Int32.max)) }
        do { run(try settings.request()) } catch { errorMessage = error.localizedDescription }
    }

    /// Same song (melody and structure from its audio codes), re-synthesised with 30 steps.
    func renderFull(_ song: Song) { renderFull([song]) }

    /// Up to three previews re-rendered at the same time, one card each.
    func renderFull(_ list: [Song]) {
        var replays: [[String: Any]] = []
        for song in list.prefix(3) {
            guard let data = try? Data(contentsOf: song.replayURL), var replay = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Für „\(song.title)“ fehlt die Replay-Datei."; return
            }
            replay.removeValue(forKey: "steps"); replay.removeValue(forKey: "studioportal")
            replays.append(replay)
        }
        guard let first = list.first else { return }
        let names = list.prefix(3).map { $0.url.deletingPathExtension().lastPathComponent + "-voll" }
        run(["operation": "music", "replays": replays, "steps": 30,
             "output_format": first.url.pathExtension.lowercased() == "mp3" ? "mp3" : "wav16"], names: names)
    }

    /// The previews of the latest run (same base name), for "Alle voll rendern".
    var latestPreviews: [Song] {
        guard let newest = songs.first(where: \.isPreview) else { return [] }
        let base = newest.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: #"-v\d$"#, with: "", options: .regularExpression)
        return songs.filter { $0.isPreview && $0.url.lastPathComponent.hasPrefix(base + "-v") }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private func run(_ request: [String: Any], names: [String]? = nil) {
        guard !running else { return }
        let newControl = RunControl(); control = newControl; running = true; started = Date(); progress = MusicProgress()
        let service = backend
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let urls = try service.generate(request, names: names, control: newControl) { state in Task { @MainActor [weak self] in self?.progress = state } }
                await MainActor.run { [weak self] in
                    self?.running = false; self?.control = nil; self?.refresh(select: urls.first)
                    Notifier.finished("Musik fertig", urls.count == 1 ? "1 Song ist bereit." : "\(urls.count) Songs sind bereit.")
                    self?.onFinish?()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.running = false; self.control = nil; self.refresh()
                    if error.localizedDescription != "Abgebrochen." { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    func cancel() { progress.status = "Wird abgebrochen"; progress.waiting = nil; control?.cancel() }

    func useSettings(_ song: Song) {
        settings.caption = song.caption; settings.lyrics = song.lyrics
        if let seed = song.lmSeed { settings.lmSeed = seed; settings.seedLocked = true }
    }

    /// Same description and lyrics, new melody seed – starts right away.
    func vary(_ song: Song) {
        settings.caption = song.caption; settings.lyrics = song.lyrics
        settings.seedLocked = false
        start()
    }

    func stop() { player?.stop(); player = nil; playing = nil }

    func isPlaying(_ url: URL) -> Bool { playing == url && player?.isPlaying == true }

    func toggle(url: URL) {
        if let song = songs.first(where: { $0.url == url }) { toggle(song) } else { toggle(Song.load(url)) }
    }

    func toggle(_ song: Song) {
        if playing == song.url, let player {
            if player.isPlaying { player.pause() } else { player.play() }
            objectWillChange.send(); return
        }
        player?.stop()
        do {
            let next = try AVAudioPlayer(contentsOf: song.url)
            next.delegate = self; next.prepareToPlay(); next.play()
            player = next; playing = song.url; selected = song
        } catch { errorMessage = "Der Song konnte nicht abgespielt werden: \(error.localizedDescription)" }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.objectWillChange.send() }
    }

    func reveal(_ song: Song) { NSWorkspace.shared.activateFileViewerSelecting([song.url]) }

    func trash(_ song: Song) {
        if playing == song.url { player?.stop(); player = nil; playing = nil }
        do {
            try trashLibraryFiles([song.url, song.replayURL])
        } catch { errorMessage = "Der Song konnte nicht in den Papierkorb gelegt werden: \(error.localizedDescription)" }
        refresh()
    }
}
