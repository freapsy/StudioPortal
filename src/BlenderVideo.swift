import Foundation
import AppKit
import AVFoundation
import CryptoKit

// H3 Video (MiniMax H3 Turbo4, text → video with sound) and the Blender session on bigki.
// Both go through the same restricted worker and card queue as images, music and 3D.

let videosDirectory: URL = studioOnStori ? studioRoot.appendingPathComponent("Videos", isDirectory: true) : legacyVideosDirectory
let blenderLooksDirectory = supportDirectory.appendingPathComponent("Blender-Ansichten", isDirectory: true)

/// Receives the files a worker sends (begin / data / filedone) into a staging folder and collects the other events.
final class WorkerReceiver {
    let stage: URL
    private(set) var files: [URL] = []
    private(set) var result: [String: Any]?
    private(set) var end: [String: Any]?
    private(set) var error: String?
    private var handle: FileHandle?, current: URL?, expected = 0, bytes = 0, hasher = SHA256()
    private let allowed: String

    init(pattern allowed: String) throws {
        self.allowed = allowed
        stage = FileManager.default.temporaryDirectory.appendingPathComponent("studioportal-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    }

    deinit { try? handle?.close(); try? FileManager.default.removeItem(at: stage) }

    /// Returns true when the event was consumed (file transfer, result, end, error).
    func consume(_ event: [String: Any]) throws -> Bool {
        switch event["type"] as? String {
        case "begin":
            guard handle == nil, let name = event["name"] as? String, let size = event["size"] as? Int,
                  match(name, allowed, 0) != nil, size >= 0, size < 4 * 1024 * 1024 * 1024 else {
                throw StudioError.message("bigki hat ungültige Dateidaten gesendet.")
            }
            let url = stage.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw StudioError.message("Datei konnte nicht gespeichert werden.") }
            handle = try FileHandle(forWritingTo: url); current = url; expected = size; bytes = 0; hasher = SHA256()
        case "data":
            guard let handle, let text = event["data"] as? String, let data = Data(base64Encoded: text) else {
                throw StudioError.message("bigki hat ungültige Dateidaten gesendet.")
            }
            bytes += data.count
            guard bytes <= expected else { throw StudioError.message("Eine Datei ist größer als angekündigt.") }
            try handle.write(contentsOf: data); hasher.update(data: data)
        case "filedone":
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard let file = handle, let url = current, bytes == expected, digest == event["sha256"] as? String else {
                throw StudioError.message("Die übertragene Datei ist beschädigt (Prüfsumme).")
            }
            try file.close(); handle = nil; current = nil
            files.append(url)
        case "result": result = event["result"] as? [String: Any]
        case "end": end = event
        case "error": error = event["message"] as? String ?? "bigki meldet einen Fehler."
        default: return false
        }
        return true
    }

    /// Moves a received file to its place without overwriting (name-2, name-3 …).
    func install(_ file: URL, in folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base)-\(index).\(ext)"); index += 1
        }
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

/// Library information for videos and Blender renders (sidecar `<name>.json`).
struct MediaInfo: Codable {
    var kind: String            // "h3-video", "blender-render", "blender-animation"
    var title: String
    var date: Date
    var origin: String?
    var detail: String
    var seed: Int?
    var seconds: Int?
    var settings: [String: String]?
}

/// Camera, resolution, samples, device, cards and denoiser of a render (from the worker's end message) for labels and comparisons.
func renderFacts(_ end: [String: Any], camera: String? = nil) -> [String: String] {
    var facts: [String: String] = ["engine": end["engine"] as? String ?? ""]
    if let camera = camera ?? (end["camera"] as? String) { facts["camera"] = camera }
    if let res = end["resolution"] as? [Int], res.count == 2 { facts["resolution"] = "\(res[0])×\(res[1])" }
    if let samples = end["samples"] as? Int { facts["samples"] = "\(samples)" }
    if let reached = end["samples_reached"] as? Int { facts["samples_reached"] = "\(reached)" }
    if let device = end["device"] as? String, !device.isEmpty { facts["device"] = device }
    if let cards = end["cards"] as? [Int], !cards.isEmpty { facts["cards"] = cards.map(String.init).joined(separator: ",") }
    if let denoiser = end["denoiser"] as? String, !denoiser.isEmpty { facts["denoiser"] = denoiser }
    if let compiled = end["kernel_compiled"] as? Bool, compiled { facts["kernel_compiled"] = "true" }
    if let source = end["source"] as? String, !source.isEmpty { facts["source"] = source }
    return facts
}

/// Structured render telemetry returned directly in the blender_render JSON response.
func renderTelemetry(_ end: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for key in ["engine", "device", "cards", "card_count", "denoiser", "samples", "samples_reached",
                "adaptive_threshold", "resolution", "setup_s", "render_s", "wait_s", "kernel_compiled", "blender_time_s"] {
        if let value = end[key], !(value is NSNull) { out[key] = value }
    }
    return out
}

func filenameStamp() -> String {
    let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
}

/// First frame of a video as JPEG next to it (`<name>.jpg`) for the library.
func writeVideoPoster(_ video: URL) {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640, height: 640)
    let semaphore = DispatchSemaphore(value: 0)
    generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.5, preferredTimescale: 600)) { image, _, _ in
        if let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? data.write(to: video.deletingPathExtension().appendingPathExtension("jpg"))
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 20)
}

// MARK: - H3 Video

