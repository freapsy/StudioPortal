import Foundation
import AppKit

// Agent interface: the same binary as the app. `studioportal <command>` prints one JSON object on stdout
// (progress as text lines on stderr); `studioportal mcp` is an MCP server (stdio) with the same operations.
// Both call the same backends as the app, so results land in the same library and sync like everything else.

enum AgentOps {
    typealias Progress = (String) -> Void

    static func status() -> [String: Any] {
        let machine = MachineStatus.fetch()
        var out: [String: Any] = ["reachable": machine.reachable, "summary": machine.summary, "lock": machine.lock,
                "cards": machine.cards.map { ["index": $0.index, "temp_c": $0.temp as Any, "busy_percent": $0.busy as Any,
                                              "vram_gb": (100 * $0.vramGB).rounded() / 100, "job": $0.job as Any,
                                              "origin": $0.origin as Any, "foreign": $0.foreign, "foreign_by": $0.foreignBy] },
                "queue": machine.queue.map { ["label": $0.label, "origin": $0.origin, "cards": $0.cards, "reason": $0.reason as Any] },
                "blender_sessions": machine.sessions.map { ["name": $0.name, "owner": $0.owner, "memory_gb": $0.memoryGB as Any,
                                                            "working_on": $0.current as Any, "last_call": $0.last as Any, "objects": $0.objects as Any,
                                                            "blender": $0.blender as Any, "build_type": $0.buildType as Any] },
                "folders": paths()]
        if let cpu = machine.cpu, !cpu.json.isEmpty { out["cpu"] = cpu.json }
        return out
    }

    static func paths() -> [String: String] {
        ["images": picturesDirectory.path, "music": musicDirectory.path, "speech": speechDirectory.path, "videos": videosDirectory.path, "models": modelsDirectory.path]
    }


    static func image(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        var settings = Settings()
        if let like = p["like"] as? String {
            // = "Übernehmen" in the app: prompt, size, references and all settings of an earlier image
            let url = URL(fileURLWithPath: expand(like))
            guard let data = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")),
                  let meta = try? jsonDecoder().decode(RunMetadata.self, from: data) else {
                throw StudioError.message("like: keine gespeicherten Einstellungen zu \(url.path)")
            }
            settings = meta.settings
            settings.seed = meta.actualSeed ?? meta.settings.seed
            if (p["new_seed"] as? Bool) == true { settings.seed = Int64.random(in: 0...Int64(Int32.max)) }
        }
        if let prompt = p["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { settings.prompt = prompt }
        guard !settings.prompt.isEmpty else { throw StudioError.message("prompt fehlt (oder like=<bild> angeben).") }
        settings.count = int(p, "count") ?? 1
        let refs = strings(p, "references")
        if !refs.isEmpty {
            settings.mode = "Bearbeiten"
            settings.references = refs.map { Reference(path: expand($0)) }
            for ref in settings.references where !FileManager.default.fileExists(atPath: ref.path) {
                throw StudioError.message("Referenzbild nicht gefunden: \(ref.path)")
            }
        }
        if let name = p["preset"] as? String {
            guard let preset = ImagePreset.all.first(where: { $0.choice.id == name }) else {
                throw StudioError.message("preset: " + ImagePreset.all.map(\.choice.id).joined(separator: ", "))
            }
            preset.apply(to: &settings)
        }
        if p["aspect"] != nil || p["megapixels"] != nil {
            let aspect = (p["aspect"] as? String) ?? ImageFormat.aspect(of: settings.width, settings.height)
            guard ImageFormat.aspects.contains(where: { $0.0 == aspect }) else {
                throw StudioError.message("aspect: " + ImageFormat.aspects.map(\.0).joined(separator: ", "))
            }
            let mp = (p["megapixels"] as? Double) ?? Double(int(p, "megapixels") ?? 0)
            (settings.width, settings.height) = ImageFormat.size(aspect: aspect, mp: mp > 0 ? min(mp, 16) : ImageFormat.megapixels(settings.width, settings.height))
        }
        if let sampler = p["sampler"] as? String { settings.sampler = sampler }
        if let scheduler = p["scheduler"] as? String { settings.scheduler = scheduler == "h3" ? "" : scheduler }
        if let cfg = (p["cfg"] as? Double) ?? (int(p, "cfg").map(Double.init)) { settings.cfg = cfg }
        if let width = int(p, "width") { settings.width = width }
        if let height = int(p, "height") { settings.height = height }
        settings.normalizeSize()
        if let seed = int(p, "seed") { settings.seed = Int64(seed) }
        if let steps = int(p, "steps") { settings.steps = steps }
        if let speed = p["speed_lora"] as? Bool {
            let steps = settings.steps; settings.setSpeedLora(speed)
            if int(p, "steps") != nil { settings.steps = steps }
        }
        if let rng = p["rng"] as? String { settings.rng = rng }
        if let flash = p["flash_attention"] as? Bool { settings.flashAttention = flash }
        if let tiling = p["vae_tiling"] as? Bool { settings.vaeTiling = tiling }
        if let extra = p["extra"] as? String { settings.extra = extra }
        let start = Date()
        var last = ""
        let files = try Backend().generate(settings, control: control) { state in
            var text = state.waiting ?? state.phase
            if let step = state.step, let total = state.total { text += " \(step)/\(total)" }
            if text != last { last = text; progress(text) }
        }
        return ["files": files.map(\.path), "seed": settings.seed, "width": settings.width, "height": settings.height,
                "steps": settings.steps, "speed_lora": settings.usesSpeedLora, "seconds": Int(Date().timeIntervalSince(start))]
    }

    static func music(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        var settings = MusicSettings()
        settings.lyrics = MusicSettings.instrumental
        if let like = p["like"] as? String {
            // = "Übernehmen" in the app: description, lyrics, length, melody and sound seed and the CFG values of an earlier song
            let url = URL(fileURLWithPath: expand(like))
            guard let data = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")),
                  let replay = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StudioError.message("like: keine Replay-Datei zu \(url.path)")
            }
            settings.caption = replay["caption"] as? String ?? ""
            settings.lyrics = replay["lyrics"] as? String ?? settings.lyrics
            if let v = replay["duration"] as? NSNumber { settings.duration = v.doubleValue }
            if let v = replay["lm_seed"] as? NSNumber { settings.lmSeed = v.int64Value }
            if let v = replay["seed"] as? NSNumber { settings.seed = v.int64Value }
            if let v = replay["lm_cfg"] as? NSNumber { settings.lmCfg = v.doubleValue }
            if let v = replay["dit_cfg"] as? NSNumber { settings.ditCfg = v.doubleValue }
            if let v = replay["lm_top_k"] as? NSNumber { settings.topK = v.intValue }
            settings.format = url.pathExtension.lowercased() == "wav" ? "wav" : "mp3"
            if (p["new_seed"] as? Bool) == true { settings.lmSeed = Int64.random(in: 0...Int64(Int32.max)) }
        }
        if let caption = p["caption"] as? String, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { settings.caption = caption }
        guard !settings.caption.isEmpty else { throw StudioError.message("caption fehlt (oder like=<song> angeben).") }
        if let lyrics = p["lyrics"] as? String, !lyrics.isEmpty { settings.lyrics = lyrics }
        settings.variants = 3; settings.steps = 8
        if let name = p["preset"] as? String {
            guard let preset = MusicPreset.all.first(where: { $0.choice.id == name }) else {
                throw StudioError.message("preset: " + MusicPreset.all.map(\.choice.id).joined(separator: ", "))
            }
            preset.apply(to: &settings)
        }
        if (p["instrumental"] as? Bool) == true {
            settings.lyrics = MusicSettings.instrumental
            if !settings.caption.localizedCaseInsensitiveContains("no vocals") { settings.caption += " No vocals. Purely instrumental." }
        }
        if let duration = double(p, "duration") { settings.duration = duration }
        if let variants = int(p, "variants") { settings.variants = variants }
        if let quality = p["quality"] as? String { settings.steps = quality == "full" ? 30 : 8 }
        if let steps = int(p, "steps") { settings.steps = steps }
        if let format = p["format"] as? String { settings.format = format == "wav" ? "wav" : "mp3" }
        if let seed = int(p, "seed") { settings.lmSeed = Int64(seed) }
        if let seed = int(p, "sound_seed") { settings.seed = Int64(seed) } else if p["like"] == nil, let seed = int(p, "seed") { settings.seed = Int64(seed) }
        if let v = double(p, "lm_cfg") { settings.lmCfg = v }
        if let v = double(p, "dit_cfg") { settings.ditCfg = v }
        if let v = int(p, "top_k") { settings.topK = v }
        let start = Date()
        let files = try MusicBackend().generate(try settings.request(), control: control, update: musicProgress(progress))
        return ["songs": files.map { ["audio": $0.path, "replay": $0.deletingPathExtension().appendingPathExtension("json").path] },
                "steps": settings.steps, "lm_seed": settings.lmSeed, "sound_seed": settings.seed, "lm_cfg": settings.lmCfg,
                "dit_cfg": settings.ditCfg, "top_k": settings.topK, "seconds": Int(Date().timeIntervalSince(start)),
                "note": settings.steps < 30 ? "Vorschau (8 Schritte). Mit render_music_full in voller Qualität rendern." : "Volle Qualität."]
    }

