import Foundation
import AppKit
import AVFoundation

let speechDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/StudioPortal-Sprache", isDirectory: true)
let callsDirectory = speechDirectory.appendingPathComponent("Anrufe", isDirectory: true)

/// Encodes raw signed 16-bit little-endian mono PCM into a standard RIFF WAVE file.
enum WAVCodec {
    static func encodeMono16(pcm: Data, sampleRate: Int) -> Data {
        var out = Data(capacity: 44 + pcm.count)
        func u32(_ v: UInt32) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 2)) }
        out.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + pcm.count))
        out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!)
        u32(16)
        u16(1) // PCM
        u16(1) // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2) // block align
        u16(16) // bits per sample
        out.append("data".data(using: .ascii)!)
        u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }

    /// Reads any macOS-supported audio file (WAV/M4A/MP3/AIFF) and converts it to mono 16-bit WAV Data for voice cloning.
    static func loadReferenceWAV(from url: URL, targetRate: Double = 44100, maxSeconds: Double = 28) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetRate, channels: 1, interleaved: true) else {
            throw StudioError.message("Audioformat konnte nicht erzeugt werden.")
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw StudioError.message("Referenz-Audio konnte nicht konvertiert werden.")
        }
        let maxSrcFrames = AVAudioFrameCount(min(Double(file.length), srcFormat.sampleRate * maxSeconds))
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: maxSrcFrames) else {
            throw StudioError.message("Speicherfehler beim Laden der Referenzstimme.")
        }
        try file.read(into: srcBuffer, frameCount: maxSrcFrames)
        let ratio = targetRate / srcFormat.sampleRate
        let dstCapacity = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio + 1024)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            throw StudioError.message("Speicherfehler bei der Audiokonvertierung.")
        }
        var consumed = false
        var err: NSError?
        converter.convert(to: dstBuffer, error: &err) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true; outStatus.pointee = .haveData; return srcBuffer
        }
        if let err { throw err }
        let byteCount = Int(dstBuffer.frameLength) * 2
        guard let ptr = dstBuffer.int16ChannelData?[0], byteCount > 0 else {
            throw StudioError.message("Die Referenz-Audiodatei enthält keinen hörbaren Ton.")
        }
        return encodeMono16(pcm: Data(bytes: ptr, count: byteCount), sampleRate: Int(targetRate))
    }
}

