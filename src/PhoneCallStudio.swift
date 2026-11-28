import Foundation
import AppKit
import AVFoundation

enum DramaVoicePreset: String, CaseIterable, Identifiable {
    case laura = "laura"
    case lukas = "lukas"
    case jonas = "jonas"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .laura: return "Laura · Warm & Souverän (Empfohlen)"
        case .lukas: return "Lukas · Warm & Locker"
        case .jonas: return "Jonas · Tief & Ruhig"
        }
    }
    var defaultName: String {
        switch self {
        case .laura: return "Laura"
        case .lukas: return "Lukas"
        case .jonas: return "Jonas"
        }
    }
    var styleTag: String { "[calm, warm]" }
}

struct CallScenario: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var callerName: String
    var agencyName: String
    var targetCompany: String
    var contactHint: String
    var websiteIssue: String
    var goal: String
    var formalSie: Bool
    var customInstructions: String

    static let presets: [CallScenario] = [
        CallScenario(
            id: "hotel-buchung",
            title: "Hotel · Handy-Buchungsfehler",
            callerName: "Laura",
            agencyName: "Studio Nordweb",
            targetCompany: "Hotel Alpenblick",
            contactHint: "Rezeption oder Hotelleitung",
            websiteIssue: "Auf dem Smartphone ist der Buchen-Knopf im Buchungsformular halb abgeschnitten und die Seite lädt über 6 Sekunden – viele Gäste brechen mobil ab oder buchen teurer über Booking.com.",
            goal: "Locker und ohne Druck anbieten, kurz einen kostenlosen 2-Minuten-Video-Check vom Fehler an deren E-Mail zu schicken oder 10 Minuten mit der zuständigen Person zu sprechen.",
            formalSie: true,
            customInstructions: ""
        ),
        CallScenario(
            id: "restaurant-speisekarte",
            title: "Restaurant · PDF & kein SSL",
            callerName: "Laura",
            agencyName: "Studio Nordweb",
            targetCompany: "Gasthof Zur Post",
            contactHint: "Inhaber oder Serviceleitung",
            websiteIssue: "Die Website zeigt im Browser „Nicht sicher“ an und die Speisekarte ist ein riesiges PDF, das man auf dem Handy kaum zoomen kann – die Telefonnummer ist auch nicht direkt anklickbar.",
            goal: "Kurz darauf aufmerksam machen und locker anbieten, einen 2-Minuten-Video-Check oder modernen Entwurf per Mail zu schicken.",
            formalSie: true,
            customInstructions: ""
        ),
        CallScenario(
            id: "firma-veraltet",
            title: "Handwerk / Firma · Veraltete Seite",
            callerName: "Lukas",
            agencyName: "Studio Nordweb",
            targetCompany: "Meisterbetrieb Brenner",
            contactHint: "Geschäftsführung oder Büro",
            websiteIssue: "Die Website funktioniert auf dem Handy nicht richtig, Kontaktformular liefert eine Fehlermeldung und bei Google fehlen Öffnungszeiten und klare Leistungsseiten.",
            goal: "Kurz darauf hinweisen und einen kostenlosen 2-Minuten-Video-Check oder kurzes 10-Minuten-Gespräch anbieten.",
            formalSie: true,
            customInstructions: ""
        ),
    ]

    func buildSystemPrompt(dramaTags: Bool) -> String {
        let anrede = formalSie
            ? "Sieze konsequent („Sie“, „Ihnen“, „Ihre Seite“ – niemals „du“ oder „euch“)"
            : "Duze freundlich und locker"
        var lines = [
            "Du bist \(callerName) von \(agencyName) in einem echten deutschen Telefonat auf Augenhöhe mit „\(targetCompany)“ (\(contactHint)).",
            "Konkreter Anlass: \(websiteIssue)",
            "Ziel: \(goal)",
            "Anrede: \(anrede). Verwende KEIN „Herr“ oder „Frau“ beim Namen – begrüße immer direkt und sympathisch mit „Grüß Sie“ oder „Guten Tag“!",
            "TOP-VERTRIEBSREGELN (IMMER EINHALTEN):",
            "- Maximal 1–2 kurze, natürliche gesprochene Sätze wie ein entspannter Kollege – kein Skript, kein Markdown, keine Klammern. Nutze natürliche Sprache („hab“, „geht's“, „kurz“).",
            "- VERBOTEN: niemals „Haben Sie einen Moment Zeit?“, „Störe ich gerade?“, „Optimierung“, „Lösung“, „Synergien“, „ganz unverbindlich“ oder aufdringlicher Verkäuferton.",
            "- Einstieg: Ruhig, kollegial, sofort zum konkreten Website-Fehler kommen und kurz fragen, ob das schon bekannt ist.",
            "- Einwand „Keine Zeit“: Sofort Recht geben, null Druck, in einem Satz den kurzen Screenshot/Video-Check per Mail anbieten.",
            "- Einwand „Schon eine Agentur“: Bestätigen („Super, umso besser“), anbieten den kurzen Clip für deren Agentur zu mailen.",
            "- Einwand „Kein Interesse“: Druck rausnehmen („Ich will Ihnen gar nichts verkaufen“), nur freundlich auf den konkreten Schaden/Verlust hinweisen.",
            "- Preisfrage („Was kostet sowas?“): NIEMALS kalt einen hohen Eurobetrag nennen! Kurz sagen, dass es vom Umfang abhängt (nur Fehler fixen vs. modernisieren) und der kurze Video-Check erst mal null Euro kostet, dann nach der Mail fragen.",
            "- Nach „[unterbrochen]“: nichts wiederholen, direkt aufs Gegenüber eingehen.",
        ]
        let extra = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append("Hinweis: \(extra)") }
        return lines.joined(separator: "\n")
    }
}

struct PhoneServerState: Equatable {
    var ready = false
    var starting = false
    var llmRunning = false
    var ttsRunning = false
    var cpuAudioRunning = false
    var engines: [String] = []
    var drama3Available = false
    var qwen3Available = false
    var sttAvailable = false
    var smartTurnAvailable = false
}