    static func renderFull(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        let files = strings(p, "files").map(expand)
        guard (1...3).contains(files.count) else { throw StudioError.message("Ein bis drei Songs angeben (Pfad zur .mp3/.wav).") }
        var replays: [[String: Any]] = []
        for file in files {
            let replay = URL(fileURLWithPath: file).deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: replay), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StudioError.message("Replay-Datei fehlt: \(replay.path)")
            }
            json.removeValue(forKey: "steps"); json.removeValue(forKey: "studioportal")
            replays.append(json)
        }
        let names = files.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent + "-voll" }
        let format = files[0].lowercased().hasSuffix(".mp3") ? "mp3" : "wav16"
        let start = Date()
        let out = try MusicBackend().generate(["operation": "music", "replays": replays, "steps": 30, "output_format": format],
                                              names: names, control: control, update: musicProgress(progress))
        return ["songs": out.map { ["audio": $0.path, "replay": $0.deletingPathExtension().appendingPathExtension("json").path] },
                "seconds": Int(Date().timeIntervalSince(start))]
    }

    private static func musicProgress(_ progress: @escaping Progress) -> (MusicProgress) -> Void {
        var last = ""
        return { state in
            let parts = state.variants.keys.sorted().map { key -> String in
                let v = state.variants[key]!
                return "V\(key) \(v.phase)" + (v.current.map { c in v.total.map { " \(c)/\($0)" } ?? "" } ?? "")
            }
            let text = state.waiting ?? (parts.isEmpty ? state.status : parts.joined(separator: " · "))
            if text != last { last = text; progress(text) }
        }
    }

    static func model3D(_ p: [String: Any], control: NodeControl, progress: @escaping Progress) throws -> [String: Any] {
        var images: [String: String] = [:]
        for view in ["front", "left", "back", "right"] {
            if let path = p[view] as? String {
                let full = expand(path)
                guard FileManager.default.fileExists(atPath: full) else { throw StudioError.message("Bild nicht gefunden: \(full)") }
                images[view] = full
            }
        }
        let color = (p["color"] as? Bool) ?? (images.count == 4)
        guard !images.isEmpty, !color || images.count == 4 else {
            throw StudioError.message(color ? "Für Farben alle vier Ansichten (front, left, back, right) angeben." : "Mindestens ein Bild (front) angeben.")
        }
        let model = (p["model"] as? String) ?? "standard"
        let resolution = int(p, "resolution") ?? 768
        guard ["standard", "turbo"].contains(model), [380, 768, 1024].contains(resolution) else {
            throw StudioError.message("model: standard|turbo, resolution: 380|768|1024.")
        }
        let options: [String: Any] = ["images": images, "model": model, "resolution": resolution, "color": color, "person": (p["person"] as? Bool) ?? false]
        let start = Date()
        let file = try runNode(script: "from_images.mjs", arguments: [], input: try JSONSerialization.data(withJSONObject: options), control: control, progress: progress)
        return result3D(file, start)
    }

    static func importModel(_ p: [String: Any], control: NodeControl, progress: @escaping Progress) throws -> [String: Any] {
        var source = try string(p, "source", required: true)
        if !source.contains("://") {
            let path = expand(source)
            guard FileManager.default.fileExists(atPath: path) else { throw StudioError.message("Datei nicht gefunden: \(path)") }
            source = URL(fileURLWithPath: path).absoluteString
        }
        let start = Date()
        let file = try runNode(script: "download.mjs", arguments: [source], input: nil, control: control, progress: progress)
        return result3D(file, start)
    }

    private static func result3D(_ file: URL, _ start: Date) -> [String: Any] {
        let preview = ModelRecord.metaFolder(for: file).appendingPathComponent("preview.png")
        return ["file": file.path, "preview": FileManager.default.fileExists(atPath: preview.path) ? preview.path : NSNull(),
                "seconds": Int(Date().timeIntervalSince(start))]
    }

    static func library(_ p: [String: Any]) -> [String: Any] {
        let kind = (p["kind"] as? String).flatMap { ["image": ItemKind.image, "images": .image, "music": .music, "video": .video, "videos": .video, "model": .model, "3d": .model][$0.lowercased()] }
        let search = (p["search"] as? String) ?? ""
        let limit = int(p, "limit") ?? 30
        let items = Library.load().filter { item in
            (kind == nil || item.kind == kind) && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.url.lastPathComponent.localizedCaseInsensitiveContains(search))
        }
        let formatter = ISO8601DateFormatter()
        return ["count": items.count, "items": items.prefix(max(1, min(limit, 500))).map { item -> [String: Any] in
            ["kind": item.kind.rawValue, "file": item.url.path, "title": item.title, "detail": item.detail,
             "date": formatter.string(from: item.date), "bytes": ((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) as Any?) ?? NSNull(), "origin": item.origin as Any, "preview": item.preview?.path as Any]
        }]
    }

    static func examples() throws -> [String: Any] {
        ["examples": try MusicBackend().examples().map { ["name": $0.name, "group": $0.group, "duration": $0.duration, "caption": $0.caption, "lyrics": $0.lyrics] }]
    }

    // MARK: node (3D, import)

    final class NodeControl {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func attach(_ p: Process) { lock.lock(); process = p; let stop = cancelled; lock.unlock(); if stop { p.terminate() } }
        func cancel() { lock.lock(); cancelled = true; let p = process; lock.unlock(); p?.terminate() }
    }

    static func runNode(script: String, arguments: [String], input: Data?, control: NodeControl, progress: Progress) throws -> URL {
        guard let resources = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: resources.appendingPathComponent(script).path) else {
            throw StudioError.message("StudioPortal-Ressourcen nicht gefunden. Den Befehl über ~/.local/bin/studioportal starten.")
        }
        guard let blender = blenderApplication()?.appendingPathComponent("Contents/MacOS/Blender") else {
            throw StudioError.message("Blender wurde nicht gefunden (~/Applications oder /Applications).")
        }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = resources.appendingPathComponent("node")
        process.arguments = [resources.appendingPathComponent(script).path] + arguments + [modelsDirectory.path, blender.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "STUDIOPORTAL_ORIGIN": requestOrigin]
        process.standardOutput = output; process.standardError = output; process.standardInput = stdin
        try process.run()
        control.attach(process)
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()
        var result: URL?, failure: String?, tail = ""
        var pending = Data()
        while let chunk = try? output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[pending.startIndex..<newline]; pending.removeSubrange(pending.startIndex...newline)
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = event["type"] as? String else {
                    tail = String((tail + String(decoding: line, as: UTF8.self) + "\n").suffix(600)); continue
                }
                let message = event["message"] as? String ?? ""
                switch type {
                case "status", "notice": if !message.isEmpty { progress(message) }
                case "done": result = (event["path"] as? String).map { URL(fileURLWithPath: $0) }
                case "error", "cancelled": failure = message
                default: break
                }
            }
        }
        process.waitUntilExit()
        if let result { return result }
        throw StudioError.message(failure ?? (tail.isEmpty ? "Fehler \(process.terminationStatus)" : tail))
    }

    static func speech(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        let action = (p["action"] as? String) ?? ((p["text"] as? String) != nil ? "speak" : "status")
        if action == "status" || action == "start" || action == "stop" {
            return try SpeechRemote.call(action, control: control, progress: progress)
        }
        var settings = SpeechSettings()
        settings.text = try string(p, "text", required: true)
        if let eng = p["engine"] as? String, !eng.isEmpty { settings.engine = eng }
        if let t = double(p, "temperature") { settings.temperature = t }
        if let tp = double(p, "top_p") { settings.topP = tp }
        if let tk = int(p, "top_k") { settings.topK = tk }
        if let mt = int(p, "max_tokens") { settings.maxTokens = mt }
        if let cs = int(p, "text_chunk_size") { settings.textChunkSize = cs }
        if let s = int(p, "seed") { settings.seed = Int64(s); settings.seedLocked = true }
        if let ref = p["voice_ref"] as? String, !ref.isEmpty { settings.voiceRefPath = expand(ref) }
        if let rt = p["reference_text"] as? String { settings.referenceText = rt }
        if let spk = p["speaker"] as? String, !spk.isEmpty { settings.speaker = spk }
        if let inst = p["instruct"] as? String { settings.instruct = inst }
        let (url, info) = try SpeechRemote.speak(settings, control: control, progress: progress)
        var out = info
        out["file"] = url.path
        return out
    }

    static func phone(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        let action = (p["action"] as? String) ?? "status"
        var extra = p
        extra.removeValue(forKey: "action")
        extra.removeValue(forKey: "_positional")
        return try PhoneRemote.call(action, extra, control: control, progress: progress)
    }

    // MARK: parameter helpers

    static func string(_ p: [String: Any], _ key: String, required: Bool = false) throws -> String {
        let value = (p[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if required && value.isEmpty { throw StudioError.message("\(key) fehlt.") }
        return value
    }
    static func int(_ p: [String: Any], _ key: String) -> Int? {
        if let n = p[key] as? NSNumber { return n.intValue }
        return (p[key] as? String).flatMap { Int($0) }
    }
    static func double(_ p: [String: Any], _ key: String) -> Double? {
        if let n = p[key] as? NSNumber { return n.doubleValue }
        return (p[key] as? String).flatMap { Double($0) }
    }
    static func strings(_ p: [String: Any], _ key: String) -> [String] {
        if let list = p[key] as? [String] { return list }
        if let one = p[key] as? String { return [one] }
        return []
    }
    static func expand(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    }
}

// MARK: - Command line

enum AgentCLI {
    static let commands: Set<String> = ["help", "--help", "-h", "info", "version", "status", "image", "music", "speech", "phone", "render-full", "vergleich", "compare", "guide", "anleitung", "video", "blender", "sync", "3d", "figur", "import",
                                        "library", "examples", "paths", "mcp", "setup-agents", "llm", "serve", "setup-iphone",
                                        "sync-info", "sync-delete", "sync-prepare", "sync-mark", "sync-now"]

    static func handles(_ arguments: [String]) -> Bool { arguments.count > 1 && commands.contains(arguments[1]) }

    static let help = """
    StudioPortal – Bilder, Musik, Video, Blender und 3D auf bigki (3× MI50). Ausgabe: ein JSON-Objekt auf stdout, Fortschritt auf stderr.

      studioportal status                         Grafikkarten, Warteschlange, Ordner
      studioportal guide bild|musik|video|3d|figur|blender|vergleich   Anleitung: Ablauf, Vorlagen, Voreinstellungen, Regler, Tipps
      studioportal image "Prompt" [--count 1-4] [--aspect 16:9 | --width W --height H] [--seed N] [--steps N] [--ref bild.png ...]
                         [--preset entwurf|foto|…] [--speed-lora] [--rng cpu] [--no-flash-attention] [--no-vae-tiling] [--extra "…"]
      studioportal music "Beschreibung" [--lyrics "[verse]..." | --instrumental] [--duration 60] [--variants 1-3]
                         [--quality preview|full] [--format mp3|wav] [--seed N] [--preset skizze|voll|…] [--steps N]
                         [--sound-seed N] [--lm-cfg 1.7] [--dit-cfg 1.7] [--top-k 50]
      Bild, Musik, Video: --like <frühere Datei> übernimmt alle Einstellungen (= „Übernehmen“), mit --new-seed = „Variieren“
      studioportal render-full song-v1.mp3 [song-v2.mp3 song-v3.mp3]   Vorschauen in voller Qualität (parallel, je eine Karte)
      studioportal video "Bild und Ton (englisch), am Ende: Audio: …" [--seconds 5] [--aspect 16:9|9:16|1:1|16:9-hd] [--seed N] [--cards 2|3]
                                                  MiniMax H3 Turbo4, ~5–7 min für 5 s auf zwei MI50 (die dritte bleibt frei)

      Blender-Sitzung auf bigki (Blender 5.3, bleibt zwischen Aufrufen offen, [--session name], Standard: eine Sitzung je Mac):
      studioportal blender python "bpy-Code"  | --script datei.py [--mit-ordner]   Python ausführen (__file__ + sys.path; --mit-ordner synct Projekt nach bigki)
      studioportal sync <Mac-Ordner|Datei> [bigki:~/ziel] [--exclude "a,b"] [--delete] [--max-file-mb 50]   Inkrementeller SHA-256-Sync nach bigki
      studioportal blender scene [--object Name]                     Szene als JSON (Objekte, Material, Kamera, Render)
      studioportal blender look [--mode solid|eevee|cycles] [--size 768] [--camera Name] [--frame N] [--overview true]
      studioportal blender open datei.blend|.glb|.fbx|.obj [--append true]
      studioportal blender save [--filename name.blend]             als .blend (gepackt) in den 3D-Ordner
      studioportal blender render [--frames 1|1-48|all] [--samples N] [--noise 0.01|off] [--percentage 100] [--cards 1-3]
                                                  Cycles auf den MI50: Standbild → Bilder, Animation → MP4 in Videos
      studioportal blender api bpy.ops.mesh.primitive_cube_add | bpy.types.Object.location
      studioportal blender look --views rund|vier|vorne,rechts [--focus Figur:Hand_R] [--color-by teile|material|vertex_groups] [--only A,B] [--reference bild.png]
      studioportal blender check [Objekt,…] [--contact "Figur:Hand_R,Handy"] [--floor true]   Zahlen: Inseln, Löcher, Schichten, Kontakt
      studioportal blender snapshot [name] [--note text] | snapshots | restore [name]          Zwischenstände
      studioportal blender tools show|add|set|reload|clear [--code "…" | --script datei.py]     werkzeuge.py (lädt bei jedem Start)
      studioportal blender open --path ~/ordner/datei.blend      Datei, die schon auf bigki liegt (kein Upload)
      studioportal blender save --bigki-path ~/ordner/            nur auf bigki speichern
      studioportal blender render --cameras KamA,KamB [--name serie] [--folder unterordner]
      studioportal blender info | new [--empty true] | sessions | quit | reset

      studioportal vergleich vorher.png nachher.png [--labels "vorher,nachher"] [--regions "Kragen:0.4,0.1,0.6,0.25;Saum:0.3,0.8,0.7,0.95"]
                                                  beschriftete Vorher-nachher-Leiste (Kamera, Auflösung, Samples, Quelle) → Bilder/Vergleiche/

      studioportal figur --image person.png [--pose a|hand-hoch|arme-hoch] [--seed N]   Figur in A-Pose (Hunyuan3D-Omni), .glb
      studioportal 3d --front vorne.png [--left --back --right ...] [--model standard|turbo] [--resolution 380|768|1024] [--no-color] [--person]
      studioportal import <Link oder Datei>       Modell als .blend importieren
      studioportal llm "Frage" [--system "…"] [--thinking none|low|medium|high] [--max-tokens N]   Qwen3.8 Flash Next (Strata, 3× MI50) – Antwort + Tokens/s
      studioportal llm status|start|stop [--force true]   Strata starten/stoppen (stoppt sonst nach 20 min ohne Anfrage)
      studioportal library [--kind image|music|video|model] [--search Text] [--limit 30]
      studioportal examples                       Musik-Vorlagen (61 offizielle Demos)
      studioportal info                           Aufbau von StudioPortal (alle Teile, Regeln, Ausrollen)
      studioportal mcp                            MCP-Server (stdio) mit denselben Funktionen
      studioportal setup-iphone                   Zugang für die iPhone-App einrichten (Dienst auf Port 8790, nur über Tailscale; zeigt Adresse + Schlüssel)
      studioportal serve                          dieser Dienst selbst (läuft als LaunchAgent)
      studioportal setup-agents                   Befehl + MCP für Claude Code, Codex und Claude Desktop einrichten

    Alle Aufträge laufen über die gemeinsame Warteschlange auf bigki (Blender und fremde GPU-Jobs haben Vorrang).
    Musik von MiniMax Music 3 bei Veröffentlichung als KI-erzeugt kennzeichnen.
    """

    static func run(_ arguments: [String]) -> Int32 {
        requestOrigin = "\(machineName) · Agent"
        let command = arguments.first ?? "help"
        var rest = Array(arguments.dropFirst())
        if command == "mcp" { MCPServer().run(); return 0 }
        if command == "serve" {
            do { try Gateway().run() } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); return 1 }
        }
        let quiet = rest.contains("--quiet"); rest.removeAll { $0 == "--quiet" }
        let progress: AgentOps.Progress = { line in if !quiet { FileHandle.standardError.write(Data(("… " + line + "\n").utf8)) } }
        let control = RunControl(), node = AgentOps.NodeControl()
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { control.cancel(); node.cancel() }
            source.resume()
            retained.append(source)
        }
        do {
            var blenderAction = ""
            if command == "blender" {
                guard let first = rest.first, !first.hasPrefix("--") else { throw StudioError.message("Blender-Aktion fehlt (python, scene, look, open, save, render, api, info, new, sessions, quit, reset).") }
                blenderAction = first; rest.removeFirst()
            }
            let blenderPositional = ["python": "code", "open": "file", "api": "identifier", "save": "filename", "scene": "object",
                                     "check": "objects", "snapshot": "name", "restore": "name", "tools": "mode"][blenderAction]
            let p = try parse(rest, positional: command == "blender" ? blenderPositional : ["image": "prompt", "music": "caption", "video": "prompt", "import": "source"][command])
            let result: [String: Any]
            switch command {
            case "help", "--help", "-h": print(help); return 0
            case "info": print(architectureText()); return 0
            case "version": result = ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1", "binary": CommandLine.arguments[0]]
            case "status": result = AgentOps.status()
            case "paths": result = AgentOps.paths()
            case "image": result = try AgentOps.image(p, control: control, progress: progress)
            case "music": result = try AgentOps.music(p, control: control, progress: progress)
            case "render-full": result = try AgentOps.renderFull(["files": p["_positional"] ?? []], control: control, progress: progress)
            case "video": result = try AgentOps.video(p, control: control, progress: progress)
            case "blender": result = try AgentOps.blender(blenderAction, p, control: control, progress: progress)
            case "sync": result = try AgentOps.syncFiles(p, control: control, progress: progress)
            case "3d": result = try AgentOps.model3D(p, control: node, progress: progress)
            case "figur": result = try AgentOps.figure(p, control: control, progress: progress)
            case "import": result = try AgentOps.importModel(p, control: node, progress: progress)
            case "library": result = AgentOps.library(p)
            case "llm":
                var q = p
                if let first = (p["_positional"] as? [String])?.first {
                    if ["status", "start", "stop"].contains(first) { q["action"] = first } else { q["prompt"] = first }
                }
                result = try AgentOps.llm(q, control: control, progress: progress)
            case "speech":
                var q = p
                if let first = (p["_positional"] as? [String])?.first {
                    if ["status", "start", "stop"].contains(first) { q["action"] = first } else { q["text"] = first; q["action"] = "speak" }
                }
                result = try AgentOps.speech(q, control: control, progress: progress)
            case "phone":
                var q = p
                if let first = (p["_positional"] as? [String])?.first { q["action"] = first }
                result = try AgentOps.phone(q, control: control, progress: progress)
            case "vergleich", "compare": result = try Comparison.make(p)
            case "guide", "anleitung": result = try Guide.make((p["_positional"] as? [String])?.first ?? p["topic"] as? String)
            case "examples": result = try AgentOps.examples()
            case "setup-iphone": result = try GatewayConfig.install()
            case "setup-agents": result = AgentSetup.installAll()
            case "sync-info": result = SyncHub.info()
            case "sync-delete": result = try SyncHub.delete(FileHandle.standardInput.readDataToEndOfFile())
            case "sync-prepare": result = try SyncHub.prepare((p["_positional"] as? [String])?.first ?? "")
            case "sync-mark": result = SyncHub.mark(FileHandle.standardInput.readDataToEndOfFile())
            case "sync-now": result = SyncHub.syncNowFromCLI()
            default: print(help); return 2
            }
            printJSON(result)
            return 0
        } catch {
            printJSON(["error": error.localizedDescription])
            return 1
        }
    }

    nonisolated(unsafe) static var retained: [DispatchSourceSignal] = []

    /// `--key value`, `--flag`, repeated `--ref` → references, `--no-color` → color=false; the first bare word is the positional argument.
    static func parse(_ arguments: [String], positional: String?) throws -> [String: Any] {
        var result: [String: Any] = [:]
        var bare: [String] = []
        var index = 0
        let flags: Set<String> = ["instrumental", "color", "person", "new_seed", "speed_lora", "flash_attention", "vae_tiling", "mit_ordner", "with_dir", "delete"]
        while index < arguments.count {
            let item = arguments[index]
            if item.hasPrefix("--") {
                let key = String(item.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
                if key.hasPrefix("no_") { result[String(key.dropFirst(3))] = false; index += 1; continue }
                if flags.contains(key) { result[key] = true; index += 1; continue }
                guard index + 1 < arguments.count else { throw StudioError.message("Wert für --\(key) fehlt.") }
                let value = arguments[index + 1]
                if key == "ref" || key == "reference" { result["references", default: [String]()] = (result["references"] as? [String] ?? []) + [value] }
                else { result[key] = value }
                index += 2
            } else { bare.append(item); index += 1 }
        }
        if let positional, let first = bare.first, result[positional] == nil { result[positional] = bare.count == 1 ? first : bare.joined(separator: " ") }
        result["_positional"] = bare
        return result
    }

    static func printJSON(_ value: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// The Mac mini side of sync, called by the MacBook over SSH.
enum SyncHub {
    static func info() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return ["enabled": SyncEngine.flagEnabled(), "machine": machineName,
                "storiMissing": (try? requireStori()) == nil,
                "folders": SyncLedger.folders().mapValues(\.path),
                "deleted": SyncLedger.load().map { ["kind": $0.kind, "path": $0.path, "date": formatter.string(from: $0.date)] }]
    }
    static func delete(_ data: Data) throws -> [String: Any] {
        guard SyncEngine.flagEnabled() else { throw StudioError.message("Sync ist hier ausgeschaltet.") }
        let records = try jsonDecoder().decode([DeletionRecord].self, from: data)
        return ["trashed": SyncLedger.apply(records)]
    }
    static func prepare(_ kind: String) throws -> [String: Any] {
        guard SyncEngine.flagEnabled() else { throw StudioError.message("Sync ist hier ausgeschaltet.") }
        guard let folder = SyncLedger.folders()[kind] else { throw StudioError.message("Unbekannter Bereich.") }
        try requireStori()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ["folder": folder.path]
    }
    static func mark(_ data: Data) -> [String: Any] {
        if let mark = try? jsonDecoder().decode(SyncEngine.Mark.self, from: data) { SyncEngine.writeMark(mark) }
        return ["ok": true]
    }
    static func syncNowFromCLI() -> [String: Any] {
        let peer = UserDefaults.standard.string(forKey: "syncPeer") ?? (machineName == "Mac mini" ? "" : SyncEngine.defaultPeer)
        guard !peer.isEmpty else { return ["error": "Dieser Mac ist die Zentrale; synchronisiert wird vom MacBook aus."] }
        guard SyncEngine.flagEnabled() else { return ["error": "Sync ist in den Einstellungen ausgeschaltet."] }
        do {
            let (pulled, pushed, deleted) = try SyncEngine.run(peer: peer)
            return ["pulled": pulled, "pushed": pushed, "deleted": deleted]
        } catch { return ["error": error.localizedDescription] }
    }
}

// MARK: - MCP server (JSON-RPC 2.0 over stdio)

final class MCPServer {
    private let output = NSLock()
    private let jobsLock = NSLock()
    private var jobs: [String: Job] = [:]
    private var controls: [String: (RunControl, AgentOps.NodeControl)] = [:]

    final class Job {
        var id: String, tool: String, state = "läuft", progress = "", result: [String: Any]?, error: String?
        let started = Date()
        let control = RunControl(), node = AgentOps.NodeControl()
        init(id: String, tool: String) { self.id = id; self.tool = tool }
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else { return }
        output.lock(); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)); output.unlock()
    }

    private func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"] else {
            if method == "notifications/cancelled", let requestId = params["requestId"] {
                jobsLock.lock(); let control = controls["\(requestId)"]; jobsLock.unlock()
                control?.0.cancel(); control?.1.cancel()
            }
            return
        }
        switch method {
        case "initialize":
            reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                       "capabilities": ["tools": ["listChanged": false]],
                       "serverInfo": ["name": "studioportal", "version": "1.0"],
                       "instructions": "StudioPortal erzeugt auf bigki (drei MI50) Bilder (MiniMax H3 Image), Musik (MiniMax Music 3), Videos mit Ton (MiniMax H3) und 3D-Modelle (Hunyuan3D → Blender) und bietet eine Blender-Sitzung (Blender 5.3, headless). Vor der ersten Nutzung einer Funktion guide topic=bild|musik|video|3d|figur|blender|vergleich lesen: dort steht dasselbe wie in den ⓘ-Erklärungen der App (Ablauf, Vorlagen, Voreinstellungen mit Werten, jeder Regler, Tipps). Agenten können alles, was die App kann; like=<datei> (+ new_seed) entspricht „Übernehmen“/„Variieren“. Alle GPU-Aufträge teilen sich eine Warteschlange mit dem Nutzer; Blender und fremde GPU-Jobs haben Vorrang. Lange Aufträge (create_video, blender_render, …) mit wait=false starten und mit get_job abfragen. Ergebnisse liegen als Dateien in der gemeinsamen Bibliothek (Pfade in der Antwort). Blender-Arbeitsweise: blender_scene lesen → mit blender_python in kleinen Schritten ändern (Variable result für Rückgaben, bpy/C/D sind da, der Zustand bleibt erhalten) → mit blender_look (solid schnell, eevee für Material/Licht) prüfen → blender_render (Cycles auf den MI50) oder blender_save. Bei unbekannter API zuerst blender_api statt raten. Nach jedem größeren Schritt blender_check (Zahlen: lose Teile, Löcher, Schichten, Boden, Kontakt Hand↔Objekt) und blender_look mit views (z. B. \"vier\") bzw. focus auf Details; vor riskanten Schritten blender_snapshot (save), bei Verschlechterung restore – nach ~3 erfolglosen Korrekturen lieber zurück statt weiter flicken. Eigene Hilfsfunktionen mit blender_tools oder blender_python persist=true dauerhaft machen (werden bei jedem Neustart geladen). Zeilen, die mit LOG beginnen, kommen gesammelt in log zurück. Figuren (realistische Menschen, z. B. Porzellan-Look) nicht in der Endpose erzeugen, sondern so: 1) Körper in A-Pose mit offenen Händen und ohne Requisiten – figur.mensch(...) (MPFB, fertig geriggt) oder ein Scan/KI-Mesh in A-Pose; 2) bei Scans figur.scan_aufraeumen, figur.abgleichen(rig, scan), figur.gewichte_uebertragen(koerper, scan, rig) – oder für beliebige Meshes (auch Tiere, Comicfiguren) figur.auto_rig(objekt): UniRig auf der CPU, ~8 min (läuft als job, get_job), 52 Knochen bone_0 …, Gewichte automatisch, Ort/Größe bleiben, gibt skelett mit Kopf-Positionen zurück; 3) posieren mit figur.arm_ik/bein_ik (Empties verschieben) – bei schweren Figuren vorher figur.schnell_posieren(True) (pausiert die Verformung von Körper/Kleid, leichter Stellvertreter im Bild; danach figur.schnell_posieren(False)); Requisiten mit figur.objekt_in_hand + figur.hand_greifen + figur.anhaengen, ein Handy hochkant mit figur.handy_griff(rig, 'R') (Finger um die Kante, Daumen seitlich, Handy wird gebaut oder handy=… platziert und angehängt); Bewegungen aus Mixamo-FBX/BVH mit figur.bvh_laden(datei, rig) (Retargeting aufs MPFB-Skelett: Gliedmaßen folgen der Richtung der Quelle – T-Pose der Quelle ergibt T-Pose –, Rumpf ohne Ruhepose-Korrektur, Blickrichtung, Hüfthöhe und Bodenkontakt – auch schiefe Mocap-Böden – werden ausgeglichen, die Figur startet an ihrem Platz; pruefung mit kopf_ueber_huefte_cm, boden_abstand_cm, weg_m in der Antwort); 4) figur.porzellan(...) und figur.studio_licht(...). Kleidung: in der A-Pose mit figur.kleid_anlegen(kleid, koerper, rig) anlegen (zieht anliegende Teile auf wenige mm an die Haut, schiebt Durchstoßendes raus, glättet Beulen, überträgt die Gewichte vom nächsten Hautpunkt, damit das Kleid der Pose folgt; frei = Vertexgruppe für fließende Teile; gewichte_uebertragen(…, modus='naechster') gibt es auch einzeln), erst danach posieren; lose Röcke/Ärmel in der Endpose mit figur.kleid_simulieren(kleid, koerper, pin_gruppe=…) fallen lassen; prüfen mit blender_check contact [Kleid, Körper] und blender_look zoom; Renders vorher/nachher mit compare_images (beschriftete Leiste mit Kamera/Auflösung/Samples/Quelle, regions für Detailausschnitte wie Kragen, Ärmelansatz, Taille, Saum). Übersicht: blender_python mit result = figur.hilfe(). Immer geladen ist auch helfer (kamera, punkte, glaetten, remesh, dezimieren – result = helfer.hilfe()). NaN/∞ in result kommen als null mit nan_warnung zurück. Die Sitzung belegt keine GPU und schließt sich nach 30 min ohne Aufruf; sie speichert nach jedem Aufruf automatisch (auch Sichtbarkeit), nach Neustart oder Absturz enthält die erste Antwort einen hinweis mit dem Grund (quit, 30 min Leerlauf, Absturz/Speicher, hängende Vorschau oder von außen beendet). Nach einem Neustart sind eigene Funktionen/Klassen/Imports aus blender_python und einfache Variablen (Zahlen, Text, Listen, Dicts, Vektoren, Matrizen, Blender-Objekte/Knochen) automatisch wieder da; der hinweis nennt sie. Reißt die Verbindung ab, rechnet bigki weiter und StudioPortal holt das Ergebnis selbst ab (sonst blender_session action=abholen ticket=…). Hängt eine Vorschau > 4 min, wird die Sitzung mit Grund beendet und startet beim nächsten Aufruf neu. Lange Aufrufe (> 50 s) kommen als job_id zurück → get_job wait=45. blender_look meldet im_bild (welche Objekte gerendert werden) und warnt, wenn etwas nur im Viewport ausgeblendet ist (für Bilder zählt hide_render) oder das Bild identisch mit dem vorigen ist. Speichergrenze 40 GB – vor Remesh helfer.groesse_pruefen. Eigene Skriptdateien: blender_tools script=… (bleibt geladen) oder blender_python script=… (einmal ausführen). Python-Pakete: numpy, scipy, igl, robust_laplacian. Große Dateien mit blender_open path / blender_save bigki_path auf bigki lassen. Aufbau des ganzen Systems: studioportal_info (auf bigki: ~/.local/share/3d-modelle-app/ARCHITEKTUR.md). Musik bei Veröffentlichung als KI-erzeugt kennzeichnen; H3-Videos nur privat (nicht in der EU veröffentlichen, nicht für Werbung)."])
        case "ping": reply(id, [:])
        case "tools/list": reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let token = (params["_meta"] as? [String: Any])?["progressToken"]
            DispatchQueue.global(qos: .userInitiated).async { self.call(id: id, name: name, arguments: arguments, token: token) }
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unbekannte Methode \(method)"]])
        }
    }

    private func call(id: Any, name: String, arguments: [String: Any], token: Any?) {
        var count = 0.0
        let progress: AgentOps.Progress = { [weak self] text in
            guard let token else { return }
            count += 1
            self?.send(["jsonrpc": "2.0", "method": "notifications/progress", "params": ["progressToken": token, "progress": count, "message": text]])
        }
        do {
            let result: [String: Any]
            switch name {
            case "get_job": result = try job(arguments)
            case "cancel_job":
                jobsLock.lock(); let job = jobs[(arguments["job_id"] as? String) ?? ""]; jobsLock.unlock()
                guard let job else { throw StudioError.message("Unbekannte job_id.") }
                job.control.cancel(); job.node.cancel()
                result = ["job_id": job.id, "state": "wird abgebrochen"]
            case "status": result = AgentOps.status()
            case "studioportal_info": result = ["file": architectureFile?.path ?? NSNull(), "text": architectureText()]
            case "list_library": result = AgentOps.library(arguments)
            case "compare_images":
                let value = try Comparison.make(arguments)
                var content: [[String: Any]] = [["type": "text", "text": json(value)]]
                if let path = value["image"] as? String, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                }
                reply(id, ["content": content, "structuredContent": value, "isError": false])
                return
            case "music_examples": result = try AgentOps.examples()
            case "llm": result = try AgentOps.llm(arguments, control: RunControl(), progress: progress)
            case "speech": result = try AgentOps.speech(arguments, control: RunControl(), progress: progress)
            case "phone": result = try AgentOps.phone(arguments, control: RunControl(), progress: progress)
            case "sync_files": result = try AgentOps.syncFiles(arguments, control: RunControl(), progress: progress)
            case "guide": result = try Guide.make(arguments["topic"] as? String)
            case "blender_python", "blender_scene", "blender_api", "blender_session", "blender_open", "blender_save",
                 "blender_check", "blender_snapshot", "blender_tools":
                // Runs as a job; the call waits up to `wait` seconds (default 50) and then hands over a job_id, so a long
                // Python step never ends in an MCP "Request timed out" while bigki keeps computing.
                let action = try Self.blenderAction(name, arguments)
                var limit = 50.0
                if let flag = arguments["wait"] as? Bool { limit = flag ? 3500 : 0 }
                else if let seconds = arguments["wait"] as? Double { limit = seconds }
                else if let seconds = arguments["wait"] as? Int { limit = Double(seconds) }
                else if let text = arguments["wait"] as? String { limit = text == "true" ? 3500 : text == "false" ? 0 : Double(text) ?? 50 }
                let job = Job(id: String(UUID().uuidString.prefix(8)).lowercased(), tool: name)
                jobsLock.lock(); jobs[job.id] = job; controls["\(id)"] = (job.control, job.node); jobsLock.unlock()
                defer { jobsLock.lock(); controls["\(id)"] = nil; jobsLock.unlock() }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let value = try AgentOps.blender(action, arguments, control: job.control) { text in job.progress = text }
                        job.result = value; job.state = "fertig"
                    } catch { job.error = error.localizedDescription; job.state = "fehlgeschlagen" }
                }
                let deadline = Date().addingTimeInterval(min(max(limit, 0), 3500))
                var beat = Date()
                while job.state == "läuft" && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                    if Date().timeIntervalSince(beat) > 10 { beat = Date(); progress("läuft noch (\(Int(Date().timeIntervalSince(job.started))) s) …") }
                }
                if job.state == "läuft" {
                    result = ["job_id": job.id, "state": "läuft", "seconds": Int(Date().timeIntervalSince(job.started)),
                              "hint": "Läuft auf bigki weiter (nichts geht verloren). Ergebnis mit get_job job_id=\(job.id) wait=45 abholen – bei Bedarf wiederholen."]
                } else {
                    jobsLock.lock(); jobs[job.id] = nil; jobsLock.unlock()
                    if let error = job.error { throw StudioError.message(error) }
                    result = job.result ?? [:]
                }
            case "blender_look":
                let control = RunControl()
                jobsLock.lock(); controls["\(id)"] = (control, AgentOps.NodeControl()); jobsLock.unlock()
                defer { jobsLock.lock(); controls["\(id)"] = nil; jobsLock.unlock() }
                let value = try AgentOps.blender("look", arguments, control: control, progress: progress)
                var content: [[String: Any]] = [["type": "text", "text": json(value)]]
                if let path = value["image"] as? String, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
                }
                reply(id, ["content": content, "structuredContent": value, "isError": (value["ok"] as? Bool) == false])
                return
            case "create_image", "create_music", "create_speech", "render_music_full", "create_video", "blender_render", "image_to_3d", "figure_3d", "import_model", "llm_chat":
                if (arguments["wait"] as? Bool) == false {
                    let job = Job(id: String(UUID().uuidString.prefix(8)).lowercased(), tool: name)
                    jobsLock.lock(); jobs[job.id] = job; jobsLock.unlock()
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let value = try self.perform(name, arguments, control: job.control, node: job.node) { text in job.progress = text }
                            job.result = value; job.state = "fertig"
                        } catch { job.error = error.localizedDescription; job.state = "fehlgeschlagen" }
                    }
                    result = ["job_id": job.id, "state": "läuft", "hint": "Mit get_job abfragen."]
                } else {
                    let control = RunControl(), node = AgentOps.NodeControl()
                    jobsLock.lock(); controls["\(id)"] = (control, node); jobsLock.unlock()
                    defer { jobsLock.lock(); controls["\(id)"] = nil; jobsLock.unlock() }
                    result = try perform(name, arguments, control: control, node: node, progress: progress)
                }
            default: throw StudioError.message("Unbekanntes Werkzeug \(name).")
            }
            var content: [[String: Any]] = [["type": "text", "text": json(result)]]
            if (arguments["preview"] as? Bool) == true { content += previews(result) }
            // labelled strip of a multi-camera render: always shown to the agent (also when fetched later via get_job)
            else if (arguments["preview"] as? Bool) != false,
                    let sheet = (result["sheet"] as? String) ?? ((result["result"] as? [String: Any])?["sheet"] as? String),
                    let data = try? Data(contentsOf: URL(fileURLWithPath: sheet)) {
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
            }
            // Blender reports Python errors as ok=false with the traceback; mark them so agents notice.
            reply(id, ["content": content, "structuredContent": result, "isError": name.hasPrefix("blender_") && (result["ok"] as? Bool) == false])
        } catch {
            reply(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    }

    private func perform(_ name: String, _ a: [String: Any], control: RunControl, node: AgentOps.NodeControl, progress: @escaping AgentOps.Progress) throws -> [String: Any] {
        switch name {
        case "create_image": return try AgentOps.image(a, control: control, progress: progress)
        case "create_music": return try AgentOps.music(a, control: control, progress: progress)
        case "create_speech": var q = a; q["action"] = "speak"; return try AgentOps.speech(q, control: control, progress: progress)
        case "render_music_full": return try AgentOps.renderFull(a, control: control, progress: progress)
        case "create_video": return try AgentOps.video(a, control: control, progress: progress)
        case "blender_render": return try AgentOps.blender("render", a, control: control, progress: progress)
        case "image_to_3d": return try AgentOps.model3D(a, control: node, progress: progress)
        case "figure_3d": return try AgentOps.figure(a, control: control, progress: progress)
        case "llm_chat": var q = a; q["action"] = "chat"; return try AgentOps.llm(q, control: control, progress: progress)
        default: return try AgentOps.importModel(a, control: node, progress: progress)
        }
    }

    static func blenderAction(_ tool: String, _ a: [String: Any]) throws -> String {
        switch tool {
        case "blender_python": return "python"
        case "blender_scene": return "scene"
        case "blender_api": return "api"
        case "blender_open": return "open"
        case "blender_save": return "save"
        case "blender_check": return "check"
        case "blender_tools": return "tools"
        case "blender_snapshot":
            switch (a["action"] as? String) ?? "save" {
            case "save": return "snapshot"
            case "restore": return "restore"
            case "list": return "snapshots"
            default: throw StudioError.message("action: save, restore oder list.")
            }
        default:
            let action = (a["action"] as? String) ?? "info"
            guard ["info", "new", "sessions", "quit", "reset", "status", "abholen"].contains(action) else { throw StudioError.message("action: info, status, new, sessions, quit, reset oder abholen.") }
            return action
        }
    }

    private func job(_ a: [String: Any]) throws -> [String: Any] {
        if let id = a["job_id"] as? String {
            jobsLock.lock(); let found = jobs[id]; jobsLock.unlock()
            guard let job = found else { throw StudioError.message("Unbekannte job_id.") }
            // wait=true: until finished (max_seconds, default 1500); wait=<n>: n seconds – saves agents from polling
            var limit: Double = 0
            if let flag = a["wait"] as? Bool, flag { limit = Double((a["max_seconds"] as? Int) ?? 1500) }
            else if let seconds = a["wait"] as? Double { limit = seconds }
            else if let seconds = a["wait"] as? Int { limit = Double(seconds) }
            else if let text = a["wait"] as? String { limit = text == "true" ? Double((a["max_seconds"] as? Int) ?? 1500) : Double(text) ?? 0 }
            let deadline = Date().addingTimeInterval(min(max(limit, 0), 3500))
            while job.state == "läuft" && Date() < deadline { Thread.sleep(forTimeInterval: 1) }
            jobsLock.lock(); defer { jobsLock.unlock() }
            var answer = describe(job)
            if job.state == "läuft" && limit > 0 { answer["hint"] = "Läuft noch – get_job erneut mit wait=true." }
            return answer
        }
        jobsLock.lock(); defer { jobsLock.unlock() }
        return ["jobs": jobs.values.sorted { $0.started > $1.started }.map(describe)]
    }

    private func describe(_ job: Job) -> [String: Any] {
        ["job_id": job.id, "tool": job.tool, "state": job.state, "progress": job.progress,
         "seconds": Int(Date().timeIntervalSince(job.started)), "result": job.result as Any, "error": job.error as Any]
    }

    private func json(_ value: [String: Any]) -> String {
        let clean = jsonSafe(value)
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{\"ok\": false, \"error\": \"Antwort ließ sich nicht als JSON darstellen: \(String(describing: value).prefix(2000).replacingOccurrences(of: "\"", with: "'"))\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// NaN/∞ → null and anything else non-JSON → text, so a single odd value never empties the whole answer.
    private func jsonSafe(_ value: Any) -> Any {
        if value is String || value is NSNull { return value }
        if let number = value as? NSNumber {   // also Swift Int/Double/Bool; booleans stay booleans
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : NSNull()
        }
        if let dict = value as? [String: Any] { return dict.mapValues { jsonSafe($0) } }
        if let list = value as? [Any] { return list.map { jsonSafe($0) } }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first.map { jsonSafe($0.value) } ?? NSNull() }
        return String(describing: value)
    }


    /// Small JPEG previews of produced images/models so a vision-capable agent can look at the result.
    private func previews(_ result: [String: Any]) -> [[String: Any]] {
        var paths = result["files"] as? [String] ?? []
        if let preview = result["preview"] as? String { paths.append(preview) }
        return paths.prefix(4).compactMap { path in
            guard let image = ThumbnailCache.image(URL(fileURLWithPath: path), size: 256),
                  let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return nil }
            return ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
        }
    }

    private static let wait: [String: Any] = ["type": "boolean", "description": "true (Standard): warten bis fertig. false: sofort job_id zurückgeben, mit get_job abfragen."]
    private static let preview: [String: Any] = ["type": "boolean", "description": "Kleine Vorschau des Ergebnisses als Bild mitsenden."]
    private static let session: [String: Any] = ["type": "string", "description": "Name der Blender-Sitzung (a–z, 0–9, -), Standard: eine eigene Sitzung je Mac (macbook, mac-mini). Eigene Namen für parallele Arbeiten oder um eine Szene zwischen den Macs zu teilen."]

    static let tools: [[String: Any]] = [
        ["name": "llm_chat", "description": "Lokales Sprachmodell Qwen3.8 Flash Next (Strata, alle drei MI50, ~140 t/s Code, ~90 t/s Deutsch; 160k Kontext). prompt (+ system) oder messages [{role, content}] (Bilder als image_url-Teile). Startet Strata bei Bedarf (~75 s, belegt alle drei Karten – Bild/Video/Musik warten so lange) und stoppt es nach 20 min ohne Anfrage. Antwort mit text, reasoning, reasoning_effort, tokens_per_second, prompt_tokens_per_second, completion_tokens, seconds. reasoning_effort (oder thinking): none (Standard, direkt), low (kurz), medium (mittel), high (tief/xhigh; thinking=true entspricht medium). Lange Antworten mit wait=false und get_job.",
         "inputSchema": ["type": "object", "properties": ["prompt": ["type": "string"], "system": ["type": "string"], "messages": ["type": "array", "items": ["type": "object"]],
                         "reasoning_effort": ["type": "string", "enum": ["none", "low", "medium", "high"]], "thinking": ["type": "boolean"], "max_tokens": ["type": "integer"], "temperature": ["type": "number"], "start": ["type": "boolean", "description": "false = nicht starten, wenn Strata aus ist"], "wait": ["type": "boolean"]]]],
        ["name": "llm", "description": "Strata (lokales LLM) verwalten: action status (läuft?, Leerlauf), start (wartet in der Kartenwarteschlange, dann ~75 s), stop (gibt die drei Karten frei; force=true auch wenn Strata nicht von StudioPortal gestartet wurde).",
         "inputSchema": ["type": "object", "properties": ["action": ["type": "string", "enum": ["status", "start", "stop"]], "force": ["type": "boolean"]]]],
        ["name": "create_speech", "description": "Sprache mit Fish Audio Drama 3 (oder Qwen3-TTS) auf 1× MI50 erzeugen (Streaming + Voice Cloning + Regie-Tags wie [laughs], [sighs], [calm], <|speaker:0|>). Speichert WAV in ~/Music/StudioPortal-Sprache. Built with Fish Audio.",
         "inputSchema": ["type": "object", "properties": ["text": ["type": "string"], "engine": ["type": "string", "enum": ["drama-3", "qwen3-tts"]], "voice_ref": ["type": "string"], "reference_text": ["type": "string"], "temperature": ["type": "number"], "top_p": ["type": "number"], "seed": ["type": "integer"], "speaker": ["type": "string"], "instruct": ["type": "string"], "wait": wait], "required": ["text"]]],
        ["name": "speech", "description": "Sprach-Server (Drama 3 / Qwen3-TTS auf 1× MI50) verwalten: action status, start oder stop.",
         "inputSchema": ["type": "object", "properties": ["action": ["type": "string", "enum": ["status", "start", "stop"]]]]],
        ["name": "phone", "description": "2+1 Telefon-Stack auf bigki verwalten (GPU 0+2: Qwen 3.8 Flash, GPU 1: Drama 3 / Qwen3-TTS, CPU: Nemotron 3.5 ASR + Smart Turn v3.2): action status, start oder stop.",
         "inputSchema": ["type": "object", "properties": ["action": ["type": "string", "enum": ["status", "start", "stop"]]]]],
        ["name": "studioportal_info", "description": "Aufbau von StudioPortal: alle Teile (Macs, App, Tailscale/SSH, bigki-Hardware, MI50-Optimierungen, Linux-Dienste, Worker/Broker, Modelle, Blender-Sitzung, Figuren), Regeln und wie man ändert/ausrollt. Vor Änderungen oder bei Fragen zum System lesen.",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "guide", "description": "Anleitung, wie man eine Funktion gut bedient – dasselbe Wissen wie die ⓘ-Erklärungen der App: Ablauf, Prompt-/Songtext-Vorlage, alle Voreinstellungen mit Werten, jeder Regler (was er tut, was am besten ist), Tipps, Parameter. Vor create_image/create_music/create_video/image_to_3d oder Figuren-Arbeit einmal lesen.",
         "inputSchema": ["type": "object", "properties": ["topic": ["type": "string", "enum": Guide.topics]]]],
        ["name": "status", "description": "Zustand von bigki: drei MI50 (Temperatur, Last, welcher Auftrag), Warteschlange aller Macs und Agenten, Bibliotheksordner.",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "create_image", "description": "Bild mit MiniMax H3 Image erzeugen – vorher guide topic=bild lesen (Q8, alle drei MI50; destilliert: 6 Schritte, CFG 1, euler + H3-Zeitplan sind richtig). Zeiten je Bild: 1 MP ~1¼ min, 4 MP ~2¼ min, 16 MP ~12 min (plus Wartezeit). preset: entwurf (4 MP in ~1¼ min mit Speed-LoRA, 2 Schritte – glatter, anderes Bild als mit 6 Schritten; LoRA nur bis ~4 MP), foto (4 MP 1:1, realistische Haut), portraet (4 MP 3:4, lcm + Rauschplan 1,1→0,9 = natürliche Haut; fürs Endbild megapixels 16), landschaft (4 MP 16:9), maximal (16 MP nativ), bearbeiten (4 MP, Format von Picture 1). Prompt lang und konkret auf Englisch (Kamera, Licht, Haut, Hintergrund); 80–150 Wörter; es gibt keinen Negativ-Prompt bei CFG 1. Der Seed macht viel aus: count 2–4 und das beste nehmen (ein Seed ergibt nur bei gleicher Größe und gleichen Einstellungen dasselbe Bild). Mit references wird ein Bild bearbeitet (<Picture 1> im Prompt, anderer Seed als das Ausgangsbild).",
         "inputSchema": ["type": "object", "properties": [
            "prompt": ["type": "string", "description": "Pflicht, außer mit like"], "count": ["type": "integer", "minimum": 1, "maximum": 4],
            "preset": ["type": "string", "enum": ImagePreset.all.map(\.choice.id)],
            "aspect": ["type": "string", "enum": ImageFormat.aspects.map(\.0)],
            "megapixels": ["type": "number", "description": "1, 2, 4 oder 16 (16 = native Größe)"],
            "sampler": ["type": "string", "description": "euler (Standard) oder lcm"], "scheduler": ["type": "string", "description": "h3 (Standard) oder simple (zu lcm)"],
            "cfg": ["type": "number", "description": "1.0 empfohlen"],
            "width": ["type": "integer"], "height": ["type": "integer"], "seed": ["type": "integer"], "steps": ["type": "integer"],
            "references": ["type": "array", "items": ["type": "string"], "description": "Pfade zu Referenzbildern auf diesem Mac"],
            "speed_lora": ["type": "boolean", "description": "2 Schritte mit Speed-LoRA (bis ~4 MP)"],
            "rng": ["type": "string", "enum": ["cpu", "cuda", "std_default"]],
            "flash_attention": ["type": "boolean"], "vae_tiling": ["type": "boolean"],
            "extra": ["type": "string", "description": "weitere sd-cli-Argumente"],
            "like": ["type": "string", "description": "Pfad eines früheren Ergebnisses: übernimmt alles (= „Übernehmen“ in der App); weitere Parameter überschreiben"], "new_seed": ["type": "boolean", "description": "mit like: neuer Seed (= „Variieren“)"],
            "wait": wait, "preview": preview]]],
        ["name": "create_music", "description": "Song mit MiniMax Music 3 erzeugen – vorher guide topic=musik lesen (Beschreibungs-/Songtext-Vorlage, Voreinstellungen, Regler). Standard: drei Vorschau-Varianten parallel (je eine MI50, ~3 min für 50 s). Danach die beste mit render_music_full in voller Qualität rendern.",
         "inputSchema": ["type": "object", "properties": [
            "caption": ["type": "string", "description": "Pflicht, außer mit like: Global/Vocals/Arrangement (siehe guide topic=musik)"],
            "lyrics": ["type": "string", "description": "Mit Abschnittsmarken [verse], [chorus] …"],
            "instrumental": ["type": "boolean"], "duration": ["type": "number", "minimum": 5, "maximum": 360],
            "variants": ["type": "integer", "minimum": 1, "maximum": 3], "quality": ["type": "string", "enum": ["preview", "full"]],
            "format": ["type": "string", "enum": ["mp3", "wav"]], "seed": ["type": "integer", "description": "Melodie-Seed"],
            "preset": ["type": "string", "enum": MusicPreset.all.map(\.choice.id)], "steps": ["type": "integer", "minimum": 2, "maximum": 100],
            "sound_seed": ["type": "integer", "description": "Klang-Seed (Diffusion)"],
            "lm_cfg": ["type": "number"], "dit_cfg": ["type": "number"], "top_k": ["type": "integer"],
            "like": ["type": "string", "description": "Pfad eines früheren Ergebnisses: übernimmt alles (= „Übernehmen“ in der App); weitere Parameter überschreiben"], "new_seed": ["type": "boolean", "description": "mit like: neue Melodie (= „Variieren“)"],
            "wait": wait]]],
        ["name": "render_music_full", "description": "Bis zu drei Vorschau-Songs in voller Qualität (30 Schritte) neu rendern – derselbe Song, parallel je eine MI50.",
         "inputSchema": ["type": "object", "required": ["files"], "properties": [
            "files": ["type": "array", "items": ["type": "string"], "maxItems": 3, "description": "Pfade der Vorschau-Audiodateien"], "wait": wait]]],
        ["name": "create_video", "description": "Video mit Ton aus Text (MiniMax H3 Turbo4, 24 fps) – vorher guide topic=video lesen. Prompt englisch: Szene, Bewegung, Kamera, Licht, am Ende 'Audio: …' (Geräusche/Musik/Sprache, z. B. 'no music and no speech'). Läuft auf zwei MI50 (~5–7 min für 5 s), die dritte bleibt frei. Ergebnis: MP4 im Video-Ordner. Nur privat nutzen (Lizenz: nicht in der EU veröffentlichen, nicht für Werbung).",
         "inputSchema": ["type": "object", "properties": [
            "prompt": ["type": "string", "description": "Pflicht, außer mit like"], "seconds": ["type": "number", "minimum": 1, "maximum": 10, "description": "Länge, Standard 5"],
            "aspect": ["type": "string", "enum": ["16:9", "9:16", "1:1", "16:9-hd"], "description": "16:9 = 864×480 (Standard, getestet), 16:9-hd = 1280×704 (deutlich langsamer)"],
            "seed": ["type": "integer"], "cards": ["type": "integer", "enum": [2, 3], "description": "3 = experimentell, kaum schneller"],
            "preset": ["type": "string", "enum": VideoPreset.all.map(\.choice.id)],
            "steps": ["type": "integer", "enum": [4, 6, 8], "description": "6 Standard (getestet: deutlich schärfer, 5 s ≈ 8 min), 4 = Entwurf (≈ 5 min, weicher)"],
            "like": ["type": "string", "description": "Pfad eines früheren Ergebnisses: übernimmt alles (= „Übernehmen“ in der App); weitere Parameter überschreiben"], "new_seed": ["type": "boolean", "description": "mit like: neuer Seed (= „Variieren“)"],
            "wait": wait, "preview": preview]]],
        ["name": "blender_scene", "description": "Aktuelle Szene der Blender-Sitzung auf bigki als JSON: Objekte (Typ, Lage, Maße, Material, Modifier), Kamera, Licht, Frames, Render-Einstellungen, fehlende Dateien. Mit object Details zu einem Objekt (Vertices, Materialknoten …). Erster Schritt vor Änderungen.",
         "inputSchema": ["type": "object", "properties": ["object": ["type": "string"], "session": session]]],
        ["name": "blender_python", "description": "Python in der laufenden Blender-Sitzung ausführen (bpy, mathutils, math, np, C = bpy.context, D = bpy.data sind da, dazu figur = Figuren-Bausteine (auch kleid_anlegen/kleid_simulieren), helfer = Kamera/Punkte/Glätten/Remesh und scipy; Variablen bleiben zwischen Aufrufen erhalten, bis die Sitzung neu startet – dann steht ein hinweis in der Antwort). Zurück kommen stdout, alle Zeilen, die mit LOG beginnen (log), der Wert der Variable result und bei Fehlern der Traceback. persist=true hängt den Code nach Erfolg an werkzeuge.py an (wird bei jedem Start geladen) – für eigene Hilfsfunktionen. Headless: keine Viewport-Operatoren, lieber bpy.data-API. Statt langem Code: script = Datei auf diesem Mac oder auf bigki (bigki:~/…); __file__ wird gesetzt und der Skriptordner auf bigki in sys.path aufgenommen. Mit with_dir=true wird der Projekt-/Skriptordner vom Mac vorher inkrementell per SHA-256 nach bigki synchronisiert, sodass lokale Nachbarmodule und Assets (z. B. ../schrift/*.ttf) direkt gefunden werden. Dauert ein Aufruf länger als wait Sekunden (Standard 50), kommt eine job_id zurück und bigki rechnet weiter – Ergebnis mit get_job wait=45 holen (kein „Request timed out“). Die Szene wird nach jedem Aufruf automatisch gespeichert; nach einem Absturz steht im hinweis der Grund und es ist der Stand nach dem letzten erfolgreichen Aufruf geladen. Speichergrenze 40 GB: darüber stoppt sich die Sitzung mit Meldung statt bigki einzufrieren – vor Remesh/Subdivision helfer.groesse_pruefen(obj, voxel=…) (findet Ausreißer, z. B. von Solidify „Even Offset“).",
         "inputSchema": ["type": "object", "properties": ["code": ["type": "string"], "script": ["type": "string", "description": "Python-Datei statt code: Pfad auf diesem Mac oder bigki:~/…"],
                                                         "with_dir": ["type": "boolean", "description": "bei Mac-Skript: Projekt-/Skriptordner vorher per SHA-256 nach bigki synchronisieren"],
                                                         "sync_dir": ["type": "string", "description": "optionaler lokaler Wurzelordner für den Sync vor dem Skriptstart"],
                                                         "dest": ["type": "string", "description": "optionaler Zielordner auf bigki (Standard ~/blender-auftraege/<ordner>)"],
                                                         "timeout": ["type": "integer", "description": "Sekunden, Standard 900"],
                                                         "wait": ["description": "Sekunden bis zur Übergabe als Job (Standard 50), true = bis fertig, false = sofort Job"],
                                                         "persist": ["type": "boolean"], "session": session]]],
        ["name": "sync_files", "description": "Ordner oder einzelne Datei (Skripte, Schriften, Texturen, Assets) inkrementell per SHA-256 vom Mac nach bigki synchronisieren. Es werden nur neue oder geänderte Dateien übertragen; .git, out, vergleiche, __pycache__, .DS_Store, *.pyc und *.blend1/2 werden standardmäßig übersprungen. Standardziel: ~/blender-auftraege/<ordnername>.",
         "inputSchema": ["type": "object", "required": ["source"], "properties": [
            "source": ["type": "string", "description": "Pfad zu Ordner oder Datei auf diesem Mac"],
            "dest": ["type": "string", "description": "Zielordner auf bigki (z. B. ~/blender-auftraege/projekt oder bigki:~/...)"],
            "exclude": ["type": "array", "items": ["type": "string"], "description": "zusätzliche auszulassende Ordner- oder Dateinamen"],
            "delete": ["type": "boolean", "description": "true = auf bigki entfernte Dateien löschen (Standard false)"],
            "max_file_mb": ["type": "integer", "description": "Dateigrößen-Limit pro Datei in MB (Standard 50, max 100)"]]]],
        ["name": "blender_look", "description": "Bild der Szene ansehen (kommt als Bild zurück). mode solid = Workbench (~0,1–1 s je Ansicht, Form/Lage), eevee = Material/Licht (Intel-Grafik), cycles = CPU-Vorschau. views = mehrere Ansichten als ein Raster mit Beschriftung, z. B. \"rund\" (vorne, schräg, rechts, hinten, links, oben), [\"vorne\",\"rechts\"] oder [{\"azimuth\":30,\"elevation\":15}] (azimuth 0 = von vorne/-Y, 90 = von rechts/+X). focus rückt ein Objekt, \"Objekt:Vertexgruppe\" oder \"Armature:Knochen\" formatfüllend ins Bild (z. B. die Hand); target = [x,y,z] Blickpunkt, distance in m. only blendet alles andere aus. color_by färbt ein: material, object, random, teile (lose Teile/Inseln je Mesh, größtes rot – zeigt schwebende Bröckchen), vertex_groups (stärkste Gruppe/Knochen) oder ein Punkt-Attribut – Legende in farben. reference = Vorlagebild (Pfad auf diesem Mac oder bigki:~/…) als erstes Feld daneben. Ohne Kamera wird automatisch gerahmt. Ausschnitt vergrößern: zoom (2–32) um center [x,y] oder region [x0,y0,x1,y1] (Anteile 0–1 von oben links im selben Bild ohne Zoom, gleiche camera/focus/azimuth) – Blender rendert nur diesen Teil in höherer Auflösung (echte Details). Jede Ansicht wird zusätzlich mit sprechendem Namen in Bilder/Blender-Ansichten/<Tag>/ abgelegt (Standard ~/Pictures/H3 Studio/Bilder/Blender-Ansichten/<Tag>/; Pfad in saved), name = eigener Dateiname.",
         "inputSchema": ["type": "object", "properties": [
            "mode": ["type": "string", "enum": ["solid", "eevee", "cycles"]], "size": ["type": "integer", "minimum": 128, "maximum": 2048, "description": "Kantenlänge je Ansicht, Standard 768 (Raster 512)"],
            "views": ["description": "\"rund\", \"vier\", Liste aus vorne/hinten/links/rechts/oben/unten/schräg/schräg-hinten oder {azimuth, elevation, distance, name}"],
            "azimuth": ["type": "number"], "elevation": ["type": "number"], "distance": ["type": "number"],
            "target": ["description": "[x,y,z] oder Objektname als Blickpunkt"], "focus": ["description": "Objekt, \"Objekt:Vertexgruppe\", \"Armature:Knochen\" oder Liste davon"],
            "only": ["type": "array", "items": ["type": "string"], "description": "nur diese Objekte rendern"],
            "color_by": ["type": "string", "description": "material | object | random | teile | vertex_groups | Name eines Punkt-Attributs"],
            "reference": ["type": "string"], "lens": ["type": "number", "description": "Brennweite der Hilfskamera, Standard 50"],
            "columns": ["type": "integer"], "camera": ["type": "string", "description": "Name eines Kamera-Objekts (einzelne Ansicht)"], "frame": ["type": "integer"],
            "overview": ["type": "boolean", "description": "Hilfskamera, die alles zeigt (ignoriert die Szenenkamera)"],
            "samples": ["type": "integer", "description": "eevee (Standard 16) oder cycles (Standard 24)"],
            "zoom": ["type": "number", "description": "Vergrößerung 1–32 um center"], "center": ["type": "array", "items": ["type": "number"], "description": "[x, y] 0–1 von oben links, Standard Mitte"],
            "region": ["type": "array", "items": ["type": "number"], "description": "[x0, y0, x1, y1] 0–1 von oben links"],
            "name": ["type": "string", "description": "Dateiname der abgelegten Ansicht"], "session": session]]],
        ["name": "blender_check", "description": "Prüft Meshes mit Zahlen statt Augenmaß (Ergebnis + warnings mit Koordinaten): lose Teile/Inseln, offene Ränder und nicht-mannigfaltige Kanten, Splitter- und gedehnte Dreiecke, Löcher (Strahl von außen trifft Rückseite), übereinanderliegende Schichten, Boden (schwebt/steckt), Vertices ohne Gewicht bei Armature, offene Ränder als Löcher mit Umfang und Mitte (holes_open). thickness=true misst die Wanddicke (min/p5/median in mm, dünnste Stellen; min_thickness in m warnt). remove_small löscht vorher kleine lose Teile im Mesh selbst (true = unter small_part Anteil, Standard 0,5 %, oder eine Punktzahl; das größte Teil bleibt) – vorher blender_snapshot. pairs/contact misst Abstand, Berührung und Eindringen zwischen zwei Objekten oder Vertexgruppen, z. B. [\"Figur:Hand_R\", \"Handy\"]. Auf dem ausgewerteten Netz (mit Modifiern/Pose). Ohne objects: alle sichtbaren Meshes.",
         "inputSchema": ["type": "object", "properties": [
            "objects": ["type": "array", "items": ["type": "string"]], "contact": ["type": "array", "items": ["type": "string"], "description": "[A, B]"],
            "pairs": ["type": "array", "items": ["type": "array", "items": ["type": "string"]]], "tolerance": ["type": "number", "description": "Berührung bis m, Standard 0.002"],
            "floor": ["type": "boolean", "description": "true = Abstand zum Boden z=0 als Warnung"], "holes": ["type": "boolean"], "layers": ["type": "boolean"],
            "layer_gap": ["type": "number", "description": "Schichtabstand in m, Standard 0,4 % der Größe"], "stretch": ["type": "number", "description": "gedehnt ab x-facher Median-Kante, Standard 12"],
            "thickness": ["type": "boolean", "description": "Wanddicke messen"], "min_thickness": ["type": "number", "description": "Warnung unter dieser Dicke in m, z. B. 0.002"],
            "thickness_samples": ["type": "integer", "description": "Messpunkte, Standard 4000"],
            "remove_small": ["description": "true oder Punktzahl: kleine lose Teile löschen"], "small_part": ["type": "number", "description": "klein = unter diesem Anteil der Punkte, Standard 0.005"],
            "timeout": ["type": "integer"], "wait": ["description": "Sekunden bis zur Übergabe als Job (Standard 50)"], "session": session]]],
        ["name": "blender_snapshot", "description": "Zwischenstände der Sitzung auf bigki: save (name, note) vor riskanten Schritten, list, restore (name; ohne name den letzten). Die letzten 12 bleiben. Nach etwa drei Korrekturrunden wird es oft schlechter – dann zum besten Stand zurück.",
         "inputSchema": ["type": "object", "properties": ["action": ["type": "string", "enum": ["save", "list", "restore"]], "name": ["type": "string"],
                                                          "note": ["type": "string"], "session": session]]],
        ["name": "blender_tools", "description": "Eigene Hilfsfunktionen der Sitzung, werden bei jedem Start und Neustart automatisch geladen. Ganze Skriptdatei laden: script = Pfad auf diesem Mac oder bigki:~/…/datei.py → liegt als werkzeuge/<name>.py in der Sitzung, erneutes Laden ersetzt sie (mode remove + name entfernt sie). Kleine Stücke in werkzeuge.py: show, add (Code anhängen), set (ersetzen), reload, clear.",
         "inputSchema": ["type": "object", "properties": ["mode": ["type": "string", "enum": ["show", "add", "set", "file", "remove", "reload", "clear"]], "code": ["type": "string"],
                                                          "script": ["type": "string", "description": "Python-Datei: Pfad auf diesem Mac oder bigki:~/…"],
                                                          "name": ["type": "string", "description": "Name des Skripts (Standard: Dateiname)"], "session": session]]],
        ["name": "blender_render", "description": "Endgültig rendern mit Cycles auf den MI50 (Warteschlange, Vorrang für Blender des Nutzers). Ein Frame → PNG im Bilder-Ordner; mehrere Frames → MP4 im Video-Ordner (zwei Blender je Karte). cameras = mehrere Kameras in einem Aufruf (je ein PNG <name>-<kamera>.png, parallel auf den Karten) plus eine beschriftete Bildleiste <name>-leiste.jpg, die als Bild zurückkommt. name = Dateiname, folder = Unterordner im Bilder-Ordner (Standard ~/Pictures/H3 Studio/Bilder, siehe status → folders). Ergebnis-JSON enthält Telemetrie (device, cards, denoiser, samples, samples_reached, setup_s, render_s, wait_s, kernel_compiled). EEVEE/Workbench-Szenen rendern ohne GPU-Warteschlange. Reißt die Verbindung ab (Tailscale), rendert bigki weiter und StudioPortal holt das Ergebnis automatisch ab. Für lange Renders wait=false und dann get_job mit wait=true.",
         "inputSchema": ["type": "object", "properties": [
            "frames": ["description": "Zahl, [start, ende] oder \"all\"; Standard: nur der aktuelle Frame, all = ganzer Bereich der Szene"],
            "camera": ["type": "string"], "cameras": ["type": "array", "items": ["type": "string"]],
            "name": ["type": "string"], "folder": ["type": "string"],
            "samples": ["type": "integer"], "noise": ["description": "Adaptive-Sampling-Schwelle, Standard 0.01, oder \"off\""],
            "percentage": ["type": "integer", "minimum": 5, "maximum": 200, "description": "Auflösung in Prozent"],
            "cards": ["type": "integer", "minimum": 1, "maximum": 3], "send_frames": ["type": "boolean", "description": "bei Animationen auch die Einzelbilder holen"],
            "title": ["type": "string", "description": "Titel für die Bibliothek"], "session": session, "wait": wait, "preview": preview]]],
        ["name": "blender_open", "description": "Datei in die Blender-Sitzung laden: file = Datei dieses Macs (bis 100 MB, wird hochgeladen) oder path = Datei, die schon auf bigki liegt (absolut, ~/… oder relativ zum Home, ohne Upload). .blend öffnet (ersetzt die Szene), .glb/.gltf/.fbx/.obj/.stl/.ply/.usd/.abc werden importiert; append=true hängt auch eine .blend an.",
         "inputSchema": ["type": "object", "properties": ["file": ["type": "string"], "path": ["type": "string"], "append": ["type": "boolean"], "session": session]]],
        ["name": "blender_save", "description": "Szene als .blend (Texturen gepackt) in den 3D-Ordner dieses Macs holen (siehe status → folders) – erscheint in der Bibliothek. bigki_path = stattdessen nur auf bigki speichern (Ordner/ oder Datei im Home, Ordner wird angelegt, keine Übertragung – für große Zwischenstände). Vorhandene Dateien werden nur mit overwrite=true ersetzt. Gespeichert mit Blender 5.3.",
         "inputSchema": ["type": "object", "properties": ["filename": ["type": "string"], "bigki_path": ["type": "string"], "overwrite": ["type": "boolean"], "session": session]]],
        ["name": "blender_api", "description": "Blender-Python-API nachschlagen (live aus Blender 5.3): Operator (bpy.ops.mesh.primitive_cube_add), Typ (bpy.types.Object, mit Eigenschaften) oder einzelne Eigenschaft/Funktion (bpy.types.Object.location). Bei Tippfehlern kommen ähnliche Namen.",
         "inputSchema": ["type": "object", "required": ["identifier"], "properties": ["identifier": ["type": "string"], "session": session]]],
        ["name": "blender_session", "description": "Sitzung verwalten: info (Version, Datei, Objekte), new (leere Szene, empty=true ganz ohne Würfel/Kamera/Licht), sessions (alle Sitzungen), status (sofort, ohne zu warten: läuft gerade, Speicher, letzte Aufrufe, letzter Absturz, Autosave), quit (beenden, Zustand bleibt), reset (Zustand löschen), abholen (Ergebnis eines Aufrufs nachträglich holen, dessen Verbindung abgerissen ist – ticket steht in der Fehlermeldung; bigki hält es 12 h).",
         "inputSchema": ["type": "object", "properties": ["action": ["type": "string", "enum": ["info", "status", "new", "sessions", "quit", "reset", "abholen"]],
                                                          "empty": ["type": "boolean"], "ticket": ["type": "string"], "session": session]]],
        ["name": "figure_3d", "description": "Realistische Figur aus EINEM Bild einer Person (Hunyuan3D-Omni mit Skelett-Vorgabe, eine MI50, ~7 min): Ergebnis ist eine Form ohne Textur in A-Pose mit offenen Händen (.glb im 3D-Ordner) – der Start für das Figuren-Rezept in Blender (blender_open append → figur.scan_aufraeumen → figur.mensch als Rig-Quelle + figur.abgleichen + figur.gewichte_uebertragen → posieren). Endposen und Requisiten NICHT hier erzeugen, sondern in Blender posieren. pose: a (Standard), hand-hoch, arme-hoch oder eigene Knochenliste. Lizenz: nur privat, nicht in der EU/UK/Südkorea veröffentlichen.",
         "inputSchema": ["type": "object", "properties": ["image": ["type": "string", "description": "Pfad zum Bild auf diesem Mac (Person möglichst ganz im Bild, Freistellen passiert automatisch)"],
                                                          "pose": ["description": "a | hand-hoch | arme-hoch | [[x1,y1,z1,x2,y2,z2], …]"],
                                                          "steps": ["type": "integer"], "seed": ["type": "integer"], "octree": ["type": "integer", "description": "256 | 384 | 512 (Standard)"],
                                                          "filename": ["type": "string"], "wait": ["type": "boolean"]], "required": ["image"]]],
        ["name": "image_to_3d", "description": "3D-Modell (Hunyuan3D-2mv) aus einer bis vier Ansichten derselben Pose, Ergebnis als .blend. Farben brauchen alle vier Ansichten.",
         "inputSchema": ["type": "object", "required": ["front"], "properties": [
            "front": ["type": "string"], "left": ["type": "string"], "back": ["type": "string"], "right": ["type": "string"],
            "model": ["type": "string", "enum": ["standard", "turbo"]], "resolution": ["type": "integer", "enum": [380, 768, 1024]],
            "color": ["type": "boolean"], "person": ["type": "boolean"], "wait": wait, "preview": preview]]],
        ["name": "import_model", "description": "3D-Modell von einem Link (Sketchfab, Poly Haven, Printables …) oder einer Datei (BLEND, GLB, FBX, OBJ, STL, 3MF, ZIP) als .blend importieren.",
         "inputSchema": ["type": "object", "required": ["source"], "properties": ["source": ["type": "string"], "wait": wait, "preview": preview]]],
        ["name": "compare_images", "description": "Beschriftete Vorher-nachher-Leiste (kommt als Bild zurück, liegt in Bilder/Vergleiche/<Tag>/): 2–8 Bilder nebeneinander, über jedem Titel und Fakten aus der Begleitdatei (Kamera, Auflösung, Samples, Quelldatei, Dauer). regions = gleiche Detailausschnitte aus allen Bildern in voller Auflösung als weitere Zeilen, z. B. [{\"name\":\"Kragen\",\"region\":[0.4,0.1,0.6,0.25]}] (Anteile 0–1 von oben links); die Ausschnitte sind im ganzen Bild gelb markiert. Für Abnahmen von Renders (offene Kanten, Säume, Ärmelansätze sieht blender_check nicht).",
         "inputSchema": ["type": "object", "required": ["images"], "properties": [
            "images": ["type": "array", "items": ["type": "string"], "description": "Pfade auf diesem Mac (z. B. file aus blender_render)"],
            "labels": ["type": "array", "items": ["type": "string"], "description": "eigene Titel je Bild, z. B. [\"vorher\", \"nachher\"]"],
            "regions": ["type": "array", "items": ["type": "object", "properties": ["name": ["type": "string"], "region": ["type": "array", "items": ["type": "number"]]]]],
            "name": ["type": "string", "description": "Dateiname ohne Endung"]]]],
        ["name": "list_library", "description": "Bibliothek durchsuchen (Bilder, Musik, Video, 3D) – auch Einträge vom anderen Mac, wenn Sync an ist.",
         "inputSchema": ["type": "object", "properties": ["kind": ["type": "string", "enum": ["image", "music", "video", "model"]],
                                                          "search": ["type": "string"], "limit": ["type": "integer"]]]],
        ["name": "music_examples", "description": "Offizielle MiniMax-Vorlagen (Beschreibung + Songtext) als Ausgangspunkt.",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "get_job", "description": "Stand eines mit wait=false gestarteten Auftrags (ohne job_id: alle). wait=true wartet, bis er fertig ist (höchstens max_seconds, Standard 1500); wait=Zahl wartet so viele Sekunden. Fertige Blender-Bildleisten kommen als Bild mit.",
         "inputSchema": ["type": "object", "properties": ["job_id": ["type": "string"], "wait": ["description": "true = bis fertig, Zahl = Sekunden"],
                                                          "max_seconds": ["type": "integer", "description": "Obergrenze für wait=true, Standard 1500"]]]],
        ["name": "cancel_job", "description": "Auftrag abbrechen (bigki gibt die Karten sofort frei).",
         "inputSchema": ["type": "object", "required": ["job_id"], "properties": ["job_id": ["type": "string"]]]],
    ]
}