/// Low-latency streaming PCM16 player built on AVAudioEngine + AVAudioPlayerNode.
/// Supports smooth volume ducking and click-free cosine fade-out for human-like barge-in.
final class StreamingPCMPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var currentRate: Double = 44100
    private var ownsEngine = true
    private var fadeWork: DispatchWorkItem?
    private var queuedFrames: Int64 = 0
    private var playbackStartSampleTime: AVAudioFramePosition?
    private var playingFlag = false
    private var estimatedFinishDate: Date = .distantPast

    var isPlaying: Bool {
        lock.withLock {
            guard playingFlag else { return false }
            if Date() > estimatedFinishDate.addingTimeInterval(0.35) {
                playingFlag = false
                queuedFrames = 0
                return false
            }
            return true
        }
    }

    /// Attach to an external shared AVAudioEngine (used by PhoneCallStudio so Apple VoiceProcessingIO AEC
    /// cancels the AI's own voice from the microphone automatically).
    func attach(to sharedEngine: AVAudioEngine, sampleRate: Double) throws {
        lock.lock(); defer { lock.unlock() }
        stopLocked(resetEngine: true)
        ownsEngine = false
        engine = sharedEngine
        currentRate = sampleRate
        let node = AVAudioPlayerNode()
        sharedEngine.attach(node)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        sharedEngine.connect(node, to: sharedEngine.mainMixerNode, format: format)
        player = node
    }

    private func ensureStandaloneEngineLocked(sampleRate: Double) throws {
        if let eng = engine, let node = player, ownsEngine, abs(currentRate - sampleRate) < 1 {
            if !eng.isRunning { try eng.start() }
            if !node.isPlaying { node.play() }
            return
        }
        stopLocked(resetEngine: true)
        ownsEngine = true
        currentRate = sampleRate
        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        eng.connect(node, to: eng.mainMixerNode, format: format)
        try eng.start()
        node.volume = 1.0
        node.play()
        engine = eng
        player = node
    }

    func appendPCM16(_ pcmData: Data, sampleRate: Double, onComplete: (() -> Void)? = nil) {
        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { onComplete?(); return }
        lock.lock()
        do {
            if ownsEngine {
                try ensureStandaloneEngineLocked(sampleRate: sampleRate)
            } else if let eng = engine, let node = player {
                if abs(currentRate - sampleRate) >= 1 {
                    eng.disconnectNodeOutput(node)
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
                    eng.connect(node, to: eng.mainMixerNode, format: format)
                    currentRate = sampleRate
                }
                if !eng.isRunning { try? eng.start() }
                if !node.isPlaying { node.volume = 1.0; node.play() }
            }
        } catch {
            lock.unlock()
            onComplete?()
            return
        }
        guard let node = player else { lock.unlock(); onComplete?(); return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: currentRate, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.floatChannelData?[0] else {
            lock.unlock(); onComplete?(); return
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pcmData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let scale: Float = 1.0 / 32768.0
            for i in 0..<sampleCount { dst[i] = Float(src[i]) * scale }
        }
        let now = Date()
        let chunkSec = Double(sampleCount) / max(currentRate, 1)
        if !playingFlag || estimatedFinishDate < now {
            playingFlag = true
            estimatedFinishDate = now.addingTimeInterval(chunkSec)
            playbackStartSampleTime = node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0)?.sampleTime }
        } else {
            estimatedFinishDate = estimatedFinishDate.addingTimeInterval(chunkSec)
        }
        queuedFrames += Int64(sampleCount)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferFinished(frames: Int64(sampleCount))
            onComplete?()
        }
        lock.unlock()
    }

    private func bufferFinished(frames: Int64) {
        lock.lock()
        queuedFrames = max(0, queuedFrames - frames)
        if queuedFrames == 0 { playingFlag = false }
        lock.unlock()
    }

    /// Approximate seconds of audio that have actually reached the speakers so far.
    var playedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard let node = player, let render = node.lastRenderTime, let pt = node.playerTime(forNodeTime: render) else { return 0 }
        let start = playbackStartSampleTime ?? 0
        return max(0, Double(pt.sampleTime - start) / max(currentRate, 1))
    }

    /// Smoothly lower speaker gain (used when the listener makes a short sound like "Mhm" or starts interrupting).
    func duck(to target: Float = 0.22, durationMs: Int = 40) {
        rampVolume(to: target, durationMs: durationMs, stopAtEnd: false)
    }

    /// Smoothly restore full speaker gain (when the short sound was just a backchannel like "Mhm").
    func unduck(durationMs: Int = 40) {
        rampVolume(to: 1.0, durationMs: durationMs, stopAtEnd: false)
    }

    /// Click-free cosine fade-out followed by immediate buffer flush (used on confirmed barge-in).
    func fadeOutAndStop(durationMs: Int = 65, completion: (() -> Void)? = nil) {
        rampVolume(to: 0.0, durationMs: durationMs, stopAtEnd: true, completion: completion)
    }

    private func rampVolume(to target: Float, durationMs: Int, stopAtEnd: Bool, completion: (() -> Void)? = nil) {
        lock.lock()
        fadeWork?.cancel()
        guard let node = player else {
            lock.unlock()
            completion?()
            return
        }
        let startVol = node.volume
        let steps = max(4, durationMs / 6)
        let interval = Double(durationMs) / 1000.0 / Double(steps)
        let work = DispatchWorkItem { [weak self] in
            for i in 1...steps {
                guard let self else { return }
                let t = Float(i) / Float(steps)
                let eased = 0.5 - 0.5 * cos(t * .pi)
                let vol = startVol + (target - startVol) * eased
                self.lock.lock()
                self.player?.volume = vol
                self.lock.unlock()
                Thread.sleep(forTimeInterval: interval)
            }
            if stopAtEnd {
                self?.stop(resetEngine: false)
            }
            completion?()
        }
        fadeWork = work
        lock.unlock()
        DispatchQueue.global(qos: .userInteractive).async(execute: work)
    }

    func stop(resetEngine: Bool = false) {
        lock.lock()
        stopLocked(resetEngine: resetEngine)
        lock.unlock()
    }

    private func stopLocked(resetEngine: Bool) {
        fadeWork?.cancel(); fadeWork = nil
        player?.stop()
        player?.reset()
        player?.volume = 1.0
        queuedFrames = 0
        playbackStartSampleTime = nil
        estimatedFinishDate = .distantPast
        playingFlag = false
        if resetEngine {
            if ownsEngine {
                engine?.stop()
                engine = nil
                player = nil
            } else if let eng = engine, let node = player {
                eng.detach(node)
                player = nil
                engine = nil
            }
        }
    }
}