struct VideoSettings {
    var prompt = ""
    var width = 864
    var height = 480
    var frames = 124            // 24 fps → ~5 s
    var seed: Int64 = Int64.random(in: 1...2_147_483_646)
    var cards = 2               // 2: the two cool cards (one MI50 stays free); 3: experimental 3-card build
    var steps = 6               // default since 17.11.2026 (tested: clearly sharper than 4, 462 s vs 280 s for 5 s); 4 for drafts
    /// H3 Video works on a 17n+5 frame grid at 24 fps (124 = 5.2 s, 192 = 8 s); other counts are rounded inside
    static func gridFrames(_ frames: Int) -> Int { min(226, max(22, ((frames - 5) + 8) / 17 * 17 + 5)) }
    static func gridFrames(seconds: Double) -> Int { gridFrames(Int((seconds * 24).rounded())) }
    static let sizes: [(String, Int, Int)] = [("16:9", 864, 480), ("9:16", 480, 864), ("1:1", 640, 640), ("16:9 groß", 1280, 704)]
}

struct VideoProgress {
    var phase = "Verbinden"
    var step: Int?
    var steps: Int?
    var waiting: String?
    var cards: [Int] = []
    var text: String {
        if let waiting { return waiting }
        switch phase {
        case "Text": return "Beschreibung wird gelesen …"
        case "Rechnen": return "Video wird berechnet" + (step.map { s in steps.map { " · Schritt \(s)/\($0)" } ?? "" } ?? "")
        case "Video": return "Bilder und Ton werden zusammengesetzt …"
        case "Umwandeln": return "Wird in MP4 umgewandelt …"
        case "Übertragen": return "Video wird übertragen …"
        default: return phase == "Start" ? "Modell wird geladen …" : phase
        }
    }
}

enum VideoBackend {
    static func generate(_ s: VideoSettings, control: RunControl, update: @escaping (VideoProgress) -> Void) throws -> URL {
        let prompt = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw StudioError.message("Bitte beschreibe Bild und Ton des Videos.") }
        let start = Date()
        var state = VideoProgress(); update(state)
        var computeStart = start   // reset whenever bigki (re)assigns cards, so queue time is not counted
        let receiver = try WorkerReceiver(pattern: #"^video-[a-f0-9]+\.mp4$"#)
        let request: [String: Any] = ["operation": "video", "prompt": prompt, "width": s.width, "height": s.height,
                                      "frames": s.frames, "seed": s.seed, "cards": s.cards, "steps": s.steps]
        try runWorker(request, control: control) { event in
            if try receiver.consume(event) {
                if event["type"] as? String == "begin" { state.phase = "Übertragen"; state.waiting = nil; update(state) }
                return
            }
            switch event["type"] as? String {
            case "waiting": state.waiting = event["message"] as? String; update(state)
            case "status":
                state.waiting = nil
                if let cards = event["cards"] as? [Int] { state.cards = cards; state.phase = "Start"; computeStart = Date() }
                update(state)
            case "progress":
                state.waiting = nil; state.phase = event["phase"] as? String ?? state.phase
                state.step = event["step"] as? Int; state.steps = event["steps"] as? Int; update(state)
            default: break
            }
        }
        if let error = receiver.error { throw StudioError.message(error) }
        guard receiver.end != nil, let file = receiver.files.first else {
            throw StudioError.message("Die Verbindung zu bigki wurde unterbrochen, bevor das Video übertragen war.")
        }
        let name = "video-\(filenameStamp())-\(String(UUID().uuidString.prefix(6)).lowercased()).mp4"
        let target = try receiver.install(file, in: videosDirectory, name: name)
        let seconds = Int(Date().timeIntervalSince(computeStart))
        let waited = Int(computeStart.timeIntervalSince(start))
        var settings = ["frames": "\(s.frames)", "cards": "\(s.cards)", "steps": "\(s.steps)", "size": "\(s.width)x\(s.height)", "model": "MiniMax H3 Turbo4 (Q6_K)"]
        if waited >= 30 { settings["wartezeit_s"] = "\(waited)" }
        let info = MediaInfo(kind: "h3-video", title: prompt, date: start, origin: requestOrigin,
                             detail: "\(s.width)×\(s.height) · \(String(format: "%.1f", Double(s.frames) / 24)) s",
                             seed: Int(s.seed), seconds: seconds, settings: settings)
        try jsonEncoder().encode(info).write(to: target.deletingPathExtension().appendingPathExtension("json"))
        writeVideoPoster(target)
        return target
    }
}

// MARK: - Blender session on bigki

