import Foundation
import SwiftUI
import AppKit
import WebKit
import AVFoundation

enum LiveKitProfile: String, CaseIterable, Identifiable {
    case local = "local"
    case hybrid = "hybrid"
    case cloudPipeline = "cloud_pipeline"
    case cloudRealtime = "cloud_realtime"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "100 % Lokal (bigki)"
        case .hybrid: return "Hybrid (bigki LLM + ElevenLabs)"
        case .cloudPipeline: return "Cloud (ElevenLabs + OpenAI)"
        case .cloudRealtime: return "Cloud (OpenAI Realtime)"
        }
    }
    var subtitle: String {
        switch self {
        case .local: return "0 €/Min · Nemotron + Qwen 3.8 Flash + Drama 3 auf bigki"
        case .hybrid: return "Kostenloses Qwen-LLM auf bigki + ElevenLabs-Stimme"
        case .cloudPipeline: return "OpenAI/Deepgram STT + GPT-4.1-mini + ElevenLabs v4 Turbo"
        case .cloudRealtime: return "Native Audio→Audio Speech-to-Speech (~300 ms)"
        }
    }
    var needsBigki: Bool { self == .local || self == .hybrid }
    var needsElevenLabs: Bool { self == .hybrid || self == .cloudPipeline }
    var needsOpenAI: Bool { self == .cloudPipeline || self == .cloudRealtime }
}

struct ElevenLabsVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let gender: String

    var label: String {
        var meta: [String] = []
        if !language.isEmpty { meta.append(language.uppercased()) }
        if gender == "male" { meta.append("m") }
        else if gender == "female" { meta.append("w") }
        else if !gender.isEmpty { meta.append(gender) }
        return meta.isEmpty ? name : "\(name) (\(meta.joined(separator: " · ")))"
    }
}

@MainActor
final class LiveKitPhoneStudio: ObservableObject {
    static let defaultYeonVoiceId = "WNpDisiMIzLl7ft2rYeN"

    @Published var profile: LiveKitProfile {
        didSet { UserDefaults.standard.set(profile.rawValue, forKey: "lkPhoneProfile") }
    }
    @Published var elevenlabsVoiceId: String {
        didSet { UserDefaults.standard.set(elevenlabsVoiceId, forKey: "lkElevenVoiceId") }
    }
    @Published var elevenlabsModel: String {
        didSet { UserDefaults.standard.set(elevenlabsModel, forKey: "lkElevenModel") }
    }
    @Published var openaiModel: String {
        didSet { UserDefaults.standard.set(openaiModel, forKey: "lkOpenAIModel") }
    }
    @Published var openaiVoice: String {
        didSet { UserDefaults.standard.set(openaiVoice, forKey: "lkOpenAIVoice") }
    }
    @Published var openaiApiKey = "" {
        didSet { if keysLoaded { saveKeys() } }
    }
    @Published var elevenlabsApiKey = "" {
        didSet {
            if keysLoaded {
                saveKeys()
                if elevenlabsApiKey.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16 {
                    fetchElevenLabsVoices()
                }
            }
        }
    }
    @Published var deepgramApiKey = "" {
        didSet { if keysLoaded { saveKeys() } }
    }
    private var keysLoaded = false

    @Published var elevenlabsVoices: [ElevenLabsVoice] = [
        ElevenLabsVoice(id: LiveKitPhoneStudio.defaultYeonVoiceId, name: "Yeon - Deep and Emotional", language: "de", gender: "male"),
    ]
    @Published var loadingVoices = false
    @Published var voicesError: String? = nil

    @Published var running = false
    @Published var starting = false
    @Published var statusText = "LiveKit lokal gestoppt"
    @Published var errorMessage: String? = nil
    @Published var reloadNonce = 0

    private var serverProc: Process?
    private var bridgeProc: Process?
    private var agentProc: Process?

    let bridgeURL = URL(string: "http://127.0.0.1:7891/")!
    private let keysURL = supportDirectory.appendingPathComponent("livekit-keys.json")
    private let configURL = supportDirectory.appendingPathComponent("livekit-call-config.json")
    private let venvPython = supportDirectory.appendingPathComponent("livekit-venv/bin/python")

