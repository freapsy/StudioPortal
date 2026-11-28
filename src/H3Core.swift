import Foundation

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

struct Reference: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
}

struct Settings: Codable, Equatable {
    var mode = "Neu"
    var prompt = ""
    var references: [Reference] = []
    var width = 1024
    var height = 1024
    var seed: Int64 = Int64.random(in: 0...Int64(Int32.max))
    var seedLocked = false
    var count = 1
    var steps = 6
    var cfg = 1.0
    var sampler = "euler"
    var scheduler = ""
    var rng = "cpu"
    var flashAttention = true
    var vaeTiling = true
    var extra = ""
    /// pDMD 2-step distillation LoRA (Apache-2.0, akhaliq/minimax-h3-image-pdmd-2step) – optional so old saved settings still decode
    var speedLora: Bool? = nil

    static let speedLoraName = "pdmd2fix"
    static let loraDirectory = "/home/bigki/.local/share/3d-modelle-app/loras"
    var usesSpeedLora: Bool { speedLora == true }
    /// prompt as sent to sd-cli: with the LoRA tag in front when the speed LoRA is on
    var workerPrompt: String { usesSpeedLora ? "<lora:\(Settings.speedLoraName):1> " + prompt : prompt }

    mutating func setSpeedLora(_ on: Bool) {
        speedLora = on ? true : nil
        if on { steps = 2; sampler = "euler"; scheduler = "simple"; cfg = 1 } else { steps = 6; scheduler = "" }
    }

    static let samplers = ["euler", "euler_a", "heun", "dpm2", "dpm++2s_a", "dpm++2m", "dpm++2mv2", "ipndm", "ipndm_v", "lcm", "ddim_trailing", "tcd", "res_multistep", "res_2s", "er_sde", "euler_cfg_pp", "euler_a_cfg_pp", "euler_ge", "dpm++2m_sde", "dpm++2m_sde_bt", "lms"]
    static let schedulers = ["discrete", "karras", "exponential", "ays", "gits", "sgm_uniform", "simple", "smoothstep", "kl_optimal", "lcm", "bong_tangent", "ltx2", "logit_normal", "flux2", "flux", "beta", "llada_image"]
    static let rngs = ["cpu", "std_default", "cuda"]

    mutating func normalizeSize() {
        width = max(32, min(8192, ((width + 31) / 32) * 32))
        height = max(32, min(8192, ((height + 31) / 32) * 32))
    }

    /// sd-cli options without the prompt and without reference paths; the bigki worker adds `-r` for the uploaded references.
    func options(referenceCount: Int) throws -> [String] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.message("Bitte gib eine Bildbeschreibung ein.") }
        guard !prompt.utf8.contains(0) else { throw StudioError.message("Die Beschreibung darf kein Nullzeichen enthalten.") }
        guard (1...4).contains(count), steps > 0, width >= 32, height >= 32, width % 32 == 0, height % 32 == 0, cfg.isFinite, cfg >= 0 else { throw StudioError.message("Bitte prüfe Größe, Anzahl, Schritte und CFG.") }
        if mode == "Bearbeiten" && !(1...16).contains(referenceCount) { throw StudioError.message("Bitte wähle ein bis 16 Referenzbilder.") }
        if usesSpeedLora && width * height > 5_000_000 {
            // tested 17.11.2026: at 16 MP the 2-step LoRA gives mosaic/speckle artefacts on skin and hair
            throw StudioError.message("Die Speed-LoRA taugt nur bis etwa 4 MP – bei 16 MP entstehen Mosaik-Artefakte. Bitte kleiner wählen oder die Speed-LoRA ausschalten.")
        }
        let more = try splitArguments(extra)
        if cfg > 1.0 && !more.contains(where: { $0 == "-n" || $0 == "--negative-prompt" || $0.hasPrefix("--negative-prompt=") }) {
            // sd-cli fails with "failed to encode negative prompt" when CFG > 1 has no negative prompt (tested 17.11.2026)
            throw StudioError.message("CFG über 1 braucht einen Negativ-Prompt (unter „Weitere sd-cli-Argumente“, z. B. -n 'blurry, plastic skin'). Empfohlen ist CFG 1 – im Test machte CFG 2 das Bild doppelt so langsam und überzeichnet.")
        }
        // Output and reference paths are managed by StudioPortal and the bigki worker.
        let forbidden = ["-o", "--output", "--preview", "--preview-path", "--imat-out", "-r", "--ref-image"]
        guard !more.contains(where: { value in forbidden.contains(where: { value == $0 || value.hasPrefix($0 + "=") }) || ((value.hasPrefix("-o") || value.hasPrefix("-r")) && !value.hasPrefix("--")) }) else {
            throw StudioError.message("Ausgabe- und Referenzpfade werden von StudioPortal verwaltet und können nicht als Zusatzargument gesetzt werden.")
        }
        var args = ["-W", "\(width)", "-H", "\(height)", "--seed", "\(seed)", "--batch-count", "\(count)", "--cfg-scale", String(cfg), "--sampling-method", sampler, "--rng", rng]
        // An explicit --steps disables the script's H3 sigma profile, even at six.
        if steps != 6 { args += ["--steps", "\(steps)"] }
        if !scheduler.isEmpty { args += ["--scheduler", scheduler] }
        if !flashAttention { args += ["--flash-attn", "off"] }
        // the LoRA was distilled with shift 12 (euler/simple, 2 steps); tested on bigki 17.11.2026
        if usesSpeedLora { args += ["--flow-shift", "12", "--lora-model-dir", Settings.loraDirectory] }
        args += more
        return args
    }
}