struct CallMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    var role: String          // "user" | "assistant"
    var text: String
    var timestamp = Date()
    var interrupted = false
    var sttMs: Double? = nil
    var turnMs: Double? = nil
    var llmMs: Double? = nil
    var ttsMs: Double? = nil
    var firstAudioMs: Double? = nil
}

struct SavedCall: Identifiable, Equatable {
    var url: URL
    var date: Date
    var title: String
    var messageCount: Int
    var audioURL: URL?
    var id: String { url.path }
}

enum PhoneRemote {
    static func parseState(_ r: [String: Any]) -> PhoneServerState {
        PhoneServerState(
            ready: r["ready"] as? Bool ?? false,
            starting: r["starting"] as? Bool ?? false,
            llmRunning: r["llm_running"] as? Bool ?? false,
            ttsRunning: r["tts_running"] as? Bool ?? false,
            cpuAudioRunning: r["cpu_audio_running"] as? Bool ?? false,
            engines: r["engines"] as? [String] ?? [],
            drama3Available: r["drama3_available"] as? Bool ?? false,
            qwen3Available: r["qwen3_tts_available"] as? Bool ?? false,
            sttAvailable: r["stt_available"] as? Bool ?? false,
            smartTurnAvailable: r["smart_turn_available"] as? Bool ?? false
        )
    }

    static func call(_ action: String, _ extra: [String: Any] = [:], control: RunControl? = nil,
                     onTranscript: ((String, Double?, Double?) -> Void)? = nil,
                     onToken: ((String) -> Void)? = nil,
                     onAudioChunk: ((Data, Int, String) -> Void)? = nil,
                     progress: ((String) -> Void)? = nil) throws -> [String: Any] {
        var req = extra
        req["operation"] = "phone"; req["action"] = action
        var result: [String: Any]?, remoteError: String?
        try runWorker(req, control: control, patient: true) { event in
            switch event["type"] as? String {
            case "status", "waiting":
                if let msg = event["message"] as? String { progress?(msg) }
            case "transcript":
                if let text = event["text"] as? String {
                    let sttMs = (event["stt_ms"] as? NSNumber)?.doubleValue
                    let turnMs = (event["turn_ms"] as? NSNumber)?.doubleValue
                    onTranscript?(text, sttMs, turnMs)
                }
            case "token":
                if let text = event["text"] as? String { onToken?(text) }
            case "audio_chunk":
                if let b64 = event["pcm_b64"] as? String, let pcm = Data(base64Encoded: b64) {
                    let sr = event["sample_rate"] as? Int ?? 44100
                    let sent = event["sentence"] as? String ?? ""
                    onAudioChunk?(pcm, sr, sent)
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
}

/// Persistent bidirectional JSONL SSH session (`operation: phone, action: session`) kept open across a call.
/// Eliminates ~250 ms SSH handshake + Python startup per turn and enables instant (<5 ms) barge-in cancellation.
final class PhoneSessionClient {
    private final class Pending {
        let onTranscript: ((String, Double?, Double?) -> Void)?
        let onToken: ((String) -> Void)?
        let onAudioChunk: ((Data, Int, String) -> Void)?
        let onStatus: ((String) -> Void)?
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        var error: Error?
        var cancelled = false
        init(onTranscript: ((String, Double?, Double?) -> Void)?,
             onToken: ((String) -> Void)?,
             onAudioChunk: ((Data, Int, String) -> Void)?,
             onStatus: ((String) -> Void)?) {
            self.onTranscript = onTranscript
            self.onToken = onToken
            self.onAudioChunk = onAudioChunk
            self.onStatus = onStatus
        }
    }

    private let lock = NSLock()
    private let writeLock = NSLock()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var alive = false
    private let readySem = DispatchSemaphore(value: 0)
    private var readySignalled = false

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return alive && (process?.isRunning ?? false)
    }

    func open() throws {
        guard portalAccessConfigured else {
            throw StudioError.message("Die Verbindung zu bigki ist auf diesem Mac noch nicht eingerichtet.")
        }
        let proc = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = portalSSHArguments.map { $0 == "ServerAliveCountMax=3" ? "ServerAliveCountMax=12" : $0 }
        proc.standardOutput = output; proc.standardError = errors; proc.standardInput = input
        try proc.run()

        lock.lock()
        process = proc
        inputHandle = input.fileHandleForWriting
        alive = true
        lock.unlock()

        // Drain stderr quietly so pipe never blocks
        DispatchQueue.global(qos: .utility).async {
            _ = errors.fileHandleForReading.readDataToEndOfFile()
        }

        // Send initial handshake to enter persistent phone session loop
        let initReq: [String: Any] = ["operation": "phone", "action": "session", "origin": requestOrigin]
        try writeJSON(initReq)

        // Background stdout JSONL dispatcher
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buf = Data()
            while let chunk = try? output.fileHandleForReading.read(upToCount: 262_144), !chunk.isEmpty {
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 10) {
                    let raw = buf[buf.startIndex..<nl]
                    buf.removeSubrange(buf.startIndex...nl)
                    guard let event = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
                    self?.dispatch(event)
                }
            }
            self?.handleDisconnect()
        }

        // Wait up to 8 s for session_ready
        _ = readySem.wait(timeout: .now() + 8)
        guard isAlive else { throw StudioError.message("Telefon-Sitzung konnte nicht geöffnet werden.") }
    }

    private func writeJSON(_ dict: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: dict)
        data.append(10)
        writeLock.lock(); defer { writeLock.unlock() }
        guard let h = inputHandle else { throw StudioError.message("Telefon-Sitzung geschlossen.") }
        try h.write(contentsOf: data)
    }