struct SpeechSettings: Codable, Equatable {
    var text = ""
    var engine = "drama-3"       // "drama-3" | "qwen3-tts"
    var livePlay = true
    var temperature = 1.0
    var topP = 0.9
    var topK = 4097
    var maxTokens = 1024
    var textChunkSize = 128
    var seed: Int64 = Int64.random(in: 0...Int64(Int32.max))
    var seedLocked = false
    var voiceRefPath: String? = nil
    var referenceText = ""
    var speaker = "Ryan"         // Qwen3-TTS CustomVoice preset
    var instruct = ""            // Qwen3-TTS style instruction
}

struct SpeechClip: Identifiable, Equatable {
    var url: URL
    var date: Date
    var text: String
    var engine: String
    var duration: Double?
    var ttfaMs: Double?
    var rtf: Double?
    var seed: Int64?
    var referenceName: String?
    var origin: String?
    var id: String { url.path }
    var metaURL: URL { url.deletingPathExtension().appendingPathExtension("json") }
    var title: String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? url.deletingPathExtension().lastPathComponent : String(clean.prefix(72)) + (clean.count > 72 ? "…" : "")
    }

    static func load(_ url: URL) -> SpeechClip {
        let data = (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let date = (data["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let dur = (data["duration_s"] as? NSNumber)?.doubleValue ?? Song.length(url, date: date)
        return SpeechClip(
            url: url, date: date, text: data["text"] as? String ?? "",
            engine: data["engine"] as? String ?? "drama-3",
            duration: dur,
            ttfaMs: (data["ttfa_ms"] as? NSNumber)?.doubleValue,
            rtf: (data["rtf"] as? NSNumber)?.doubleValue,
            seed: (data["seed"] as? NSNumber)?.int64Value,
            referenceName: data["reference_name"] as? String,
            origin: data["origin"] as? String
        )
    }
}

struct SpeechServerState: Equatable {
    var running = false
    var starting = false
    var card: Int? = nil
    var engines: [String] = []
    var drama3Available = false
    var qwen3Available = false
    var model: String? = nil
    var idleSeconds: Int? = nil
    var autoStopMinutes: Int? = nil
}

enum SpeechRemote {
    static func status() throws -> SpeechServerState {
        let r = try call("status")
        return parseState(r)
    }

    static func start(control: RunControl? = nil, progress: ((String) -> Void)? = nil) throws -> SpeechServerState {
        parseState(try call("start", control: control, progress: progress))
    }

    static func stop() throws -> SpeechServerState {
        parseState(try call("stop"))
    }

    static func parseState(_ r: [String: Any]) -> SpeechServerState {
        SpeechServerState(
            running: r["running"] as? Bool ?? false,
            starting: r["starting"] as? Bool ?? false,
            card: r["card"] as? Int,
            engines: r["engines"] as? [String] ?? [],
            drama3Available: r["drama3_available"] as? Bool ?? false,
            qwen3Available: r["qwen3_tts_available"] as? Bool ?? false,
            model: r["model"] as? String,
            idleSeconds: r["idle_seconds"] as? Int,
            autoStopMinutes: r["auto_stop_minutes"] as? Int
        )
    }

    static func call(_ action: String, _ extra: [String: Any] = [:], control: RunControl? = nil,
                     onAudioChunk: ((Data, Int) -> Void)? = nil,
                     progress: ((String) -> Void)? = nil) throws -> [String: Any] {
        var req = extra
        req["operation"] = "speech"; req["action"] = action
        var result: [String: Any]?, remoteError: String?
        try runWorker(req, control: control, patient: true) { event in
            switch event["type"] as? String {
            case "status", "waiting":
                if let msg = event["message"] as? String { progress?(msg) }
            case "audio_chunk":
                if let b64 = event["pcm_b64"] as? String, let pcm = Data(base64Encoded: b64) {
                    let sr = event["sample_rate"] as? Int ?? 44100
                    onAudioChunk?(pcm, sr)
                }
            case "result":
                result = event["result"] as? [String: Any]
            case "error":
                remoteError = event["message"] as? String ?? "bigki meldet einen Fehler."
            default: break
            }
        }
        if let remoteError { throw StudioError.message(remoteError) }
        guard let result else { throw StudioError.message("Die Verbindung zu bigki wurde unterbrochen.") }
        return result
    }

    /// Synthesizes text into a saved WAV + JSON sidecar in ~/Music/StudioPortal-Sprache, streaming PCM live via `onChunk`.
    static func speak(_ settings: SpeechSettings, control: RunControl,
                      onChunk: ((Data, Int) -> Void)? = nil,
                      progress: ((String) -> Void)? = nil) throws -> (url: URL, info: [String: Any]) {
        let trimmed = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StudioError.message("Bitte gib einen Text zum Sprechen ein.") }
        var extra: [String: Any] = [
            "text": trimmed,
            "engine": settings.engine,
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "top_k": settings.topK,
            "max_tokens": settings.maxTokens,
            "text_chunk_size": settings.textChunkSize,
            "seed": settings.seed,
            "speaker": settings.speaker,
            "instruct": settings.instruct,
        ]
        var refName: String? = nil
        if let refPath = settings.voiceRefPath, !refPath.isEmpty {
            let refURL = URL(fileURLWithPath: refPath)
            let wav = try WAVCodec.loadReferenceWAV(from: refURL)
            extra["voice_ref_b64"] = wav.base64EncodedString()
            if !settings.referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extra["reference_text"] = settings.referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            refName = refURL.lastPathComponent
        }
        var collected = Data()
        var sampleRate = settings.engine == "qwen3-tts" ? 24000 : 44100
        let res = try call("speak", extra, control: control, onAudioChunk: { pcm, sr in
            sampleRate = sr
            collected.append(pcm)
            onChunk?(pcm, sr)
        }, progress: progress)
        guard !collected.isEmpty else { throw StudioError.message("Es wurden keine Audiodaten empfangen.") }
        try FileManager.default.createDirectory(at: speechDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let baseName = "sprache-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased())"
        let wavURL = speechDirectory.appendingPathComponent(baseName + ".wav")
        let wavData = WAVCodec.encodeMono16(pcm: collected, sampleRate: sampleRate)
        try wavData.write(to: wavURL, options: .atomic)
        var meta: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "text": trimmed,
            "engine": settings.engine,
            "sample_rate": sampleRate,
            "duration_s": (res["duration_s"] as? NSNumber)?.doubleValue ?? (Double(collected.count / 2) / Double(sampleRate)),
            "ttfa_ms": res["ttfa_ms"] as Any,
            "total_ms": res["total_ms"] as Any,
            "rtf": res["rtf"] as Any,
            "seed": settings.seed,
            "origin": requestOrigin,
        ]
        if let refName { meta["reference_name"] = refName }
        if let json = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: wavURL.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        }
        return (wavURL, res)
    }
}