    init() {
        profile = LiveKitProfile(rawValue: UserDefaults.standard.string(forKey: "lkPhoneProfile") ?? "") ?? .local
        let savedVoice = (UserDefaults.standard.string(forKey: "lkElevenVoiceId") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if savedVoice.isEmpty || savedVoice == "pNInz6obpgDQGcFmaJgB" || savedVoice.lowercased() == "yeon" {
            elevenlabsVoiceId = Self.defaultYeonVoiceId
        } else {
            elevenlabsVoiceId = savedVoice
        }
        let savedModel = UserDefaults.standard.string(forKey: "lkElevenModel") ?? ""
        elevenlabsModel = (savedModel.isEmpty || savedModel == "eleven_flash_v2_5") ? "eleven_v4_turbo" : savedModel
        openaiModel = UserDefaults.standard.string(forKey: "lkOpenAIModel") ?? "gpt-4.1-mini"
        openaiVoice = UserDefaults.standard.string(forKey: "lkOpenAIVoice") ?? "marin"
        loadKeys()
        keysLoaded = true
        if !elevenlabsApiKey.isEmpty {
            fetchElevenLabsVoices()
        }
    }

    func fetchElevenLabsVoices() {
        let key = elevenlabsApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard !loadingVoices else { return }
        loadingVoices = true
        voicesError = nil
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
                req.setValue(key, forHTTPHeaderField: "xi-api-key")
                req.timeoutInterval = 12
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    throw StudioError.message("ElevenLabs /v1/voices HTTP \(http.statusCode)")
                }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = root["voices"] as? [[String: Any]] else {
                    throw StudioError.message("Unerwartete Antwort von ElevenLabs")
                }
                var parsed: [ElevenLabsVoice] = []
                for v in items {
                    guard let vid = v["voice_id"] as? String, !vid.isEmpty,
                          let name = v["name"] as? String, !name.isEmpty else { continue }
                    let labels = v["labels"] as? [String: Any] ?? [:]
                    let lang = (labels["language"] as? String ?? "").lowercased()
                    let gender = (labels["gender"] as? String ?? "").lowercased()
                    parsed.append(ElevenLabsVoice(id: vid, name: name, language: lang, gender: gender))
                }
                parsed.sort { a, b in
                    if a.id == Self.defaultYeonVoiceId { return true }
                    if b.id == Self.defaultYeonVoiceId { return false }
                    let aDe = a.language == "de"
                    let bDe = b.language == "de"
                    if aDe != bDe { return aDe }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                if !parsed.isEmpty {
                    self.elevenlabsVoices = parsed
                }
                self.loadingVoices = false
            } catch {
                self.loadingVoices = false
                self.voicesError = "Stimmenliste nicht abrufbar (\(error.localizedDescription))"
            }
        }
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: venvPython.path) && livekitServerBinary != nil
    }

    private var livekitServerBinary: String? {
        for path in ["/opt/homebrew/bin/livekit-server", "/usr/local/bin/livekit-server"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func scriptPath(_ name: String) -> String? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: res.path) {
            return res.path
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("src").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dev.path) { return dev.path }
        return nil
    }

    func loadKeys() {
        guard let data = try? Data(contentsOf: keysURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        openaiApiKey = dict["openai_api_key"] ?? ""
        elevenlabsApiKey = dict["elevenlabs_api_key"] ?? ""
        deepgramApiKey = dict["deepgram_api_key"] ?? ""
    }

    func saveKeys() {
        let dict: [String: String] = [
            "openai_api_key": openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "elevenlabs_api_key": elevenlabsApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "deepgram_api_key": deepgramApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try? data.write(to: keysURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
        }
    }

    func syncConfig(from phone: PhoneCallStudio) {
        let cfg: [String: Any] = [
            "profile": profile.rawValue,
            "instructions": phone.scenario.buildSystemPrompt(dramaTags: false),
            "caller_name": phone.scenario.callerName,
            "target_company": phone.scenario.targetCompany,
            "scenario_title": phone.scenario.title,
            "tts_engine": phone.ttsEngine,
            "voice_preset": phone.voicePreset.rawValue,
            "voice_style": phone.voicePreset.styleTag,
            "tts_temperature": phone.ttsTemperature,
            "seed": phone.seed,
            "qwen_speaker": phone.qwenSpeaker,
            "qwen_instruct": phone.qwenInstruct,
            "elevenlabs_voice_id": elevenlabsVoiceId.trimmingCharacters(in: .whitespacesAndNewlines),
            "elevenlabs_model": elevenlabsModel,
            "openai_model": openaiModel,
            "openai_voice": openaiVoice,
            "openai_realtime_model": "gpt-realtime",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func ensureStarted(phone: PhoneCallStudio) {
        syncConfig(from: phone)
        saveKeys()
        if running && (serverProc?.isRunning == true || Self.portOpen(7880)) && Self.portOpen(7891) {
            return
        }
        guard !starting else { return }
        guard let lkBin = livekitServerBinary else {
            errorMessage = "livekit-server fehlt (brew install livekit)."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else {
            errorMessage = "livekit-venv fehlt unter ~/Library/Application Support/StudioPortal/livekit-venv."
            return
        }
        guard let bridgeScript = scriptPath("livekit_web_bridge.py"),
              let agentScript = scriptPath("livekit_phone_agent.py") else {
            errorMessage = "LiveKit-Agent-Skripte wurden im App-Bundle nicht gefunden."
            return
        }

        starting = true
        errorMessage = nil
        statusText = "Starte LiveKit-Server & Agent lokal …"

        // Request mic access proactively on macOS so WKWebView WebRTC audio works immediately
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        let pyPath = venvPython.path
        let logDir = supportDirectory
        Task.detached(priority: .userInitiated) {
            do {
                let sProc = try Self.startIfNeeded(port: 7880, exec: lkBin, args: ["--dev", "--bind", "127.0.0.1", "--port", "7880"], logFile: logDir.appendingPathComponent("livekit-server.log"))
                let bProc = try Self.startIfNeeded(port: 7891, exec: pyPath, args: [bridgeScript], logFile: logDir.appendingPathComponent("livekit-bridge.log"))

                // Wait for livekit-server (7880) and web bridge (7891)
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline && (!Self.portOpen(7880) || !Self.portOpen(7891)) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard Self.portOpen(7880) && Self.portOpen(7891) else {
                    throw StudioError.message("LiveKit-Server oder Web-Bridge konnte nicht gestartet werden.")
                }

                // Start LiveKit Python agent connected to ws://127.0.0.1:7880
                let aProc = try Self.spawnProcess(exec: pyPath, args: [agentScript, "dev"], envExtra: [
                    "LIVEKIT_URL": "ws://127.0.0.1:7880",
                    "LIVEKIT_API_KEY": "devkey",
                    "LIVEKIT_API_SECRET": "secret",
                    "PYTHONUNBUFFERED": "1",
                ], logFile: logDir.appendingPathComponent("livekit-agent.log"))
                try? await Task.sleep(for: .milliseconds(900))

                await MainActor.run {
                    if let sProc { self.serverProc = sProc }
                    if let bProc { self.bridgeProc = bProc }
                    self.agentProc = aProc
                    self.starting = false
                    self.running = true
                    self.statusText = "LiveKit lokal bereit (Port 7880)"
                    self.reloadNonce += 1
                }
            } catch {
                await MainActor.run {
                    self.starting = false
                    self.running = false
                    self.statusText = "Fehler beim LiveKit-Start"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func restartAgent(phone: PhoneCallStudio) {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.ensureStarted(phone: phone)
        }
    }

    func stop() {
        for proc in [agentProc, bridgeProc, serverProc] {
            if let p = proc, p.isRunning { p.terminate() }
        }
        agentProc = nil; bridgeProc = nil; serverProc = nil
        running = false
        starting = false
        statusText = "LiveKit lokal gestoppt"
    }

    func openInBrowser() {
        NSWorkspace.shared.open(bridgeURL)
    }

    private nonisolated static func portOpen(_ port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
    }

    private nonisolated static func startIfNeeded(port: UInt16, exec: String, args: [String], logFile: URL) throws -> Process? {
        if portOpen(port) { return nil }
        return try spawnProcess(exec: exec, args: args, envExtra: [:], logFile: logFile)
    }

    private nonisolated static func spawnProcess(exec: String, args: [String], envExtra: [String: String], logFile: URL) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for (k, v) in envExtra { env[k] = v }
        proc.environment = env
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logFile) {
            try? fh.truncate(atOffset: 0)
            proc.standardOutput = fh
            proc.standardError = fh
        }
        try proc.run()
        return proc
    }
}

struct LiveKitWebView: NSViewRepresentable {
    var url: URL
    var reloadNonce: Int

    final class Coordinator: NSObject, WKUIDelegate {
        var lastNonce = -1
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastNonce = reloadNonce
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastNonce != reloadNonce {
            context.coordinator.lastNonce = reloadNonce
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
}