    private func dispatch(_ event: [String: Any]) {
        guard let kind = event["type"] as? String else { return }
        if kind == "session_ready" {
            lock.lock()
            let shouldSignal = !readySignalled
            readySignalled = true
            lock.unlock()
            if shouldSignal { readySem.signal() }
            return
        }
        guard let id = (event["id"] as? NSNumber)?.intValue else { return }
        lock.lock()
        let entry = pending[id]
        lock.unlock()
        guard let entry else { return }

        switch kind {
        case "status", "waiting":
            if let msg = event["message"] as? String { entry.onStatus?(msg) }
        case "transcript":
            if !entry.cancelled, let text = event["text"] as? String {
                let sttMs = (event["stt_ms"] as? NSNumber)?.doubleValue
                let turnMs = (event["turn_ms"] as? NSNumber)?.doubleValue
                entry.onTranscript?(text, sttMs, turnMs)
            }
        case "token":
            if !entry.cancelled, let text = event["text"] as? String { entry.onToken?(text) }
        case "audio_chunk":
            if !entry.cancelled, let b64 = event["pcm_b64"] as? String, let pcm = Data(base64Encoded: b64) {
                let sr = event["sample_rate"] as? Int ?? 44100
                let sent = event["sentence"] as? String ?? ""
                entry.onAudioChunk?(pcm, sr, sent)
            }
        case "session_result":
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            entry.result = event["result"] as? [String: Any] ?? [:]
            entry.sem.signal()
        case "session_cancelled":
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            entry.error = StudioError.message("Abgebrochen.")
            entry.sem.signal()
        case "session_error":
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            entry.error = StudioError.message(event["message"] as? String ?? "bigki meldet einen Fehler.")
            entry.sem.signal()
        default: break
        }
    }

    private func handleDisconnect() {
        lock.lock()
        alive = false
        let items = Array(pending.values)
        pending.removeAll()
        let shouldSignal = !readySignalled
        readySignalled = true
        lock.unlock()
        if shouldSignal { readySem.signal() }
        for item in items {
            item.error = StudioError.message("Telefon-Sitzung getrennt.")
            item.sem.signal()
        }
    }

    func allocateId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId; nextId += 1
        return id
    }

    func call(_ cmd: String, id: Int? = nil, _ extra: [String: Any] = [:],
              onTranscript: ((String, Double?, Double?) -> Void)? = nil,
              onToken: ((String) -> Void)? = nil,
              onAudioChunk: ((Data, Int, String) -> Void)? = nil,
              progress: ((String) -> Void)? = nil) throws -> [String: Any] {
        guard isAlive else { throw StudioError.message("Telefon-Sitzung nicht aktiv.") }
        let reqId = id ?? allocateId()
        let entry = Pending(onTranscript: onTranscript, onToken: onToken, onAudioChunk: onAudioChunk, onStatus: progress)
        lock.lock(); pending[reqId] = entry; lock.unlock()
        var payload = extra
        payload["id"] = reqId
        payload["cmd"] = cmd
        do {
            try writeJSON(payload)
        } catch {
            lock.lock(); pending.removeValue(forKey: reqId); lock.unlock()
            throw error
        }
        entry.sem.wait()
        if let err = entry.error { throw err }
        return entry.result ?? [:]
    }

    func cancel(id: Int? = nil) {
        lock.lock()
        if let id, let e = pending[id] { e.cancelled = true }
        else if id == nil { for e in pending.values { e.cancelled = true } }
        lock.unlock()
        var payload: [String: Any] = ["cmd": "cancel"]
        if let id { payload["id"] = id }
        try? writeJSON(payload)
    }

    func close() {
        try? writeJSON(["cmd": "quit"])
        writeLock.lock()
        try? inputHandle?.close()
        inputHandle = nil
        writeLock.unlock()
        lock.lock()
        let p = process
        process = nil
        alive = false
        lock.unlock()
        if let p, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { if p.isRunning { p.terminate() } }
        }
    }
}

@MainActor
final class PhoneCallStudio: ObservableObject {
    enum CallPhase: String {
        case idle = "Bereit"
        case startingStack = "Starte 2+1 Stack …"
        case listening = "Hört zu"
        case checkingTurn = "Prüft Satzende …"
        case thinking = "Denkt …"
        case speaking = "Spricht"
        case ducked = "Lauscht (Barge-In)"
    }

    @Published var server = PhoneServerState()
    @Published var scenario: CallScenario = CallScenario.presets[0]
    @Published var ttsEngine = "drama-3"          // "drama-3" | "qwen3-tts"
    @Published var voicePreset: DramaVoicePreset = .laura {
        didSet {
            let defaults = Set(DramaVoicePreset.allCases.map(\.defaultName))
            if defaults.contains(scenario.callerName) {
                scenario.callerName = voicePreset.defaultName
            }
        }
    }
    @Published var qwenSpeaker = "Ryan"
    @Published var qwenInstruct = "Freundlich, ruhig, natürlich am Telefon auf Deutsch."
    @Published var voiceRefPath: String? = nil
    @Published var referenceText = ""
    @Published var callActive = false
    @Published var muted = false
    @Published var phase: CallPhase = .idle
    @Published var statusMessage = ""
    @Published var micLevel: Float = 0
    @Published var messages: [CallMessage] = []
    @Published var draftText = ""
    @Published var savedCalls: [SavedCall] = []
    @Published var errorMessage: String? = nil
    @Published var aecEnabled = false
    @Published var seed: Int64 = 1337
    @Published var ttsTemperature = 0.76

    // Audio & Pipeline state
    private var audioEngine: AVAudioEngine?
    private let pcmPlayer = StreamingPCMPlayer()
    private var startControl: RunControl?
    private var turnControl: RunControl?
    private var activeSession: PhoneSessionClient?
    private var activeTurnReqId: Int?
    private var listenInFlight = false
    private var voiceRefCacheB64: String? = nil
    private var voiceRefCachePath: String? = nil

    // VAD & Barge-In state (accessed from audio tap queue via lock)
    private let audioLock = NSLock()
    private var noiseFloor: Float = 0.008
    private var preRoll = Data()              // 300 ms rolling ring buffer (16 kHz * 2 bytes * 0.3s = 9600 B)
    private var speechBuffer = Data()
    private var bargeInBuffer = Data()
    private var isCapturingSpeech = false
    private var speechMs: Double = 0
    private var silenceMs: Double = 0
    private var bargeSpeechMs: Double = 0
    private var bargeSilenceMs: Double = 0
    private var isDucked = false
    private var turnCheckCooldownUntil = Date.distantPast
    private var activeAssistantTotalAudioSec: Double = 0
    private var activeAssistantMessageId: UUID? = nil
    private var recordedAIPCM = Data()
    private var recordedSampleRate = 44100
    private var callStartedAt = Date()
    private var replayPlayer: AVAudioPlayer?
    private var warmedAnchor: (systemPrompt: String, userAnchor: String, assistantReply: String)? = nil