@MainActor
final class SpeechStudio: ObservableObject {
    @Published var settings = SpeechSettings()
    @Published var server = SpeechServerState()
    @Published var clips: [SpeechClip] = []
    @Published var selected: SpeechClip? = nil
    @Published var running = false
    @Published var statusText = ""
    @Published var liveTTFAMs: Double? = nil
    @Published var errorMessage: String? = nil
    @Published var playingURL: URL? = nil
    @Published var isPlayingClip = false
    var onFinish: (() -> Void)?

    private var control: RunControl?
    private let streamer = StreamingPCMPlayer()
    private var clipPlayer: AVAudioPlayer?
    private var pollTimer: Timer?

    static let starters: [(title: String, note: String, text: String)] = [
        ("Akquise · Hotel", "Freundlicher, natürlicher Einstieg",
         "Grüß Sie Frau Weber, hier ist Lukas aus München. Mir ist gerade aufgefallen, dass auf der Website vom Hotel Alpenblick das Buchungsformular auf dem Handy abgeschnitten wird – haben Sie dreißig Sekunden?"),
        ("Ausdruck & Lachen", "Mit Drama-3 Regie-Tags",
         "[calm] Guten Morgen! [laughs] Entschuldigen Sie, mein Kaffee wirkt gerade erst. Ich wollte Ihnen kurz zeigen, wie wir Ihre Website in zwei Tagen wieder blitzschnell machen."),
        ("Zwei Sprecher", "Dialog mit <|speaker:0|> & <|speaker:1|>",
         "<|speaker:0|> Hotel Alpenblick, Weber am Apparat, guten Tag. <|speaker:1|> Grüß Sie Frau Weber, ich rufe kurz wegen Ihrer Website an – auf dem Smartphone klemmt dort gerade der Buchen-Knopf."),
        ("Flüstern & Spannung", "Hörspiel / Drama-3 Stärke",
         "[whisper] Hört man mich noch? [sighs] Gut. Die neue Seite steht morgen früh pünktlich um acht live."),
    ]