func splitArguments(_ input: String) throws -> [String] {
    var result: [String] = [], current = ""
    var quote: Character?, escape = false, started = false
    for char in input {
        if escape { current.append(char); escape = false; started = true; continue }
        if char == "\\" && quote != "'" { escape = true; started = true; continue }
        if let q = quote {
            if char == q { quote = nil } else { current.append(char) }
        } else if char == "'" || char == "\"" { quote = char; started = true }
        else if char.isWhitespace {
            if started { result.append(current); current = ""; started = false }
        } else { current.append(char); started = true }
    }
    guard !escape, quote == nil else { throw StudioError.message("Die Zusatzargumente enthalten ein offenes Anführungszeichen oder einen einzelnen Backslash.") }
    if started { result.append(current) }
    guard !result.contains(where: { $0.utf8.contains(0) }) else { throw StudioError.message("Zusatzargumente dürfen kein Nullzeichen enthalten.") }
    return result
}

func uniqueName(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "h3-\(formatter.string(from: date))-\(UUID().uuidString.lowercased())"
}

struct RunMetadata: Codable {
    var settings: Settings
    var date: Date
    var durationSeconds: Double
    var outputName: String
    var actualSeed: Int64?
    var origin: String?
}

struct LogParser {
    var phase = "Verbinden"
    var waiting: String?
    var step: Int?
    var total: Int?
    var imageIndex: Int?
    var imageTotal: Int?
    var names: [String] = []
    var seeds: [Int64] = []
    var message: String?

    mutating func consume(_ line: String) {
        waiting = nil
        let lower = line.lowercased()
        if lower.contains("blender is active") || (lower.contains("stopping inference for other gpu processes") && lower.contains("blender")) { message = "Blender läuft. Die Bildberechnung wurde zum Schutz des Renderjobs beendet." }
        else if lower.contains("gpu lock busy") || lower.contains("gpu processes are active") || lower.contains(" is in use; wait") || lower.contains("stopping inference for other gpu processes") { message = "Die GPUs sind durch einen anderen Auftrag belegt. Bitte später erneut versuchen." }
        else if lower.contains("unsafe hotspot") { message = "Die Berechnung wurde wegen einer zu hohen Hotspot-Temperatur oder eines Sensorfehlers abgebrochen (Grenze: 92 °C)." }
        else if lower.contains("cannot verify all three") || lower.contains("cannot read") { message = "Die Temperaturen der drei GPUs konnten nicht sicher geprüft werden." }
        else if lower.contains("cannot check gpu processes") { message = "Die GPU-Belegung konnte nicht sicher geprüft werden." }
        if lower.contains("started ") || lower.contains("conditioner.hpp") { phase = "Textencoder" }
        if lower.contains("generating image:") {
            phase = "Rechnen"; step = nil; total = nil
            imageIndex = match(line, #"generating image:\s*(\d+)/(\d+)"#, 1).flatMap(Int.init)
            imageTotal = match(line, #"generating image:\s*(\d+)/(\d+)"#, 2).flatMap(Int.init)
            if let value = match(line, #"- seed\s+(-?\d+)"#, 1).flatMap(Int64.init) { seeds.append(value) }
        }
        if let current = match(line, #"\|\s*(\d+)/(\d+)\s*-\s*[\d.]+\s*(?:s/it|it/s)"#, 1).flatMap(Int.init), let count = match(line, #"\|\s*(\d+)/(\d+)\s*-\s*[\d.]+\s*(?:s/it|it/s)"#, 2).flatMap(Int.init) {
            // VAE tiling prints its own k/N bar after "decoding"; keep the VAE phase for it.
            if phase != "VAE" { phase = "Rechnen" }
            step = current; total = count
        }
        if lower.contains("decoding ") && lower.contains("latent") { phase = "VAE"; step = nil; total = nil }
        if let path = match(line, #"save result image \d+ to '([^']+\.png)' \(success\)"#, 1), !names.contains(path) { names.append(path) }
    }
}

func match(_ text: String, _ pattern: String, _ group: Int) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let found = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), group < found.numberOfRanges, let range = Range(found.range(at: group), in: text) else { return nil }
    return String(text[range])
}

// Keep explicit custom folders and migrate the old external SSD preference to the internal default.
let studioRoot: URL = {
    let key = "studioRoot"
    if let saved = UserDefaults.standard.string(forKey: key), !saved.hasPrefix("/Volumes/stori/") {
        return URL(fileURLWithPath: saved, isDirectory: true)
    }
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/H3 Studio").path
    UserDefaults.standard.set(path, forKey: key)
    return URL(fileURLWithPath: path, isDirectory: true)
}()
let picturesDirectory = studioRoot.appendingPathComponent("Bilder", isDirectory: true)

func requireStori() throws {
    guard studioRoot.path.hasPrefix("/Volumes/stori/") else { return }
    guard FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil)?.contains(where: { $0.standardizedFileURL.path == "/Volumes/stori" }) == true else {
        throw StudioError.message("Die SSD Stori ist nicht eingebunden. Bitte verbinde sie, bevor du Bilder speicherst.")
    }
}

func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    return encoder
}
func jsonDecoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