    init() { refreshSavedCalls() }

    func refreshServer() {
        Task.detached(priority: .utility) {
            if let r = try? PhoneRemote.call("status") {
                let st = PhoneRemote.parseState(r)
                await MainActor.run {
                    self.server = st
                    if !st.drama3Available && st.qwen3Available { self.ttsEngine = "qwen3-tts" }
                }
            }
        }
    }

    func startStack(thenStartCall: Bool = false) {
        guard phase != .startingStack else { return }
        phase = .startingStack
        statusMessage = "Starte 2+1 Telefon-Stack auf bigki (~65 s) …"
        errorMessage = nil
        let ctrl = RunControl(); startControl = ctrl
        Task.detached(priority: .userInitiated) {
            do {
                let r = try PhoneRemote.call("start", control: ctrl, progress: { msg in
                    Task { @MainActor in self.statusMessage = msg }
                })
                let st = PhoneRemote.parseState(r)
                await MainActor.run {
                    self.server = st
                    self.phase = .idle
                    self.statusMessage = ""
                    if !st.drama3Available && st.qwen3Available { self.ttsEngine = "qwen3-tts" }
                    if thenStartCall { self.beginCall() }
                }
            } catch {
                await MainActor.run {
                    self.phase = .idle; self.statusMessage = ""
                    if !ctrl.isCancelled() { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    func stopStack() {
        if callActive { endCall(save: true) }
        startControl?.cancel()
        Task.detached(priority: .userInitiated) {
            let r = (try? PhoneRemote.call("stop")) ?? [:]
            let st = PhoneRemote.parseState(r)
            await MainActor.run { self.server = st; self.phase = .idle; self.statusMessage = "" }
        }
    }

    func beginCall() {
        errorMessage = nil
        if !server.ready {
            startStack(thenStartCall: true)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.errorMessage = "Kein Mikrofonzugriff. Bitte unter Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon für StudioPortal erlauben."
                    return
                }
                do {
                    try self.setupVoiceAudioEngine()
                    self.messages = []
                    self.recordedAIPCM = Data()
                    self.callStartedAt = Date()
                    self.callActive = true
                    self.phase = .listening
                    self.statusMessage = "Leitung steht – geh ran (z. B. „\(self.scenario.targetCompany), guten Tag!“)"
                    self.resetVADState()
                    self.openSessionAndPrewarm()
                } catch {
                    self.errorMessage = "Audio-Engine konnte nicht gestartet werden: \(error.localizedDescription)"
                }
            }
        }
    }

    func endCall(save: Bool = true) {
        if let rid = activeTurnReqId { activeSession?.cancel(id: rid); activeTurnReqId = nil }
        turnControl?.cancel(); turnControl = nil
        activeSession?.close(); activeSession = nil
        warmedAnchor = nil
        listenInFlight = false
        pcmPlayer.fadeOutAndStop(durationMs: 40)
        teardownAudioEngine()
        let hadMessages = !messages.isEmpty
        callActive = false
        phase = .idle
        statusMessage = ""
        micLevel = 0
        if save && hadMessages { saveCurrentCall() }
    }

    /// Lets the AI initiate immediately (e.g. if you want it to greet right away without speaking first).
    func aiSpeakFirst() {
        guard callActive else { return }
        sendTurn(userText: "(Telefon klingelt – Gesprächspartner nimmt ab und sagt kurz „Hallo?“)", appendUserBubble: false)
    }

    /// Manual text input during a call (great for testing objections without a mic or in quiet rooms).
    func sendTypedUtterance() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draftText = ""
        if !callActive {
            if !server.ready { errorMessage = "Bitte zuerst den 2+1 Telefon-Stack starten."; return }
            callActive = true
            callStartedAt = Date()
            recordedAIPCM = Data()
        }
        // If AI is currently speaking, treat typed text as a clean barge-in!
        if phase == .speaking || phase == .ducked || phase == .thinking {
            performConfirmedBargeIn(keepUserBuffer: false)
        }
        sendTurn(userText: text, appendUserBubble: true)
    }

    private func setupVoiceAudioEngine() throws {
        do {
            try startAudioEngine(enableAEC: true)
        } catch {
            // Fallback cleanly without VoiceProcessingIO if an audio device refuses AEC (-10875)
            try startAudioEngine(enableAEC: false)
        }
    }

    private func startAudioEngine(enableAEC: Bool) throws {
        teardownAudioEngine()
        let eng = AVAudioEngine()
        let _ = eng.mainMixerNode
        let input = eng.inputNode
        var vpOn = false
        if enableAEC {
            do {
                try input.setVoiceProcessingEnabled(true)
                vpOn = true
            } catch {
                vpOn = false
            }
        }
        let sr: Double = ttsEngine == "qwen3-tts" ? 24000 : 44100
        try pcmPlayer.attach(to: eng, sampleRate: sr)
        let inFormat = input.outputFormat(forBus: 0)
        if inFormat.channelCount > 0 && inFormat.sampleRate > 0 {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer)
            }
        }
        eng.prepare()
        do {
            try eng.start()
        } catch {
            if inFormat.channelCount > 0 && inFormat.sampleRate > 0 {
                input.removeTap(onBus: 0)
            }
            pcmPlayer.stop(resetEngine: true)
            eng.stop()
            throw error
        }
        aecEnabled = vpOn
        audioEngine = eng
    }

    private func teardownAudioEngine() {
        if let eng = audioEngine {
            eng.inputNode.removeTap(onBus: 0)
            pcmPlayer.stop(resetEngine: true)
            eng.stop()
            audioEngine = nil
        }
        aecEnabled = false
    }