    init() { refresh() }

    func refresh(select url: URL? = nil) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: speechDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let loaded = urls.filter { $0.pathExtension.lowercased() == "wav" }.map(SpeechClip.load).sorted { $0.date > $1.date }
        clips = loaded
        if let url, let found = loaded.first(where: { $0.url == url }) { selected = found }
        else if let sel = selected, !loaded.contains(where: { $0.url == sel.url }) { selected = nil }
    }

    func refreshServer() {
        Task.detached(priority: .utility) {
            if let s = try? SpeechRemote.status() {
                await MainActor.run { self.server = s }
            }
        }
    }

    func startServer() {
        guard !running else { return }
        running = true; statusText = "Starte Fish Audio Drama 3 auf 1× MI50 …"; errorMessage = nil
        let ctrl = RunControl(); control = ctrl
        Task.detached(priority: .userInitiated) {
            do {
                let s = try SpeechRemote.start(control: ctrl) { msg in
                    Task { @MainActor in self.statusText = msg }
                }
                await MainActor.run { self.server = s; self.running = false; self.statusText = "" }
            } catch {
                await MainActor.run { self.running = false; self.statusText = ""; self.errorMessage = error.localizedDescription }
            }
        }
    }

    func stopServer() {
        streamer.stop(resetEngine: true)
        Task.detached(priority: .userInitiated) {
            let s = (try? SpeechRemote.stop()) ?? SpeechServerState()
            await MainActor.run { self.server = s }
        }
    }

    func speak() {
        guard !running else { return }
        if !settings.seedLocked { settings.seed = Int64.random(in: 0...Int64(Int32.max)) }
        stopPlayback()
        running = true; statusText = "Verbinde mit bigki …"; liveTTFAMs = nil; errorMessage = nil
        let current = settings
        let ctrl = RunControl(); control = ctrl
        let t0 = Date()
        var gotFirst = false
        Task.detached(priority: .userInitiated) {
            do {
                let (url, _) = try SpeechRemote.speak(current, control: ctrl, onChunk: { pcm, sr in
                    if !gotFirst {
                        gotFirst = true
                        let ms = Date().timeIntervalSince(t0) * 1000
                        Task { @MainActor in self.liveTTFAMs = ms; self.statusText = "Spielt live ab …" }
                    }
                    if current.livePlay {
                        self.streamer.appendPCM16(pcm, sampleRate: Double(sr))
                    }
                }, progress: { msg in
                    Task { @MainActor in self.statusText = msg }
                })
                await MainActor.run {
                    self.running = false; self.statusText = ""
                    self.refresh(select: url)
                    self.refreshServer()
                    self.onFinish?()
                    Notifier.finished("Sprache fertig", current.text.prefix(60).description)
                }
            } catch {
                self.streamer.fadeOutAndStop(durationMs: 40)
                await MainActor.run {
                    self.running = false; self.statusText = ""
                    if !ctrl.isCancelled() { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    func cancel() {
        control?.cancel()
        streamer.fadeOutAndStop(durationMs: 40)
        running = false; statusText = ""
    }

    func togglePlay(_ clip: SpeechClip) {
        if playingURL == clip.url, let p = clipPlayer {
            if p.isPlaying { p.pause(); isPlayingClip = false }
            else { p.play(); isPlayingClip = true }
            return
        }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: clip.url)
            p.prepareToPlay()
            p.play()
            clipPlayer = p; playingURL = clip.url; isPlayingClip = true
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.clipPlayer?.isPlaying != true {
                        self.isPlayingClip = false
                        self.pollTimer?.invalidate()
                    }
                }
            }
        } catch {
            errorMessage = "Audio konnte nicht abgespielt werden: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        clipPlayer?.stop(); clipPlayer = nil
        playingURL = nil; isPlayingClip = false
        pollTimer?.invalidate(); pollTimer = nil
        streamer.stop(resetEngine: false)
    }

    func useSettings(_ clip: SpeechClip) {
        settings.text = clip.text
        settings.engine = clip.engine
        if let seed = clip.seed { settings.seed = seed; settings.seedLocked = true }
    }

    func reveal(_ clip: SpeechClip) {
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }

    func trash(_ clip: SpeechClip) {
        if playingURL == clip.url { stopPlayback() }
        try? trashLibraryFiles([clip.url, clip.metaURL])
        if selected?.url == clip.url { selected = nil }
        refresh()
    }
}