enum BlenderRemote {
    /// One action in the Blender session (python, scene, api, info, new, look, open, save, render, quit, reset, sessions).
    /// Returns the session's answer plus the files it produced (already moved to their place).
    static func call(_ action: String, _ params: [String: Any], control: RunControl? = nil,
                     progress: @escaping (String) -> Void = { _ in }) throws -> [String: Any] {
        var request = params
        request["operation"] = "blender"
        request["action"] = action
        if action == "look", let reference = params["reference"] as? String {
            request.removeValue(forKey: "reference")
            if reference.hasPrefix("bigki:") { request["reference_path"] = String(reference.dropFirst(6)) }
            else {
                let url = URL(fileURLWithPath: (reference as NSString).expandingTildeInPath)
                let data = try Data(contentsOf: url)
                guard data.count <= 20 * 1024 * 1024 else { throw StudioError.message("Das Vorlagebild ist größer als 20 MB.") }
                request["reference_data"] = data.base64EncodedString()
                request["reference_name"] = url.lastPathComponent
            }
        }
        if action == "open" && params["path"] == nil {
            guard let path = params["file"] as? String else { throw StudioError.message("file fehlt (Pfad einer .blend/.glb/.fbx/.obj … auf diesem Mac) oder path (Datei auf bigki).") }
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard data.count <= 100 * 1024 * 1024 else { throw StudioError.message("Die Datei ist größer als 100 MB.") }
            request["data"] = data.base64EncodedString()
            request["filename"] = url.lastPathComponent
            request.removeValue(forKey: "file")
        }
        let start = Date()
        // Renders carry a pickup ticket: if the connection drops (Tailscale hang), bigki keeps rendering and parks the
        // result; StudioPortal then collects it with action "abholen" instead of failing.
        // Since 17.11.2026 every session call carries one too (python, look, check …): bigki parks the answer, so a long
        // step whose connection drops is not lost – the app collects it the same way (agent feedback "Auftrag weg").
        let ticketed = ["render", "python", "scene", "api", "info", "new", "check", "snapshot", "snapshots", "restore", "tools", "look"]
        let manualPickup = action == "abholen"   // blender_session action=abholen ticket=… (e.g. after the Mac restarted)
        let ticket: String? = manualPickup ? (params["ticket"] as? String) : ticketed.contains(action) || (action == "open" && request["data"] == nil && request["file"] == nil)
            ? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased() : nil
        if let ticket { request["ticket"] = ticket }
        var receiver = try WorkerReceiver(pattern: #"^[A-Za-z0-9._-]+\.(png|blend|mp4)$"#)
        var last = ""
        func run(_ request: [String: Any], into receiver: WorkerReceiver) throws {
            try runWorker(request, control: control, patient: ticket != nil) { event in
                if try receiver.consume(event) { return }
                var text: String?
                switch event["type"] as? String {
                case "status", "waiting": text = event["message"] as? String
                case "progress":
                    let phase = event["phase"] as? String ?? ""
                    if let step = event["step"] as? Int, let steps = event["steps"] as? Int { text = "\(phase) \(step)/\(steps)" } else { text = phase }
                default: break
                }
                if let text, text != last { last = text; progress(text) }
            }
        }
        if manualPickup && ticket == nil { throw StudioError.message("ticket fehlt.") }
        if !manualPickup {
            do { try run(request, into: receiver) } catch {
                if ticket == nil || control?.isCancelled() == true || receiver.error != nil { throw error }
            }
        }
        func done() -> Bool { receiver.end != nil || receiver.result != nil || receiver.error != nil }
        if let ticket, !done(), control?.isCancelled() != true {
            let pickup: [String: Any] = ["operation": "blender", "action": "abholen", "ticket": ticket, "session": request["session"] ?? defaultBlenderSession]
            var attempt = 0
            let what = action == "render" ? "der Render" : "der Aufruf"
            while !done() {
                attempt += 1
                if control?.isCancelled() == true { throw StudioError.message("Abgebrochen.") }
                progress("Verbindung zu bigki unterbrochen – \(what) läuft dort weiter, StudioPortal holt das Ergebnis ab (Versuch \(attempt)) …")
                receiver = try WorkerReceiver(pattern: #"^[A-Za-z0-9._-]+\.(png|blend|mp4)$"#)
                do { try run(pickup, into: receiver) } catch {
                    if control?.isCancelled() == true || receiver.error != nil { throw error }
                }
                if !done() {
                    guard attempt < 40 else {
                        throw StudioError.message("bigki ist seit über 10 Minuten nicht erreichbar. Das Ergebnis liegt dort noch 12 h zum Abholen bereit: blender_session action=abholen ticket=\(ticket).")
                    }
                    Thread.sleep(forTimeInterval: 15)
                }
            }
        }
        if let error = receiver.error { throw StudioError.message(error) }
        if let ticket, receiver.end != nil || receiver.result != nil {
            // received completely: let bigki delete the parked copy (in the background, failures do not matter)
            let confirm: [String: Any] = ["operation": "blender", "action": "abgeholt", "ticket": ticket, "session": request["session"] ?? defaultBlenderSession]
            DispatchQueue.global(qos: .utility).async { try? runWorker(confirm) { _ in } }
        }
        var answer = receiver.result ?? [:]
        // what to do with the received files; a manual pickup does not know the original action
        let kind = manualPickup ? (receiver.end != nil ? "render" : receiver.files.isEmpty ? "python" : "look") : action
        if kind == "render", let end = receiver.end, let cameras = end["cameras"] as? [String] {
            // several cameras → one PNG each: <name>-<camera>.png, optionally in a subfolder of the pictures folder
            try requireStori()
            var folder = picturesDirectory
            if let sub = params["folder"] as? String, !sub.isEmpty {
                folder = picturesDirectory.appendingPathComponent(sub.replacingOccurrences(of: "..", with: "_"), isDirectory: true)
            }
            let base = (params["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "blender-\(filenameStamp())"
            var files: [String: String] = [:]
            for (index, file) in receiver.files.enumerated() where index < cameras.count {
                let safe = cameras[index].replacingOccurrences(of: "/", with: "_")
                let target = try receiver.install(file, in: folder, name: "\(base)-\(safe).png")
                let info = MediaInfo(kind: "blender-render", title: (params["title"] as? String) ?? "\(base) · \(cameras[index])", date: start,
                                     origin: requestOrigin, detail: "Cycles · Kamera \(cameras[index])", seed: nil,
                                     seconds: Int(Date().timeIntervalSince(start)), settings: renderFacts(end, camera: cameras[index]))
                try jsonEncoder().encode(info).write(to: target.deletingPathExtension().appendingPathExtension("json"))
                files[cameras[index]] = target.path
            }
            var answer: [String: Any] = ["ok": true, "files": files, "count": files.count, "folder": folder.path,
                                         "render_seconds": end["seconds"] ?? 0, "seconds": Int(Date().timeIntervalSince(start))]
            for (k, v) in renderTelemetry(end) { answer[k] = v }
            // one labelled strip of all cameras next to the single PNGs (also returned to agents as one image)
            let tiles = cameras.compactMap { camera in files[camera].map { (camera, URL(fileURLWithPath: $0)) } }
            if tiles.count > 1, let sheet = try? contactSheet(tiles, to: folder.appendingPathComponent("\(base)-leiste.jpg")) {
                answer["sheet"] = sheet.path
                answer["preview"] = sheet.path
            }
            return answer
        }
        if kind == "render" {
            guard let end = receiver.end, let file = receiver.files.first else {
                throw StudioError.message("Die Verbindung zu bigki wurde unterbrochen, bevor das Rendering übertragen war.")
            }
            let count = end["count"] as? Int ?? 1
            let scene = (params["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Blender-Szene"
            let stamp = filenameStamp()
            let detail = count == 1 ? "Cycles · Bild \((end["frames"] as? [Int])?.first ?? 1)" : "\(count) Bilder"
            let info = MediaInfo(kind: count == 1 ? "blender-render" : "blender-animation", title: scene, date: start,
                                 origin: requestOrigin, detail: detail, seed: nil, seconds: Int(Date().timeIntervalSince(start)),
                                 settings: renderFacts(end).merging(["frames": "\(end["frames"] ?? "")"]) { a, _ in a })
            let target: URL
            let base = (params["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var folder = picturesDirectory
            if let sub = params["folder"] as? String, !sub.isEmpty {
                folder = picturesDirectory.appendingPathComponent(sub.replacingOccurrences(of: "..", with: "_"), isDirectory: true)
            }
            if count == 1 {
                try requireStori()
                target = try receiver.install(file, in: folder, name: "\(base ?? "blender-\(stamp)").png")
            } else {
                target = try receiver.install(file, in: videosDirectory, name: "\(base ?? "blender-\(stamp)").mp4")
                writeVideoPoster(target)
            }
            try jsonEncoder().encode(info).write(to: target.deletingPathExtension().appendingPathExtension("json"))
            var frames: [String] = []
            for extra in receiver.files.dropFirst() {
                let folder = videosDirectory.appendingPathComponent("blender-\(stamp)-bilder", isDirectory: true)
                frames.append(try receiver.install(extra, in: folder, name: extra.lastPathComponent).path)
            }
            answer = ["ok": true, "file": target.path, "frames": end["frames"] ?? [], "count": count,
                      "render_seconds": end["seconds"] ?? 0, "seconds": Int(Date().timeIntervalSince(start))]
            for (k, v) in renderTelemetry(end) { answer[k] = v }
            if !frames.isEmpty { answer["frame_files"] = frames }
        } else if kind == "look", let file = receiver.files.first {
            answer.removeValue(forKey: "path")
            let local = try receiver.install(file, in: blenderLooksDirectory, name: "ansicht-\(filenameStamp()).png")
            answer["image"] = local.path
            pruneLooks()
            // a copy with a speaking name in the shared pictures folder (Stori on the Mac mini): Bilder/Blender-Ansichten/<day>/
            if (try? requireStori()) != nil {
                let stamp = filenameStamp()   // yyyyMMdd-HHmmss
                let day = "\(stamp.prefix(4))-\(stamp.dropFirst(4).prefix(2))-\(stamp.dropFirst(6).prefix(2))"
                let folder = picturesDirectory.appendingPathComponent("Blender-Ansichten", isDirectory: true).appendingPathComponent(day, isDirectory: true)
                let name = lookName(params)
                if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil {
                    var target = folder.appendingPathComponent(name + ".png"), index = 2
                    while FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(name)-\(index).png"); index += 1 }
                    if (try? FileManager.default.copyItem(at: local, to: target)) != nil { answer["saved"] = target.path }
                }
            }
        } else if action == "save", params["bigki_path"] != nil {
            answer["hint"] = "Liegt nur auf bigki (nicht auf diesem Mac, nicht in der Bibliothek)."
        } else if action == "save", let file = receiver.files.first {
            let name = (params["filename"] as? String).map { ($0 as NSString).lastPathComponent } ?? "blender-\(filenameStamp()).blend"
            let target = try receiver.install(file, in: modelsDirectory, name: name.hasSuffix(".blend") ? name : name + ".blend")
            let meta = ModelRecord.metaFolder(for: target)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
            let info: [String: Any] = ["kind": "model", "source": "blender", "file": target.lastPathComponent,
                                       "date": ISO8601DateFormatter().string(from: Date()), "origin": requestOrigin,
                                       "blender": answer["engine"] as? String ?? ""]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]).write(to: meta.appendingPathComponent("info.json"))
            if let preview = params["preview"] as? String, FileManager.default.fileExists(atPath: preview) {
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: preview), to: meta.appendingPathComponent("preview.png"))
            }
            answer.removeValue(forKey: "path")
            answer["file"] = target.path
            answer["note"] = "Mit Blender 5.3 gespeichert – ältere Blender-Versionen (z. B. 4.5) öffnen sie eventuell nicht vollständig."
        }
        return answer
    }

    /// "<name>" if given, else time-session-mode-what (focus / views / camera / zoom), file-name safe.
    static func lookName(_ params: [String: Any]) -> String {
        var parts: [String] = []
        if let name = params["name"] as? String, !name.isEmpty { parts = [name] } else {
            parts.append(String(filenameStamp().suffix(6)))
            parts.append(params["session"] as? String ?? defaultBlenderSession)
            parts.append(params["mode"] as? String ?? "solid")
            if let focus = params["focus"] as? String { parts.append(focus) }
            else if let views = params["views"] as? String { parts.append(views) }
            else if let views = params["views"] as? [Any] { parts.append(views.compactMap { $0 as? String }.joined(separator: "+").isEmpty ? "ansichten" : views.compactMap { $0 as? String }.joined(separator: "+")) }
            else if let camera = params["camera"] as? String { parts.append(camera) }
            if let color = params["color_by"] as? String { parts.append(color) }
            if params["zoom"] != nil || params["region"] != nil { parts.append("zoom") }
        }
        let raw = parts.joined(separator: "-")
        let safe = raw.folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "[^A-Za-z0-9._+-]+", with: "_", options: .regularExpression)
        return String(safe.prefix(90))
    }

    /// Tiles images side by side (up to 4 per row) with the label under each, as JPEG. No PIL/sips needed.
    static func contactSheet(_ tiles: [(String, URL)], to target: URL, maxWidth: CGFloat = 1800) throws -> URL {
        let images = tiles.compactMap { label, url in NSImage(contentsOf: url).map { (label, $0) } }
        guard !images.isEmpty else { throw StudioError.message("Keine Bilder für die Bildleiste.") }
        let columns = min(images.count, images.count == 4 ? 2 : 4)
        let rows = Int((Double(images.count) / Double(columns)).rounded(.up))
        let gap: CGFloat = 8, labelHeight: CGFloat = 30
        let tileWidth = min(640, (maxWidth - gap * CGFloat(columns + 1)) / CGFloat(columns))
        let aspect = images.map { $0.1.size.height / max($0.1.size.width, 1) }.max() ?? 1
        let tileHeight = (tileWidth * aspect).rounded()
        let width = Int(gap + CGFloat(columns) * (tileWidth + gap)), height = Int(gap + CGFloat(rows) * (tileHeight + labelHeight + gap))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw StudioError.message("Bildleiste konnte nicht angelegt werden.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor(white: 0.92, alpha: 1)]
        for (index, (label, image)) in images.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + CGFloat(column) * (tileWidth + gap)
            let top = CGFloat(height) - gap - CGFloat(row) * (tileHeight + labelHeight + gap)
            let scale = min(tileWidth / max(image.size.width, 1), tileHeight / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: x + (tileWidth - size.width) / 2, y: top - tileHeight + (tileHeight - size.height) / 2, width: size.width, height: size.height))
            let text = NSAttributedString(string: label, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: x + max(0, (tileWidth - textSize.width) / 2), y: top - tileHeight - labelHeight + (labelHeight - textSize.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw StudioError.message("Bildleiste konnte nicht gespeichert werden.")
        }
        var url = target
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = target.deletingLastPathComponent().appendingPathComponent("\(target.deletingPathExtension().lastPathComponent)-\(index).jpg"); index += 1
        }
        try data.write(to: url)
        return url
    }

    private static func pruneLooks() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: blenderLooksDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in files.dropFirst(60) { try? FileManager.default.removeItem(at: file) }
    }
}

// MARK: - Agent operations (CLI and MCP)

let defaultBlenderSession: String = {
    let slug = machineName.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String((slug.isEmpty ? "standard" : slug).prefix(24))
}()

extension AgentOps {
    static let videoAspects: [String: (Int, Int)] = ["16:9": (864, 480), "9:16": (480, 864), "1:1": (640, 640), "16:9-hd": (1280, 704)]

    static func video(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        var s = VideoSettings()
        if let like = p["like"] as? String {
            // = "Übernehmen" in the app: description, length, format, steps, cards and seed of an earlier video
            let url = URL(fileURLWithPath: expand(like))
            guard let data = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")),
                  let info = try? jsonDecoder().decode(MediaInfo.self, from: data), info.kind == "h3-video" else {
                throw StudioError.message("like: kein H3-Video mit Begleitdatei: \(url.path)")
            }
            s.prompt = info.title
            if let seed = info.seed { s.seed = Int64(seed) }
            if let frames = info.settings?["frames"].flatMap(Int.init) { s.frames = frames }
            if let steps = info.settings?["steps"].flatMap(Int.init) { s.steps = steps }
            if let cards = info.settings?["cards"].flatMap(Int.init) { s.cards = cards }
            let size = (info.settings?["size"] ?? info.detail.components(separatedBy: " · ").first ?? "")
                .replacingOccurrences(of: "×", with: "x").split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if size.count == 2 { s.width = size[0]; s.height = size[1] }
            if (p["new_seed"] as? Bool) == true { s.seed = Int64.random(in: 1...2_147_483_646) }
        }
        if let prompt = p["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s.prompt = prompt }
        guard !s.prompt.isEmpty else { throw StudioError.message("prompt fehlt (oder like=<video> angeben).") }
        if let aspect = p["aspect"] as? String {
            guard let size = videoAspects[aspect] else { throw StudioError.message("aspect muss 16:9, 9:16, 1:1 oder 16:9-hd sein.") }
            (s.width, s.height) = size
        }
        if let width = int(p, "width") { s.width = width }
        if let height = int(p, "height") { s.height = height }
        if let name = p["preset"] as? String {
            guard let preset = VideoPreset.all.first(where: { $0.choice.id == name }) else {
                throw StudioError.message("preset: " + VideoPreset.all.map(\.choice.id).joined(separator: ", "))
            }
            preset.apply(to: &s)
        }
        if let seconds = double(p, "seconds") { s.frames = VideoSettings.gridFrames(seconds: seconds) }
        if let frames = int(p, "frames") { s.frames = frames }
        s.frames = VideoSettings.gridFrames(s.frames)
        if let steps = int(p, "steps") { s.steps = [4, 5, 6, 8].contains(steps) ? steps : 6 }
        if let seed = int(p, "seed") { s.seed = Int64(seed) }
        if let cards = int(p, "cards") { s.cards = cards == 3 ? 3 : 2 }
        let start = Date()
        var last = ""
        let file = try VideoBackend.generate(s, control: control) { state in
            if state.text != last { last = state.text; progress(state.text) }
        }
        let poster = file.deletingPathExtension().appendingPathExtension("jpg")
        let info = (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("json")))
            .flatMap { try? jsonDecoder().decode(MediaInfo.self, from: $0) }
        return ["file": file.path, "preview": FileManager.default.fileExists(atPath: poster.path) ? poster.path : NSNull(),
                "seed": s.seed, "width": s.width, "height": s.height, "frames": s.frames, "steps": s.steps,
                "length_seconds": Double(s.frames) / 24, "seconds": Int(Date().timeIntervalSince(start)),
                "compute_seconds": info?.seconds ?? NSNull()]
    }

    /// Keys passed through to the Blender session per action (everything else is ignored).
    private static let blenderKeys: [String: [String]] = [
        "python": ["code", "script_path", "timeout", "persist"], "scene": ["object"], "api": ["identifier"], "info": [], "new": ["empty"],
        "look": ["mode", "size", "camera", "frame", "overview", "samples", "views", "azimuth", "elevation", "distance", "target",
                 "focus", "lens", "color_by", "only", "columns", "reference", "region", "zoom", "center", "name"],
        "open": ["file", "path", "append"], "save": ["filename", "bigki_path", "overwrite"],
        "render": ["frames", "samples", "noise", "percentage", "cards", "send_frames", "title", "camera", "cameras", "name", "folder"],
        "check": ["objects", "pairs", "contact", "tolerance", "floor", "floor_z", "holes", "layers", "layer_gap", "rays",
                  "small_part", "sliver", "stretch", "layer_samples", "max_objects", "timeout", "thickness", "thickness_samples",
                  "min_thickness", "remove_small"],
        "snapshot": ["name", "note", "keep"], "snapshots": [], "restore": ["name"], "tools": ["mode", "code", "name"],
        "sessions": [], "quit": [], "reset": [], "status": [], "abholen": ["ticket"],
    ]

    static func syncFiles(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        let bare = p["_positional"] as? [String] ?? []
        let source = (p["source"] as? String) ?? (p["local"] as? String) ?? (p["path"] as? String) ?? bare.first ?? ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.message("source fehlt (Ordner oder Datei auf diesem Mac).")
        }
        let dest = (p["dest"] as? String) ?? (p["target"] as? String) ?? (bare.count >= 2 ? bare[1] : nil)
        let extraExcludes: [String]
        if let list = p["exclude"] as? [String] { extraExcludes = list }
        else if let text = p["exclude"] as? String { extraExcludes = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        else { extraExcludes = [] }
        let deleteFlag: Bool
        if let b = p["delete"] as? Bool { deleteFlag = b }
        else if let s = p["delete"] as? String { deleteFlag = ["1", "true", "yes", "ja"].contains(s.lowercased()) }
        else { deleteFlag = false }
        let maxMB = int(p, "max_file_mb") ?? 50
        return try BigkiSync.sync(localPath: expand(source), dest: dest, extraExcludes: extraExcludes,
                                  deleteExtraneous: deleteFlag, maxFileMB: max(1, min(maxMB, 100)),
                                  control: control, progress: progress)
    }

    static func blender(_ action: String, _ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        guard let keys = blenderKeys[action] else {
            throw StudioError.message("Unbekannte Blender-Aktion \(action). Möglich: " + blenderKeys.keys.sorted().joined(separator: ", "))
        }
        var params: [String: Any] = [:]
        for key in keys { if let value = p[key] { params[key] = value } }
        if action == "look", params["reference"] == nil, let first = (p["references"] as? [String])?.first { params["reference"] = first }
        // Each Mac has its own default session so agents on the MacBook and the Mac mini do not edit the same scene.
        if let session = p["session"] as? String, !session.isEmpty { params["session"] = session.lowercased() }
        else if !["sessions"].contains(action) { params["session"] = defaultBlenderSession }
        for key in ["timeout", "size", "frame", "samples", "percentage", "cards"] {
            if let text = params[key] as? String { guard let n = Int(text) else { throw StudioError.message("\(key) muss eine Zahl sein.") }; params[key] = n }
        }
        for key in ["append", "overview", "send_frames", "empty", "persist", "holes", "layers", "floor", "thickness"] {
            if let text = params[key] as? String { params[key] = ["1", "true", "yes", "ja"].contains(text.lowercased()) }
        }
        for key in ["azimuth", "elevation", "distance", "lens", "tolerance", "floor_z", "layer_gap", "small_part", "sliver", "stretch",
                    "zoom", "min_thickness"] {
            if let text = params[key] as? String { guard let n = Double(text) else { throw StudioError.message("\(key) muss eine Zahl sein.") }; params[key] = n }
        }
        if let text = params["remove_small"] as? String {
            params["remove_small"] = Int(text).map { $0 as Any } ?? (["1", "true", "yes", "ja"].contains(text.lowercased()) as Any)
        }
        for key in ["region", "center"] {   // CLI: "0.4,0.1,0.7,0.4"
            if let text = params[key] as? String { params[key] = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        }
        for key in ["columns", "rays", "layer_samples", "max_objects", "keep", "thickness_samples"] {
            if let text = params[key] as? String, let n = Int(text) { params[key] = n }
        }
        // CLI: comma lists ("vorne,rechts", "Figur,Handy"), pairs as "A,B;C,D", target as "x,y,z" or an object name
        for key in ["only", "objects", "cameras"] {
            if let text = params[key] as? String { params[key] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        if let text = params["contact"] as? String { params["contact"] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let text = params["pairs"] as? String {
            params["pairs"] = text.split(separator: ";").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        if let text = params["target"] as? String {
            let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if numbers.count == 3 { params["target"] = numbers }
        }
        if let text = params["noise"] as? String { params["noise"] = text == "off" ? "off" : Double(text) ?? 0.01 }
        if let text = params["frames"] as? String {
            if text == "all" { params["frames"] = "all" }
            else if let one = Int(text) { params["frames"] = one }
            else {
                let parts = text.split(whereSeparator: { $0 == "-" || $0 == ":" || $0 == "," }).compactMap { Int($0) }
                guard parts.count == 2 else { throw StudioError.message("frames: Zahl, \"1-48\" oder \"all\".") }
                params["frames"] = parts
            }
        }
        if action == "open", let file = params["file"] as? String {
            // a path that only exists on bigki (e.g. /home/bigki/… or bigki:~/…) is opened there without upload
            if file.hasPrefix("bigki:") { params["path"] = String(file.dropFirst(6)); params.removeValue(forKey: "file") }
            else if !FileManager.default.fileExists(atPath: expand(file)) && (file.hasPrefix("/home/") || file.hasPrefix("~/")) {
                params["path"] = file; params.removeValue(forKey: "file")
            } else { params["file"] = expand(file) }
        }
        var syncReport: [String: Any]?
        // script = a file instead of pasted code: on this Mac (read here) or on bigki (bigki:~/…, /home/bigki/…; read there)
        if action == "tools" || action == "python", let file = (p["script"] as? String) ?? (p["file"] as? String), !file.isEmpty,
           (params["code"] as? String)?.isEmpty != false {
            if file.hasPrefix("bigki:") { params["script_path"] = String(file.dropFirst(6)) }
            else if !FileManager.default.fileExists(atPath: expand(file)) && (file.hasPrefix("/home/") || file.hasPrefix("~/")) {
                params["script_path"] = file
            } else {
                let expandedFile = expand(file)
                guard FileManager.default.fileExists(atPath: expandedFile) else { throw StudioError.message("Skript \(file) gibt es auf diesem Mac nicht (für Dateien auf bigki: bigki:~/…).") }
                let wantsSync: Bool = (p["with_dir"] as? Bool) == true || (p["mit_ordner"] as? Bool) == true
                    || (p["sync_dir"] as? String)?.isEmpty == false
                    || ["1", "true", "yes", "ja"].contains(((p["with_dir"] as? String) ?? (p["mit_ordner"] as? String) ?? "").lowercased())
                if action == "python" && wantsSync {
                    let scriptURL = URL(fileURLWithPath: expandedFile).resolvingSymlinksInPath().standardizedFileURL
                    let syncRoot: URL
                    if let customDir = p["sync_dir"] as? String, !customDir.isEmpty {
                        syncRoot = URL(fileURLWithPath: expand(customDir)).resolvingSymlinksInPath().standardizedFileURL
                    } else {
                        syncRoot = BigkiSync.detectSyncRoot(forScript: scriptURL)
                    }
                    let rootPrefix = syncRoot.path.hasSuffix("/") ? syncRoot.path : syncRoot.path + "/"
                    guard scriptURL.path.hasPrefix(rootPrefix) else {
                        throw StudioError.message("Skript \(scriptURL.path) liegt nicht innerhalb von sync_dir (\(syncRoot.path)).")
                    }
                    let relScript = String(scriptURL.path.dropFirst(rootPrefix.count))
                    let synced = try BigkiSync.sync(localPath: syncRoot.path, dest: p["dest"] as? String,
                                                    control: control, progress: progress)
                    guard let remoteDest = synced["dest"] as? String else {
                        throw StudioError.message("Sync-Ziel konnte nicht bestimmt werden.")
                    }
                    syncReport = synced
                    params["script_path"] = (remoteDest.hasSuffix("/") ? remoteDest : remoteDest + "/") + relScript
                } else {
                    params["code"] = try String(contentsOfFile: expandedFile, encoding: .utf8)
                    if action == "python" { params["script_path"] = expandedFile }
                }
            }
            if action == "tools" {   // a whole script file: stored as werkzeuge/<name>.py, loaded again at every start
                params["mode"] = "file"
                if params["name"] == nil { params["name"] = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent }
            }
        }
        if action == "python", (params["code"] as? String)?.isEmpty != false, params["script_path"] == nil {
            throw StudioError.message("code oder script fehlt (Python für die Blender-Sitzung).")
        }
        if action == "api", params["identifier"] == nil { throw StudioError.message("identifier fehlt, z. B. bpy.ops.mesh.primitive_cube_add oder bpy.types.Object.location.") }
        var result = try BlenderRemote.call(action, params, control: control, progress: progress)
        if let syncReport { result["sync"] = syncReport }
        if action == "render", let file = result["file"] as? String {
            let poster = URL(fileURLWithPath: file).deletingPathExtension().appendingPathExtension("jpg").path
            result["preview"] = file.hasSuffix(".png") ? file as Any : (FileManager.default.fileExists(atPath: poster) ? poster as Any : NSNull())
        }
        return result
    }
}

/// Incremental SHA-256 file/directory sync from Mac to bigki via the restricted worker (scripts, fonts, assets).
enum BigkiSync {
    static let defaultExcludeDirs: Set<String> = [
        ".git", "out", "vergleiche", "__pycache__", "node_modules", ".venv", "venv", ".mypy_cache", ".pytest_cache"
    ]
    static let defaultExcludeFiles: Set<String> = [".DS_Store", "Thumbs.db"]
    static let defaultExcludeExtensions: Set<String> = ["pyc", "pyo", "blend1", "blend2"]

    static func detectSyncRoot(forScript scriptURL: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let fm = FileManager.default
        let resolvedScript = scriptURL.resolvingSymlinksInPath().standardizedFileURL
        var current = resolvedScript.deletingLastPathComponent()
        for _ in 0..<4 {
            if current.path == "/" || current.path == home { break }
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            current = current.deletingLastPathComponent()
        }
        return resolvedScript.deletingLastPathComponent()
    }

    private static func workerCall(_ request: [String: Any], control: RunControl?) throws -> [String: Any] {
        var result: [String: Any]?
        var failure: String?
        try runWorker(request, control: control) { event in
            switch event["type"] as? String {
            case "result": result = event["result"] as? [String: Any]
            case "error": failure = event["message"] as? String ?? "Sync auf bigki fehlgeschlagen."
            default: break
            }
        }
        if let failure { throw StudioError.message(failure) }
        guard let result else { throw StudioError.message("Keine Antwort von bigki beim Sync.") }
        return result
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sync(localPath: String, dest: String?, extraExcludes: [String] = [], deleteExtraneous: Bool = false,
                     maxFileMB: Int = 50, control: RunControl? = nil,
                     progress: @escaping (String) -> Void = { _ in }) throws -> [String: Any] {
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: localPath).resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw StudioError.message("Quelle existiert nicht: \(sourceURL.path)")
        }
        let started = Date()
        let cleanedDest = (dest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDest: String
        if !cleanedDest.isEmpty {
            targetDest = cleanedDest
        } else if isDir.boolValue {
            targetDest = "~/blender-auftraege/\(sourceURL.lastPathComponent)"
        } else {
            targetDest = "~/blender-auftraege/\(sourceURL.deletingLastPathComponent().lastPathComponent)"
        }
        progress("Prüfe Zielstand auf bigki (\(targetDest)) …")
        let manifest = try workerCall(["operation": "sync", "action": "manifest", "dest": targetDest], control: control)
        let resolvedDest = (manifest["dest"] as? String) ?? targetDest
        let remoteFiles = manifest["files"] as? [String: [String: Any]] ?? [:]

        let excludeSet = defaultExcludeDirs.union(defaultExcludeFiles).union(extraExcludes.filter { !$0.isEmpty })
        let maxBytes = maxFileMB * 1024 * 1024
        var localEntries: [(rel: String, url: URL)] = []
        var skipped: [[String: Any]] = []

        if !isDir.boolValue {
            localEntries.append((sourceURL.lastPathComponent, sourceURL))
        } else {
            func walk(_ dir: URL, prefix: String) throws {
                let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
                for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let vals = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                    if vals.isSymbolicLink == true { continue }
                    let name = item.lastPathComponent
                    if excludeSet.contains(name) { continue }
                    let rel = prefix.isEmpty ? name : prefix + "/" + name
                    if excludeSet.contains(rel) { continue }
                    if vals.isDirectory == true {
                        try walk(item, prefix: rel)
                    } else {
                        if defaultExcludeExtensions.contains(item.pathExtension.lowercased()) { continue }
                        let size = vals.fileSize ?? 0
                        if size > maxBytes {
                            skipped.append(["path": rel, "reason": "größer als \(maxFileMB) MB (\(size / (1024 * 1024)) MB)"])
                            continue
                        }
                        localEntries.append((rel, item))
                    }
                }
            }
            try walk(sourceURL, prefix: "")
        }

        var toUpload: [(rel: String, data: Data, sha256: String, executable: Bool)] = []
        var unchanged = 0
        var localRelSet = Set<String>()
        for (rel, url) in localEntries {
            localRelSet.insert(rel)
            let data = try Data(contentsOf: url)
            if data.count > maxBytes {
                skipped.append(["path": rel, "reason": "größer als \(maxFileMB) MB"])
                continue
            }
            let sha = sha256Hex(data)
            if let remote = remoteFiles[rel], (remote["sha256"] as? String) == sha {
                unchanged += 1
            } else {
                let perms = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                toUpload.append((rel, data, sha, (perms & 0o111) != 0))
            }
        }

        var toDelete: [String] = []
        if deleteExtraneous && isDir.boolValue {
            for rel in remoteFiles.keys.sorted() where !localRelSet.contains(rel) {
                let firstPart = rel.split(separator: "/").first.map(String.init) ?? ""
                if !excludeSet.contains(firstPart) && !excludeSet.contains(rel) {
                    toDelete.append(rel)
                }
            }
        }

        var uploadedPaths: [String] = []
        var deletedPaths: [String] = []
        var totalBytes = 0
        let batchByteLimit = 32 * 1024 * 1024
        let batchFileLimit = 200
        var idx = 0
        while idx < toUpload.count {
            var batch: [[String: Any]] = []
            var batchBytes = 0
            while idx < toUpload.count && batch.count < batchFileLimit {
                let item = toUpload[idx]
                if !batch.isEmpty && batchBytes + item.data.count > batchByteLimit { break }
                batch.append(["path": item.rel, "data": item.data.base64EncodedString(), "sha256": item.sha256, "executable": item.executable])
                batchBytes += item.data.count
                idx += 1
            }
            progress("Übertrage \(uploadedPaths.count + batch.count)/\(toUpload.count) geänderte Dateien nach bigki …")
            let delNow = (idx == toUpload.count) ? toDelete : []
            let reply = try workerCall(["operation": "sync", "action": "put", "dest": resolvedDest, "files": batch, "delete": delNow], control: control)
            uploadedPaths += reply["written"] as? [String] ?? []
            deletedPaths += reply["deleted"] as? [String] ?? []
            totalBytes += reply["bytes"] as? Int ?? batchBytes
        }
        if toUpload.isEmpty && !toDelete.isEmpty {
            let reply = try workerCall(["operation": "sync", "action": "put", "dest": resolvedDest, "files": [], "delete": toDelete], control: control)
            deletedPaths += reply["deleted"] as? [String] ?? []
        }

        let elapsed = (Date().timeIntervalSince(started) * 10).rounded() / 10
        return [
            "ok": true,
            "source": sourceURL.path,
            "dest": resolvedDest,
            "uploaded": uploadedPaths,
            "uploaded_count": uploadedPaths.count,
            "unchanged_count": unchanged,
            "deleted": deletedPaths,
            "skipped": skipped,
            "bytes_uploaded": totalBytes,
            "seconds": elapsed,
        ]
    }
}