    private func resetVADState() {
        audioLock.lock()
        preRoll.removeAll(keepingCapacity: true)
        speechBuffer.removeAll(keepingCapacity: true)
        bargeInBuffer.removeAll(keepingCapacity: true)
        isCapturingSpeech = false
        speechMs = 0; silenceMs = 0
        bargeSpeechMs = 0; bargeSilenceMs = 0
        isDucked = false
        audioLock.unlock()
    }

    /// Extracts channel 0 (VoiceProcessingIO AEC mono output on macOS, even when the tap reports 3 channels)
    /// and resamples cleanly to 16 kHz mono signed 16-bit PCM for VAD, Smart Turn, and Nemotron ASR.
    private nonisolated func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        let srcFrames = Int(buffer.frameLength)
        let srcRate = buffer.format.sampleRate
        guard srcFrames > 0, srcRate > 0, let ch0 = buffer.floatChannelData?[0] else { return }

        let ratio = srcRate / 16000.0
        let outFrames = max(1, Int(Double(srcFrames) / ratio))
        var pcm = [Int16](repeating: 0, count: outFrames)
        var sumSq: Double = 0
        let win = max(1, Int(ratio.rounded()))

        for i in 0..<outFrames {
            let start = min(srcFrames - 1, Int(Double(i) * ratio))
            let end = min(srcFrames, start + win)
            var acc: Float = 0
            for j in start..<end { acc += ch0[j] }
            let sample = acc / Float(max(1, end - start))
            let clamped = max(-1.0, min(1.0, sample))
            pcm[i] = Int16(clamped * 32767.0)
            sumSq += Double(clamped) * Double(clamped)
        }

        let rms = Float(sqrt(sumSq / Double(outFrames)))
        let frameMs = Double(outFrames) / 16.0
        let pcmChunk = pcm.withUnsafeBytes { Data($0) }