// MARK: - Setup for Claude Code, Codex and Claude Desktop

enum AgentSetup {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let command = home.appendingPathComponent(".local/bin/studioportal")

    static func installCommand() throws {
        let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = "#!/bin/sh\nexec \"\(binary)\" \"$@\"\n"
        try script.write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    }

    static func claudeBinary() -> String? {
        let candidates = [home.appendingPathComponent(".local/bin/claude").path, home.appendingPathComponent(".npm-global/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.appendingPathComponent(".claude/local/claude").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func claudeCodeConfigured() -> Bool {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["mcpServers"] as? [String: Any])?["studioportal"] != nil
    }

    static func installClaudeCode() throws {
        guard let claude = claudeBinary() else { throw StudioError.message("Claude Code (claude) wurde nicht gefunden.") }
        if claudeCodeConfigured() { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["mcp", "add", "--scope", "user", "studioportal", "--", command.path, "mcp"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":" + URL(fileURLWithPath: claude).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StudioError.message("claude mcp add ist fehlgeschlagen.") }
    }

    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    static func codexConfigured() -> Bool { (try? String(contentsOf: codexConfig, encoding: .utf8))?.contains("[mcp_servers.studioportal]") == true }
    static func installCodex() throws {
        if codexConfigured() { return }
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) else { throw StudioError.message("Codex ist auf diesem Mac nicht eingerichtet (~/.codex fehlt).") }
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n[mcp_servers.studioportal]\ncommand = \"\(command.path)\"\nargs = [\"mcp\"]\nstartup_timeout_sec = 20\ntool_timeout_sec = 3600\n"
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    static var desktopConfig: URL { home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }
    static func desktopConfigured() -> Bool {
        guard let data = try? Data(contentsOf: desktopConfig), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["mcpServers"] as? [String: Any])?["studioportal"] != nil
    }
    static func installDesktop() throws {
        if desktopConfigured() { return }
        guard FileManager.default.fileExists(atPath: desktopConfig.deletingLastPathComponent().path) else { throw StudioError.message("Die Claude-App ist auf diesem Mac nicht eingerichtet.") }
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: desktopConfig) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StudioError.message("claude_desktop_config.json ist unlesbar – nicht verändert.") }
            json = existing
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers["studioportal"] = ["command": command.path, "args": ["mcp"]]
        json["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: desktopConfig, options: .atomic)
    }

    static func installAll() -> [String: Any] {
        var result: [String: Any] = [:]
        do { try installCommand(); result["command"] = command.path } catch { result["command"] = "Fehler: \(error.localizedDescription)" }
        for (name, action) in [("claude_code", installClaudeCode), ("codex", installCodex), ("claude_desktop", installDesktop)] as [(String, () throws -> Void)] {
            do { try action(); result[name] = "eingerichtet" } catch { result[name] = error.localizedDescription }
        }
        return result
    }
}