        Task { @MainActor [weak self] in
            guard let self, self.callActive else { return }
            self.micLevel = self.muted ? 0 : min(1.0, rms * 6.5)
            if self.muted { return }
            self.processVADFrame(pcmChunk: pcmChunk, rms: rms, frameMs: frameMs)
        }
    }

    private func processVADFrame(pcmChunk: Data, rms: Float, frameMs: Double) {
        audioLock.lock()
        // Update rolling 300 ms pre-roll
        preRoll.append(pcmChunk)
        if preRoll.count > 9600 { preRoll.removeFirst(preRoll.count - 9600) }

        let speakingNow = (phase == .speaking || phase == .ducked) && pcmPlayer.isPlaying
        let thresh: Float = speakingNow ? max(0.030, noiseFloor * 3.5) : max(0.018, noiseFloor * 2.6)
        let isVoice = rms >= thresh
        if !isVoice && !speakingNow {
            noiseFloor = noiseFloor * 0.96 + rms * 0.04
            noiseFloor = min(0.035, max(0.004, noiseFloor))
        } else if !speakingNow && isCapturingSpeech && speechMs > 3000 && rms < 0.04 {
            // Gently adapt upward if steady room/fan noise hovers just over threshold so VAD never locks on for 18s
            noiseFloor = noiseFloor * 0.992 + rms * 0.008
            noiseFloor = min(0.035, max(0.004, noiseFloor))
        }

        // Case A: AI is speaking -> Soft Ducking + Backchannel Filter + Cosine Fade-Out Barge-In
        if speakingNow {
            if isVoice {
                bargeSpeechMs += frameMs
                bargeSilenceMs = 0
                if bargeInBuffer.isEmpty { bargeInBuffer.append(preRoll) }
                bargeInBuffer.append(pcmChunk)
                if !isDucked && bargeSpeechMs >= 65 {
                    isDucked = true
                    audioLock.unlock()
                    pcmPlayer.duck(to: 0.22, durationMs: 40)
                    phase = .ducked
                    statusMessage = "Lauscht (mögliche Unterbrechung) …"
                    return
                }
                if bargeSpeechMs >= 220 {
                    audioLock.unlock()
                    performConfirmedBargeIn(keepUserBuffer: true)
                    return
                }
            } else if isDucked {
                bargeSilenceMs += frameMs
                bargeInBuffer.append(pcmChunk)
                if bargeSilenceMs >= 180 {
                    // Short backchannel ("Mhm", "Ja", cough) -> unduck smoothly!
                    isDucked = false; bargeSpeechMs = 0; bargeSilenceMs = 0
                    bargeInBuffer.removeAll(keepingCapacity: true)
                    audioLock.unlock()
                    pcmPlayer.unduck(durationMs: 45)
                    phase = .speaking
                    statusMessage = "Spricht …"
                    return
                }
            } else {
                bargeSpeechMs = max(0, bargeSpeechMs - frameMs)
                if bargeSpeechMs == 0 { bargeInBuffer.removeAll(keepingCapacity: true) }
            }
            audioLock.unlock()
            return
        }

        // Case B: Listening for user speech
        guard phase == .listening || phase == .checkingTurn else {
            audioLock.unlock()
            return
        }
        if isVoice {
            if !isCapturingSpeech {
                isCapturingSpeech = true
                speechBuffer = preRoll
                speechMs = 0
            }
            speechBuffer.append(pcmChunk)
            speechMs += frameMs
            silenceMs = 0
            audioLock.unlock()
            return
        }

        if isCapturingSpeech {
            speechBuffer.append(pcmChunk)
            silenceMs += frameMs
            // Cap max single utterance to 12 seconds; NEVER bypass !listenInFlight!
            let maxReached = speechBuffer.count >= 16000 * 2 * 12
            let readyForCheck = !listenInFlight && ((speechMs >= 240 && silenceMs >= 280 && Date() >= turnCheckCooldownUntil) || maxReached)
            if readyForCheck {
                let snapshot = speechBuffer
                let currentSilence = silenceMs
                let forceFinal = currentSilence >= 900 || maxReached
                if forceFinal {
                    speechBuffer.removeAll(keepingCapacity: true)
                    isCapturingSpeech = false
                    speechMs = 0
                    silenceMs = 0
                }
                audioLock.unlock()
                evaluateCapturedSpeech(pcm16k: snapshot, forceFinal: forceFinal)
                return
            }
        }
        audioLock.unlock()
    }

    private func performConfirmedBargeIn(keepUserBuffer: Bool) {
        let played = pcmPlayer.playedSeconds
        let total = max(activeAssistantTotalAudioSec, 0.4)
        let frac = min(1.0, max(0.08, played / total))
        if let rid = activeTurnReqId { activeSession?.cancel(id: rid); activeTurnReqId = nil }
        turnControl?.cancel(); turnControl = nil
        listenInFlight = false
        pcmPlayer.fadeOutAndStop(durationMs: 65)

        // Truncate the AI's last message in history so Qwen knows the exact cutoff point
        if let msgId = activeAssistantMessageId, let idx = messages.firstIndex(where: { $0.id == msgId }) {
            let full = messages[idx].text
            if !full.isEmpty && frac < 0.92 {
                let words = full.split(separator: " ")
                let keptCount = max(2, Int((Double(words.count) * frac).rounded()))
                let cut = words.prefix(keptCount).joined(separator: " ")
                messages[idx].text = cut + " … [unterbrochen]"
                messages[idx].interrupted = true
            }
        }
        activeAssistantMessageId = nil

        audioLock.lock()
        isDucked = false; bargeSpeechMs = 0; bargeSilenceMs = 0
        if keepUserBuffer && !bargeInBuffer.isEmpty {
            speechBuffer = bargeInBuffer
            isCapturingSpeech = true
            speechMs = Double(speechBuffer.count / 2) / 16.0
            silenceMs = 0
        } else {
            speechBuffer.removeAll(keepingCapacity: true)
            isCapturingSpeech = false; speechMs = 0; silenceMs = 0
        }
        bargeInBuffer.removeAll(keepingCapacity: true)
        audioLock.unlock()
        phase = .listening
        statusMessage = "Unterbrochen – hört zu …"
    }

    /// Opens ONE persistent SSH `phone/session` for the entire call (0 ms SSH/Python startup per turn)
    /// and immediately pre-warms Strata's KV prefix cache with the call's system prompt + anchor turn.
    private func openSessionAndPrewarm() {
        activeSession?.close()
        activeSession = nil
        warmedAnchor = nil
        let sysPrompt = scenario.buildSystemPrompt(dramaTags: ttsEngine == "drama-3")
        let anchorUser = "(Leitung steht, gleich meldet sich das Gegenüber.)"
        let sess = PhoneSessionClient()
        Task.detached(priority: .userInitiated) {
            var opened = false
            if (try? sess.open()) != nil {
                opened = true
                await MainActor.run {
                    if self.callActive { self.activeSession = sess } else { sess.close() }
                }
            }
            let warmArgs: [String: Any] = [
                "messages": [
                    ["role": "system", "content": sysPrompt],
                    ["role": "user", "content": anchorUser],
                ],
            ]
            let res: [String: Any]?
            if opened && sess.isAlive {
                res = try? sess.call("warmup", warmArgs)
            } else {
                res = try? PhoneRemote.call("warmup", warmArgs)
            }
            if let res, res["warmed"] as? Bool == true {
                let reply = (res["warmup_reply"] as? String) ?? ""
                if !reply.isEmpty {
                    await MainActor.run {
                        guard self.callActive else { return }
                        self.warmedAnchor = (sysPrompt, anchorUser, reply)
                    }
                }
            }
        }
    }

    private func buildAPIMessages() -> [[String: Any]] {
        let sysPrompt = scenario.buildSystemPrompt(dramaTags: ttsEngine == "drama-3")
        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": sysPrompt]
        ]
        if let anchor = warmedAnchor, anchor.systemPrompt == sysPrompt {
            apiMessages.append(["role": "user", "content": anchor.userAnchor])
            apiMessages.append(["role": "assistant", "content": anchor.assistantReply])
        }
        for m in messages.suffix(24) {
            if !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                apiMessages.append(["role": m.role, "content": m.text])
            }
        }
        return apiMessages
    }

    /// Single-hop voice turn: sends captured 16 kHz audio + conversation history in ONE SSH call to bigki
    /// (Smart Turn -> Nemotron ASR -> transcript event -> 2-card Strata [reasoning OFF] -> cached-voice Drama 3 stream).
    private func evaluateCapturedSpeech(pcm16k: Data, forceFinal: Bool) {
        listenInFlight = true
        phase = .checkingTurn
        let wavData = WAVCodec.encodeMono16(pcm: pcm16k, sampleRate: 16000)
        let b64 = wavData.base64EncodedString()
        let apiMessages = buildAPIMessages()
        let engineName = ttsEngine
        let presetKey = voicePreset.rawValue
        let styleTag = voicePreset.styleTag
        let speakerName = qwenSpeaker
        let instructText = qwenInstruct
        let refB64 = engineName == "drama-3" ? resolvedVoiceRefB64() : nil
        let refTxt = referenceText
        let curSeed = seed
        let curTemp = ttsTemperature
        let ctrl = RunControl(); turnControl = ctrl
        let turnAssistantId = UUID()
        let sess = activeSession
        let reqId = sess?.isAlive == true ? sess?.allocateId() : nil
        activeTurnReqId = reqId

        Task.detached(priority: .userInitiated) {
            do {
                var extra: [String: Any] = [
                    "audio_b64": b64,
                    "messages": apiMessages,
                    "check_turn": !forceFinal,
                    "force_transcribe": forceFinal,
                    "language": "de-DE",
                    "turn_threshold": 0.42,
                    "tts_engine": engineName,
                    "voice_preset": presetKey,
                    "voice_style": styleTag,
                    "speaker": speakerName,
                    "instruct": instructText,
                    "seed": curSeed,
                    "tts_temperature": curTemp,
                    "max_tokens": 100,
                ]
                if let refB64 {
                    extra["voice_ref_b64"] = refB64
                    if !refTxt.isEmpty { extra["reference_text"] = refTxt }
                }

                let handleTranscript: (String, Double?, Double?) -> Void = { userText, sttMs, turnMs in
                    Task { @MainActor in
                        guard self.callActive, !ctrl.isCancelled() else { return }
                        self.resetVADState()
                        self.messages.append(CallMessage(role: "user", text: userText, sttMs: sttMs, turnMs: turnMs))
                        let aMsg = CallMessage(id: turnAssistantId, role: "assistant", text: "")
                        self.messages.append(aMsg)
                        self.activeAssistantMessageId = turnAssistantId
                        self.activeAssistantTotalAudioSec = 0
                        self.phase = .thinking
                        self.statusMessage = "Qwen antwortet …"
                    }
                }
                let handleToken: (String) -> Void = { piece in
                    Task { @MainActor in
                        guard !ctrl.isCancelled(),
                              let idx = self.messages.firstIndex(where: { $0.id == turnAssistantId }) else { return }
                        self.messages[idx].text += piece
                    }
                }
                let handleChunk: (Data, Int, String) -> Void = { pcm, sr, _ in
                    guard !ctrl.isCancelled() else { return }
                    self.pcmPlayer.appendPCM16(pcm, sampleRate: Double(sr))
                    let chunkSec = Double(pcm.count / 2) / Double(max(sr, 1))
                    Task { @MainActor in
                        guard !ctrl.isCancelled() else { return }
                        self.recordedSampleRate = sr
                        self.recordedAIPCM.append(pcm)
                        self.activeAssistantTotalAudioSec += chunkSec
                        if self.phase == .thinking || self.phase == .checkingTurn {
                            self.phase = .speaking
                            self.statusMessage = "Spricht … (jederzeit unterbrechbar)"
                        }
                    }
                }
                let handleProgress: (String) -> Void = { msg in
                    Task { @MainActor in self.statusMessage = msg }
                }

                let res: [String: Any]
                if let sess, let reqId, sess.isAlive {
                    res = try sess.call("converse", id: reqId, extra,
                                        onTranscript: handleTranscript,
                                        onToken: handleToken,
                                        onAudioChunk: handleChunk,
                                        progress: handleProgress)
                } else {
                    res = try PhoneRemote.call("converse", extra, control: ctrl,
                                               onTranscript: handleTranscript,
                                               onToken: handleToken,
                                               onAudioChunk: handleChunk,
                                               progress: handleProgress)
                }

                let complete = forceFinal || (res["turn_complete"] as? Bool ?? true)
                let userText = (res["user_text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                if !complete {
                    await MainActor.run {
                        if self.turnControl === ctrl { self.listenInFlight = false }
                        guard self.callActive, !ctrl.isCancelled() else { return }
                        self.audioLock.lock()
                        self.turnCheckCooldownUntil = Date().addingTimeInterval(0.28)
                        self.audioLock.unlock()
                        self.phase = .listening
                        self.statusMessage = "Hört weiter zu (Satz noch offen) …"
                    }
                    return
                }
                if userText.isEmpty {
                    await MainActor.run {
                        if self.turnControl === ctrl { self.listenInFlight = false }
                        guard self.callActive, !ctrl.isCancelled() else { return }
                        self.resetVADState()
                        self.phase = .listening
                        self.statusMessage = "Hört zu …"
                    }
                    return
                }

                await MainActor.run {
                    if let idx = self.messages.firstIndex(where: { $0.id == turnAssistantId }) {
                        if let full = res["text"] as? String, !full.isEmpty, !self.messages[idx].interrupted {
                            self.messages[idx].text = full
                        }
                        self.messages[idx].llmMs = (res["llm_ttft_ms"] as? NSNumber)?.doubleValue
                        self.messages[idx].ttsMs = (res["tts_ttfa_ms"] as? NSNumber)?.doubleValue
                        self.messages[idx].firstAudioMs = (res["e2e_first_audio_ms"] as? NSNumber)?.doubleValue
                            ?? (res["first_audio_ms"] as? NSNumber)?.doubleValue
                    }
                }

                // Wait until scheduled audio finishes playing (bounded by hard ceiling so playback can never deadlock listening!)
                let waitDeadline = Date().addingTimeInterval(22.0)
                while !ctrl.isCancelled() && self.pcmPlayer.isPlaying && Date() < waitDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await MainActor.run {
                    if self.turnControl === ctrl { self.listenInFlight = false }
                    if !ctrl.isCancelled() && self.callActive {
                        self.activeAssistantMessageId = nil
                        self.audioLock.lock()
                        self.noiseFloor = min(self.noiseFloor, 0.007)
                        self.audioLock.unlock()
                        self.phase = .listening
                        self.statusMessage = "Hört zu …"
                    }
                }
            } catch {
                await MainActor.run {
                    if self.turnControl === ctrl { self.listenInFlight = false }
                    if !ctrl.isCancelled() {
                        self.errorMessage = error.localizedDescription
                        if self.callActive {
                            self.resetVADState()
                            self.phase = .listening
                            self.statusMessage = "Hört zu …"
                        }
                    }
                }
            }
        }
    }

    private func resolvedVoiceRefB64() -> String? {
        guard let path = voiceRefPath, !path.isEmpty else { return nil }
        if voiceRefCachePath == path, let cached = voiceRefCacheB64 { return cached }
        if let wav = try? WAVCodec.loadReferenceWAV(from: URL(fileURLWithPath: path)) {
            let b64 = wav.base64EncodedString()
            voiceRefCachePath = path; voiceRefCacheB64 = b64
            return b64
        }
        return nil
    }

    private func sendTurn(userText: String, appendUserBubble: Bool, sttMs: Double? = nil, turnMs: Double? = nil) {
        if appendUserBubble {
            messages.append(CallMessage(role: "user", text: userText, sttMs: sttMs, turnMs: turnMs))
        }
        var apiMessages = buildAPIMessages()
        if !appendUserBubble {
            apiMessages.append(["role": "user", "content": userText])
        }

        let assistantMsg = CallMessage(role: "assistant", text: "")
        messages.append(assistantMsg)
        activeAssistantMessageId = assistantMsg.id
        activeAssistantTotalAudioSec = 0
        phase = .thinking
        statusMessage = "Qwen antwortet …"

        let engineName = ttsEngine
        let presetKey = voicePreset.rawValue
        let styleTag = voicePreset.styleTag
        let speakerName = qwenSpeaker
        let instructText = qwenInstruct
        let refB64 = engineName == "drama-3" ? resolvedVoiceRefB64() : nil
        let refTxt = referenceText
        let curSeed = seed
        let curTemp = ttsTemperature
        let ctrl = RunControl(); turnControl = ctrl
        let sess = activeSession
        let reqId = sess?.isAlive == true ? sess?.allocateId() : nil
        activeTurnReqId = reqId

        Task.detached(priority: .userInitiated) {
            do {
                var extra: [String: Any] = [
                    "messages": apiMessages,
                    "tts_engine": engineName,
                    "voice_preset": presetKey,
                    "voice_style": styleTag,
                    "speaker": speakerName,
                    "instruct": instructText,
                    "seed": curSeed,
                    "tts_temperature": curTemp,
                    "max_tokens": 100,
                ]
                if let refB64 {
                    extra["voice_ref_b64"] = refB64
                    if !refTxt.isEmpty { extra["reference_text"] = refTxt }
                }
                let onTok: (String) -> Void = { piece in
                    Task { @MainActor in
                        guard !ctrl.isCancelled(),
                              let idx = self.messages.firstIndex(where: { $0.id == assistantMsg.id }) else { return }
                        self.messages[idx].text += piece
                    }
                }
                let onAud: (Data, Int, String) -> Void = { pcm, sr, _ in
                    guard !ctrl.isCancelled() else { return }
                    self.pcmPlayer.appendPCM16(pcm, sampleRate: Double(sr))
                    let chunkSec = Double(pcm.count / 2) / Double(max(sr, 1))
                    Task { @MainActor in
                        guard !ctrl.isCancelled() else { return }
                        self.recordedSampleRate = sr
                        self.recordedAIPCM.append(pcm)
                        self.activeAssistantTotalAudioSec += chunkSec
                        if self.phase == .thinking {
                            self.phase = .speaking
                            self.statusMessage = "Spricht … (jederzeit unterbrechbar)"
                        }
                    }
                }
                let onProg: (String) -> Void = { msg in
                    Task { @MainActor in self.statusMessage = msg }
                }
                let res: [String: Any]
                if let sess, let reqId, sess.isAlive {
                    res = try sess.call("turn", id: reqId, extra, onToken: onTok, onAudioChunk: onAud, progress: onProg)
                } else {
                    res = try PhoneRemote.call("turn", extra, control: ctrl, onToken: onTok, onAudioChunk: onAud, progress: onProg)
                }

                await MainActor.run {
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantMsg.id }) {
                        if let full = res["text"] as? String, !full.isEmpty, !self.messages[idx].interrupted {
                            self.messages[idx].text = full
                        }
                        self.messages[idx].llmMs = (res["llm_ttft_ms"] as? NSNumber)?.doubleValue
                        self.messages[idx].ttsMs = (res["tts_ttfa_ms"] as? NSNumber)?.doubleValue
                        self.messages[idx].firstAudioMs = (res["first_audio_ms"] as? NSNumber)?.doubleValue
                    }
                }

                // Wait until scheduled audio finishes playing (bounded by hard ceiling so playback can never deadlock listening!)
                let waitDeadline = Date().addingTimeInterval(22.0)
                while !ctrl.isCancelled() && self.pcmPlayer.isPlaying && Date() < waitDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await MainActor.run {
                    if !ctrl.isCancelled() && self.callActive {
                        self.activeAssistantMessageId = nil
                        self.audioLock.lock()
                        self.noiseFloor = min(self.noiseFloor, 0.007)
                        self.audioLock.unlock()
                        self.phase = .listening
                        self.statusMessage = "Hört zu …"
                    }
                }
            } catch {
                await MainActor.run {
                    if !ctrl.isCancelled() {
                        self.errorMessage = error.localizedDescription
                        if self.callActive { self.phase = .listening; self.statusMessage = "Hört zu …" }
                    }
                }
            }
        }
    }

    private func saveCurrentCall() {
        do {
            try FileManager.default.createDirectory(at: callsDirectory, withIntermediateDirectories: true)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmmss"
            let base = "anruf-\(df.string(from: callStartedAt))"
            let jsonURL = callsDirectory.appendingPathComponent(base + ".json")
            let wavURL = callsDirectory.appendingPathComponent(base + ".wav")
            if !recordedAIPCM.isEmpty {
                let wav = WAVCodec.encodeMono16(pcm: recordedAIPCM, sampleRate: recordedSampleRate)
                try wav.write(to: wavURL, options: .atomic)
            }
            let payload: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: callStartedAt),
                "title": scenario.targetCompany,
                "scenario": scenario.title,
                "tts_engine": ttsEngine,
                "messages": messages.map { [
                    "role": $0.role, "text": $0.text, "interrupted": $0.interrupted,
                    "stt_ms": $0.sttMs as Any, "llm_ms": $0.llmMs as Any,
                    "tts_ms": $0.ttsMs as Any, "first_audio_ms": $0.firstAudioMs as Any,
                ] },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: jsonURL, options: .atomic)
            refreshSavedCalls()
        } catch {
            // Non-fatal
        }
    }

    func refreshSavedCalls() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: callsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        savedCalls = urls.filter { $0.pathExtension.lowercased() == "json" }.compactMap { url in
            let data = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let date = (data["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let wav = url.deletingPathExtension().appendingPathExtension("wav")
            return SavedCall(
                url: url, date: date, title: data["title"] as? String ?? url.deletingPathExtension().lastPathComponent,
                messageCount: (data["messages"] as? [Any])?.count ?? 0,
                audioURL: FileManager.default.fileExists(atPath: wav.path) ? wav : nil
            )
        }.sorted { $0.date > $1.date }
    }

    func playSavedCall(_ call: SavedCall) {
        guard let audio = call.audioURL else { return }
        replayPlayer?.stop()
        replayPlayer = try? AVAudioPlayer(contentsOf: audio)
        replayPlayer?.play()
    }

    func revealSavedCall(_ call: SavedCall) {
        NSWorkspace.shared.activateFileViewerSelecting([call.audioURL ?? call.url])
    }
}
