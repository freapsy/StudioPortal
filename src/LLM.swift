import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ThinkingEffort: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case low = "low"
    case medium = "medium"
    case high = "high"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Aus"
        case .low: return "Niedrig"
        case .medium: return "Mittel"
        case .high: return "Hoch"
        }
    }

    static func parse(_ raw: Any?) throws -> ThinkingEffort {
        guard let raw else { return .none }
        if let flag = raw as? Bool { return flag ? .medium : .none }
        let key = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return .none }
        switch key {
        case "none", "off", "aus", "false", "0": return .none
        case "low", "niedrig", "kurz": return .low
        case "medium", "mittel", "true", "1": return .medium
        case "high", "xhigh", "hoch", "tief", "max": return .high
        default: throw StudioError.message("Ungültige Denkstufe '\(raw)' (erlaubt: none, low, medium, high).")
        }
    }
}

/// LLM on bigki: Strata with Qwen3.8 Flash Next on all three MI50 (the user's own installation; the worker starts it
/// on demand through the card queue and stops it after 20 min without a StudioPortal request).
enum LLMRemote {
    static func call(_ action: String, _ extra: [String: Any] = [:], control: RunControl? = nil,
                     onToken: ((String) -> Void)? = nil, onReasoning: ((String) -> Void)? = nil,
                     progress: ((String) -> Void)? = nil) throws -> [String: Any] {
        var request = extra
        request["operation"] = "llm"; request["action"] = action
        var result: [String: Any]?, remoteError: String?
        try runWorker(request, control: control, patient: true) { event in
            switch event["type"] as? String {
            case "token": if let text = event["text"] as? String { onToken?(text) }
            case "reasoning": if let text = event["text"] as? String { onReasoning?(text) }
            case "status", "waiting": if let text = event["message"] as? String { progress?(text) }
            case "result": result = event["result"] as? [String: Any]
            case "error": remoteError = event["message"] as? String ?? "bigki meldet einen Fehler."
            default: break
            }
        }
        if let remoteError { throw StudioError.message(remoteError) }
        guard let result else { throw StudioError.message("Die Verbindung zu bigki wurde unterbrochen.") }
        return result
    }

    /// "149 t/s · Prompt 75 t/s · 132 Tokens · 1,4 s" – shown under every answer.
    static func speed(_ r: [String: Any]) -> String {
        var parts: [String] = []
        if let tps = (r["tokens_per_second"] as? NSNumber)?.doubleValue { parts.append(String(format: "%.0f t/s", tps)) }
        if let pp = (r["prompt_tokens_per_second"] as? NSNumber)?.doubleValue { parts.append(String(format: "Prompt %.0f t/s", pp)) }
        if let n = r["completion_tokens"] as? Int { parts.append("\(n) Tokens") }
        if let s = (r["seconds"] as? NSNumber)?.doubleValue { parts.append(String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",")) }
        if let eff = r["reasoning_effort"] as? String, let level = try? ThinkingEffort.parse(eff), level != .none {
            parts.append("Denken: \(level.label)")
        }
        return parts.joined(separator: " · ")
    }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    var role: String
    var text: String
    var reasoning: String? = nil
    var info: String? = nil
    var files: [URL] = []
    var preview: Data? = nil  // ältere gespeicherte Chats: eine Vorschau
    var previews: [ChatPreview]? = nil
    var webUsed = false
    /// Verlauf eines Pi-Auftrags (Denken, Werkzeugschritte, Fehler); bleibt auch nach Stopp erhalten.
    var steps: [ChatStep]? = nil

    mutating func record(_ item: PhotoCraftSession.Activity) {
        var list = steps ?? []
        switch item {
        case .thinking(let piece):
            if list.last?.kind == "thinking" { list[list.count - 1].text += piece } else { list.append(ChatStep(kind: "thinking", text: piece)) }
        case .tool(let line): list.append(ChatStep(kind: "tool", text: line))
        case .failed(let line): list.append(ChatStep(kind: "failed", text: line))
        }
        steps = list
    }
}

/// Antwort auf eine Rückfrage, über Threads hinweg (Pis Ereignis-Thread wartet, die Oberfläche antwortet).
final class Decision: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: (ok: Bool, instead: String?)?
    func finish(_ ok: Bool, _ instead: String?) {
        let first = lock.withLock { () -> Bool in guard value == nil else { return false }; value = (ok, instead); return true }
        if first { done.signal() }
    }
    func wait() -> (ok: Bool, instead: String?) { done.wait(); return lock.withLock { value ?? (false, nil) } }
}

/// Eine PhotoCraft-Vorschau unter einer Antwort, mit dem Namen des Dokuments (falls bekannt).
struct ChatPreview: Equatable, Hashable, Codable {
    var name: String?
    var data: Data
}

struct ChatStep: Equatable, Codable {
    var kind: String  // thinking | tool | failed
    var text: String
}

@MainActor
final class LLMStudio: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var effort: ThinkingEffort = .none
    @Published var running = false { didSet { if running && !oldValue { pollLive() } } }
    /// Live-Werte von Strata (Prompt lesen / schreiben, t/s, Kontext), solange eine Antwort läuft.
    @Published private(set) var live: StrataLive.Snapshot?
    /// Nachrichten, die während einer Antwort geschrieben wurden und danach gesendet werden (normaler Chat oder zu spät für Pi).
    @Published private(set) var queued: [String] = []
    @Published var phase: String?
    @Published var error: String?
    @Published var state: [String: Any] = [:]
    @Published var switching = false
    @Published var piEnabled = false {
        didSet { if oldValue != piEnabled { photoCraft = nil; chatSaved = false; contextTokens = nil } }
    }
    @Published var photoCraftEnabled = false {
        didSet { if oldValue != photoCraftEnabled { photoCraft = nil; chatSaved = false; contextTokens = nil } }
    }
    @Published var webSearchEnabled = false {
        didSet { if oldValue != webSearchEnabled { photoCraft = nil; chatSaved = false; contextTokens = nil } }
    }
    var usesPi: Bool { piEnabled || photoCraftEnabled || webSearchEnabled }
    /// Zuletzt gemessene Kontextbelegung (Prompt + Antwort) in Token; nil = noch unbekannt.
    @Published private(set) var contextTokens: Int?
    private var contextChars = 0
    private var summary: String?
    private var summaryUpTo = 0
    var contextLimit: Int { state["context"] as? Int ?? 262_144 }
    /// Wie Pi: standardmäßig zusammenfassen, sobald weniger als 16k Token frei sind.
    static let compactReserve = 16_384
    /// Ab wie vielen Token automatisch zusammengefasst wird (0 = automatisch, kurz vor der Grenze). Gilt für Chat und Pi.
    @Published var compactAt = UserDefaults.standard.integer(forKey: "llmCompactAt") {
        didSet { UserDefaults.standard.set(compactAt, forKey: "llmCompactAt"); photoCraft = nil }
    }
    @Published var compactKeep: Int = {
        let saved = UserDefaults.standard.integer(forKey: "llmCompactKeep")
        return ChatCompaction.keepOptions.contains(saved) ? saved : ChatCompaction.defaultKeep
    }() {
        didSet {
            UserDefaults.standard.set(compactKeep, forKey: "llmCompactKeep")
            if oldValue != compactKeep { photoCraft = nil }
        }
    }

    /// Sicherheitsstufe für Dateien (Sandbox / Fragen / Alles erlauben), gemerkt; ändern startet Pi neu.
    @Published var fileMode = PhotoCraftSession.FileMode(rawValue: UserDefaults.standard.string(forKey: "llmFileMode") ?? "") ?? .sandbox {
        didSet { UserDefaults.standard.set(fileMode.rawValue, forKey: "llmFileMode"); if oldValue != fileMode { photoCraft = nil } }
    }
    struct Approval: Identifiable {
        let id = UUID(), title: String, detail: String
        let keys: [String]?  // Regelschlüssel (Programme bzw. Dateiänderungen); nil = nur einzeln freigebbar
        let answer: (Bool, String?) -> Void
    }
    /// Wie bei Claude Code: einmal, für diesen Chat, immer (hier im Arbeitsordner) oder nein mit Hinweis.
    enum Choice { case once, chat, always, deny(String) }
    /// Offene Rückfrage von Pi im Modus „Fragen“.
    @Published private(set) var approval: Approval?
    /// Freigaben „in diesem Chat“ (bis „Neuer Chat“) und „immer“ (je Arbeitsordner gemerkt, UserDefaults `llmAllowRules`).
    @Published private(set) var chatRules: Set<String> = []
    @Published private(set) var folderRules: Set<String> = []
    private var rulesFolder: String { photoCraftDocument?.resolvingSymlinksInPath().path ?? "" }
    private static var savedRules: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "llmAllowRules") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "llmAllowRules") }
    }

    /// Blockiert nur Pis Ereignis-Thread, bis der Nutzer in der App entscheidet (Stopp = ablehnen). Passt eine Regel, ohne Karte.
    nonisolated func askUser(_ title: String, _ detail: String) -> (ok: Bool, instead: String?) {
        let keys = CommandRules.keys(title: title, detail: detail)
        let decision = Decision()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.folderRules = Set(Self.savedRules[self.rulesFolder] ?? [])
                if CommandRules.allowed(keys, by: self.chatRules.union(self.folderRules)) { decision.finish(true, nil); return }
                self.approval = Approval(title: title, detail: detail, keys: keys) { decision.finish($0, $1) }
            }
        }
        return decision.wait()
    }

    func answer(_ choice: Choice) {
        guard let pending = approval else { return }
        approval = nil
        switch choice {
        case .once: break
        case .chat: chatRules.formUnion(pending.keys ?? [])
        case .always:
            folderRules.formUnion(pending.keys ?? [])
            var all = Self.savedRules; all[rulesFolder] = folderRules.sorted(); Self.savedRules = all
        case .deny(let text): pending.answer(false, text.trimmingCharacters(in: .whitespacesAndNewlines)); return
        }
        pending.answer(true, nil)
    }

    /// „Freigaben zurücksetzen“: Chat-Regeln und die gemerkten für diesen Arbeitsordner.
    func forgetRules() {
        chatRules = []; folderRules = []
        var all = Self.savedRules; all[rulesFolder] = nil; Self.savedRules = all
    }

    var rulesSummary: String? {
        let folderRules = Set(Self.savedRules[rulesFolder] ?? [])
        let chat = chatRules.subtracting(folderRules)
        guard !chat.isEmpty || !folderRules.isEmpty else { return nil }
        return [folderRules.isEmpty ? nil : "Immer hier: " + CommandRules.label(folderRules.sorted()),
                chat.isEmpty ? nil : "In diesem Chat: " + CommandRules.label(chat.sorted())].compactMap { $0 }.joined(separator: " · ")
    }

    var compactThreshold: Int {
        let latest = contextLimit - Self.compactReserve
        return compactAt > 0 ? min(compactAt, latest) : latest
    }
    @Published var photoCraftEffort: ThinkingEffort = .medium
    @Published var photoCraftDocument: URL? = LLMStudio.savedWorkFolder
    @Published private(set) var savedChats = SavedLLMChat.all()
    @Published private(set) var savingChat = false
    @Published private(set) var chatSaved = false
    /// Chats werden nach jeder Antwort automatisch gespeichert, außer solange „Temporärer Chat“ eingeschaltet ist.
    @Published var temporaryChat = false { didSet { if !temporaryChat { autosave() } } }
    private var control: RunControl?
    private var photoCraft: PhotoCraftSession?
    private var archive: SavedLLMChat?
    private var restoreArchive = false
    private var lastEditable: URL?

    var serverRunning: Bool { state["running"] as? Bool ?? false }
    var statusText: String {
        if switching { return phase ?? "…" }
        if state["starting"] as? Bool == true { return "startet …" }
        guard serverRunning else { return state.isEmpty ? "prüfe …" : "aus – startet beim ersten Senden (~75 s)" }
        if let minutes = state["auto_stop_minutes"] as? Int { return "läuft · stoppt nach \(minutes) min Pause" }
        return "läuft"
    }

    func refresh() async {
        let value = await Task.detached(priority: .utility) { try? LLMRemote.call("status") }.value
        if let value { state = value }
    }

    func toggleServer() {
        let action = serverRunning ? "stop" : "start"
        switching = true; error = nil; phase = action == "start" ? "Strata startet (~75 s) …" : "stoppt …"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[String: Any], Error> in
                Result { try LLMRemote.call(action, action == "stop" ? ["force": true] : [:], progress: { text in
                    Task { @MainActor in self.phase = text }
                }) }
            }.value
            switching = false; phase = nil
            switch outcome {
            case .success(let value): state = value
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !savingChat else { return }
        if text == "/compact" || text.hasPrefix("/compact ") {
            if running { input = ""; queued.append(text) } else { compactNow(focus: text.dropFirst(8).trimmingCharacters(in: .whitespaces)) }
            return
        }
        chatSaved = false
        if running { interject(text); return }
        if usesPi { sendToPi(text); return }
        input = ""; error = nil
        messages.append(ChatMessage(role: "user", text: text))
        messages.append(ChatMessage(role: "assistant", text: ""))
        let index = messages.count - 1
        let control = RunControl(); self.control = control
        let answering = serverRunning ? (effort == .none ? "antwortet …" : "denkt nach (\(effort.label)) …") : "Strata startet (~75 s) …"
        let compaction = compactionPlan(before: index)
        running = true; phase = compaction == nil ? answering : "fasst den Verlauf zusammen …"
        let level = effort.rawValue
        let think = effort != .none
        Task {
            if let compaction {
                let request = compaction.request
                let folded = await Task.detached(priority: .userInitiated) { () -> Result<[String: Any], Error> in
                    Result { try LLMRemote.call("chat", request, control: control) }
                }.value
                guard case .success(let value) = folded, let text = value["text"] as? String, !text.isEmpty else {
                    if case .failure(let failure) = folded { error = "Zusammenfassen fehlgeschlagen: \(failure.localizedDescription)" }
                    else { error = "Zusammenfassen fehlgeschlagen: leere Antwort." }
                    messages.remove(at: index); running = false; phase = nil; self.control = nil
                    if !finishQueue(ok: false) { autosave() }; return
                }
                summary = text; summaryUpTo = compaction.cut
                phase = answering
            }
            let history = modelHistory(before: index)
            let sentChars = history.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[String: Any], Error> in
                Result { try LLMRemote.call("chat", ["messages": history, "thinking": think, "reasoning_effort": level, "max_tokens": 8192], control: control,
                    onToken: { piece in Task { @MainActor in self.messages[index].text += piece; self.phase = nil } },
                    onReasoning: { piece in Task { @MainActor in
                        self.messages[index].reasoning = (self.messages[index].reasoning ?? "") + piece
                        if self.messages[index].text.isEmpty { self.phase = "denkt nach (\(self.effort.label)) …" }
                    } },
                    progress: { line in Task { @MainActor in if self.messages[index].text.isEmpty && self.messages[index].reasoning == nil { self.phase = line } } }) }
            }.value
            running = false; phase = nil; self.control = nil
            switch outcome {
            case .success(let value):
                if let full = value["text"] as? String { messages[index].text = full }
                if let r = value["reasoning"] as? String, !r.isEmpty { messages[index].reasoning = r }
                messages[index].info = LLMRemote.speed(value) + (compaction != nil ? " · Verlauf zusammengefasst" : "")
                if let prompt = value["prompt_tokens"] as? Int {
                    contextTokens = prompt + (value["completion_tokens"] as? Int ?? 0)
                    contextChars = sentChars + messages[index].text.count
                }
            case .failure(let failure):
                error = failure.localizedDescription
                if messages[index].text.isEmpty && messages[index].reasoning == nil { messages[index].text = "" ; messages.remove(at: index) }
            }
            await refresh()
            if !finishQueue(ok: error == nil && !control.isCancelled()) { autosave() }
        }
    }

    /// Senden, während er arbeitet: Pi (PhotoCraft/Websuche) liest die Nachricht nach dem aktuellen Werkzeugschritt und macht
    /// weiter; sonst (normaler Chat, Pi startet noch) wird sie nach der Antwort als nächste Nachricht gesendet.
    /// /compact [Schwerpunkt]: Verlauf sofort zusammenfassen. PhotoCraft/Websuche: Pis eigener compact-Befehl in der laufenden
    /// Sitzung; normaler Chat: dieselbe Zusammenfassung wie Auto-Compact, aber über den ganzen bisherigen Verlauf.
    func compactNow(focus: String) {
        input = ""; error = nil
        let focus = focus.isEmpty ? nil : focus
        let control = RunControl(); self.control = control
        if usesPi {
            guard let session = photoCraft, session.isRunning else {
                error = "Noch keine laufende Pi-Sitzung: Der nächste Auftrag startet ohnehin frisch."
                return
            }
            running = true; phase = "Pi fasst den Verlauf zusammen …"
            Task {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<Int?, Error> in
                    Result {
                        _ = try LLMRemote.call("start", control: control)
                        return try session.compact(focus: focus)
                    }
                }.value
                compacted(result.map { before in before.map { "Verlauf zusammengefasst (vorher \(StrataLive.tokens($0)) Token)" } ?? "Verlauf zusammengefasst" }, control: control)
            }
            return
        }
        guard let plan = ChatCompaction.plan(messages, summary: summary, from: summaryUpTo, before: messages.count,
                                             tokensPerChar: 1, limit: 0, keep: 0, force: true, focus: focus) else {
            error = "Nichts zum Zusammenfassen."
            return
        }
        let before = contextTokens
        running = true; phase = "fasst den Verlauf zusammen …"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[String: Any], Error> in
                Result { try LLMRemote.call("chat", plan.request, control: control) }
            }.value
            compacted(result.flatMap { value in
                guard let text = value["text"] as? String, !text.isEmpty else { return .failure(StudioError.message("leere Antwort")) }
                let ratio = before.map { Double($0) / Double(max(1, self.contextChars)) } ?? 0.25
                self.summary = text; self.summaryUpTo = plan.cut
                self.contextChars = text.count; self.contextTokens = Int(Double(text.count) * ratio)
                return .success("Verlauf zusammengefasst" + (before.map { " (vorher \(StrataLive.tokens($0)) Token)" } ?? ""))
            }, control: control)
        }
    }

    private func compacted(_ result: Result<String, Error>, control: RunControl) {
        running = false; phase = nil; self.control = nil
        switch result {
        case .success(let note):
            if usesPi { contextTokens = nil }
            if let last = messages.indices.last { messages[last].info = [messages[last].info, note].compactMap { $0 }.joined(separator: " · ") }
            chatSaved = false
        case .failure(let failure):
            if !control.isCancelled() { error = "Zusammenfassen fehlgeschlagen: \(failure.localizedDescription)" }
        }
        if !finishQueue(ok: !control.isCancelled()) { autosave() }
    }

    /// Folgeprompt in die Warteschlange: wird nach der laufenden Antwort gesendet (wie bei Claude).
    func queueNext() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if running { input = ""; queued.append(text) } else { send() }
    }

    func unqueue(_ index: Int) {
        if queued.indices.contains(index) { queued.remove(at: index) }
    }

    private func interject(_ text: String) {
        input = ""
        if photoCraft?.steer(text) == true {
            messages.append(ChatMessage(role: "user", text: text))
            phase = "Liest deine Nachricht nach dem aktuellen Schritt …"
        } else {
            queued.append(text)
        }
    }

    /// Nach einer Antwort: Wartendes senden; nach Fehler oder Stopp zurück ins Eingabefeld statt ungefragt weiterzumachen.
    /// true, wenn gleich die nächste Nachricht läuft (dann speichert erst deren Ende).
    /// Nach Erfolg geht der nächste Folgeprompt los (einer nach dem anderen); nach Fehler oder Stopp kommen alle zurück ins Eingabefeld.
    @discardableResult private func finishQueue(ok: Bool) -> Bool {
        guard !queued.isEmpty else { return false }
        guard ok else {
            input = (queued + [input]).filter { !$0.isEmpty }.joined(separator: "\n\n"); queued = []
            return false
        }
        let typed = input
        input = queued.removeFirst()
        send()
        input = typed  // was der Nutzer gerade tippt, bleibt stehen
        return running
    }

    private func autosave() {
        if !temporaryChat, !messages.isEmpty, !chatSaved, !running { saveChat() }
    }

    func pickWorkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        if piEnabled && !photoCraftEnabled {
            panel.message = "Wähle den Arbeitsordner oder eine einzelne Datei für Pi."
        } else {
            panel.allowedContentTypes = [.folder, .image, .pdf] + ["psb", "pcraft"].compactMap { UTType(filenameExtension: $0) }
            panel.message = "Wähle den Arbeitsordner oder eine einzelne Datei für PhotoCraft."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        photoCraft = nil
        restoreArchive = false
        lastEditable = nil
        photoCraftDocument = url
        UserDefaults.standard.set(url.path, forKey: "llmWorkFolder")
        chatSaved = false
        error = nil
    }

    private func sendToPi(_ text: String) {
        let withPhotoCraft = photoCraftEnabled
        let codingMode = piEnabled && !withPhotoCraft
        let document = withPhotoCraft || codingMode ? photoCraftDocument : nil
        if withPhotoCraft && document == nil {
            error = "Wähle zuerst oben rechts einen Arbeitsordner für PhotoCraft."
            return
        }
        // Mit den Werkzeugschritten, damit eine neue Pi-Sitzung (z. B. nach Stopp) weiß, was schon getan wurde.
        let context = messages.suffix(32).map { message in
            let done = (message.steps ?? []).filter { $0.kind != "thinking" }.map(\.text).joined(separator: "\n")
            return "\(message.role): \(message.text.prefix(1600))" + (done.isEmpty ? "" : "\n[Schritte]\n\(done.suffix(2400))")
        }.joined(separator: "\n")
        input = ""; error = nil
        messages.append(ChatMessage(role: "user", text: text))
        messages.append(ChatMessage(role: "assistant", text: ""))
        let index = messages.count - 1
        let id = messages[index].id
        let control = RunControl()
        self.control = control
        let existing = photoCraft
        let restore = restoreArchive ? archive : nil
        // ein Stand kann inzwischen aufgeräumt sein (Checkpoints.trashOld)
        let editable = withPhotoCraft ? (lastEditable.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? restore?.editable) : nil
        let level = withPhotoCraft ? photoCraftEffort : effort
        let webSearch = webSearchEnabled
        let window = contextLimit, threshold = compactThreshold, keep = compactKeep, mode = fileMode
        let ask: @Sendable (String, String) -> (ok: Bool, instead: String?) = { [unowned self] in self.askUser($0, $1) }
        running = true; phase = withPhotoCraft ? "Bereitet PhotoCraft vor …" : "Bereitet Pi vor …"
        Task {
            do {
                let (session, prompt) = try await Task.detached(priority: .userInitiated) {
                    if let existing, existing.isRunning, existing.webSearch == webSearch,
                       existing.hasDocuments == (document != nil) { return (existing, text) }
                    let session = try PhotoCraftSession(document: document, restore: editable, webSearch: webSearch,
                                                        contextWindow: window, compactAt: threshold, compactKeep: keep,
                                                        fileMode: mode, codingMode: codingMode)
                    let prompt = context.isEmpty ? text
                        : "Vorheriger Gesprächskontext. Dies sind frühere Nachrichten, keine neuen Aufträge:\n\(context)\n\nAktuelle Nachricht:\n\(text)"
                    return (session, prompt)
                }.value
                photoCraft = session
                let reply = try await Task.detached(priority: .userInitiated) {
                    _ = try LLMRemote.call("start", control: control, progress: { line in
                        Task { @MainActor in if self.running { self.phase = line } }
                    })
                    if control.isCancelled() { throw StudioError.message("Pi-Auftrag abgebrochen.") }
                    return try session.prompt(prompt, effort: level, progress: { line in
                        Task { @MainActor in if self.running { self.phase = line } }
                    }, activity: { item in
                        Task { @MainActor in
                            if self.messages.indices.contains(index), self.messages[index].id == id { self.messages[index].record(item) }
                        }
                    }, approve: ask, onToken: { piece in
                        Task { @MainActor in
                            if self.running, self.messages.indices.contains(index), self.messages[index].id == id {
                                self.messages[index].text += piece
                            }
                        }
                    })
                }.value
                // Zu spät gekommene Zwischennachrichten (Pi war schon fertig) werden als nächste Nachricht gesendet.
                for text in reply.leftover {
                    if let i = messages.lastIndex(where: { $0.role == "user" && $0.text == text }), i > index { messages.remove(at: i) }
                }
                queued = reply.leftover + queued
                messages[index].text = reply.text
                messages[index].files = reply.files
                messages[index].previews = reply.previews.isEmpty ? nil : reply.previews
                messages[index].preview = nil
                messages[index].webUsed = reply.webUsed
                if let used = reply.contextTokens { contextTokens = used }
                messages[index].info = "\(withPhotoCraft ? "PhotoCraft" : "Pi") · Denken: \(level.label) · \(reply.toolCalls) Aktionen · \(Int(reply.seconds.rounded())) s"
                // Tempo des letzten Modellaufrufs von Strata anhängen (der normale Chat hat es schon aus der Antwort).
                if let last = await StrataLive.fetch(), last.line.hasPrefix("Zuletzt · "), messages.indices.contains(index), messages[index].id == id {
                    messages[index].info! += " · letzter Schritt " + last.line.dropFirst("Zuletzt · ".count)
                }
                if withPhotoCraft {
                    lastEditable = Self.latestPSD([session.checkpoint] + reply.files) ?? lastEditable
                }
                // Die Antwort steht unter den Zwischennachrichten, die er während der Arbeit gelesen hat.
                if index < messages.count - 1 { messages.append(messages.remove(at: index)) }
            } catch {
                if control.isCancelled(), messages.indices.contains(index), messages[index].id == id {
                    // Gestoppt: Text, Denken und Schritte bleiben stehen; Pi behält den Verlauf, „weiter“ setzt fort.
                    if messages[index].text.isEmpty { messages[index].text = "*Gestoppt.*" }
                    let done = (messages[index].steps ?? []).filter { $0.kind == "tool" }.count
                    messages[index].info = "Gestoppt nach \(done) Schritten · schreib „weiter“, um fortzusetzen"
                } else {
                    self.error = error.localizedDescription
                    if messages[index].text.isEmpty && (messages[index].steps ?? []).isEmpty { messages.remove(at: index) }
                }
            }
            running = false; phase = nil; self.control = nil
            await refresh()
            if !finishQueue(ok: error == nil && !control.isCancelled()) { autosave() }
        }
    }

    private func pollLive() {
        live = nil
        Task {
            while running {
                let snapshot = await StrataLive.fetch()
                if running { live = snapshot }
                try? await Task.sleep(for: .seconds(1))
            }
            live = nil
        }
    }

    func stop() {
        answer(.deny(""))
        control?.cancel()
        photoCraft?.abort()
    }

    func clear() {
        guard !running, !savingChat else { return }
        chatRules = []
        photoCraft = nil
        photoCraftDocument = Self.savedWorkFolder
        piEnabled = false
        photoCraftEnabled = false
        webSearchEnabled = false
        archive = nil
        restoreArchive = false
        lastEditable = nil
        chatSaved = false
        contextTokens = nil; summary = nil; summaryUpTo = 0
        messages.removeAll()
        error = nil
    }

    func openChat(_ saved: SavedLLMChat) {
        guard !running, !savingChat else { return }
        clear()
        archive = saved
        messages = saved.messages
        photoCraftDocument = saved.source
        piEnabled = saved.piEnabled == true
        photoCraftEnabled = saved.photoCraftEnabled
        photoCraftEffort = saved.photoCraftEffort
        summary = saved.summary; summaryUpTo = min(saved.summaryUpTo ?? 0, saved.messages.count)
        restoreArchive = true
        lastEditable = saved.editable
        chatSaved = true
    }

    func saveChat() {
        guard !messages.isEmpty, !running, !savingChat else { return }
        let session = photoCraft
        let previous = archive
        let source = (session?.isRunning == true ? session?.sourceFile : nil) ?? photoCraftDocument
        let isFolder = source.flatMap { try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory } == true
        let documentName = source.map { piEnabled && !photoCraftEnabled ? $0.lastPathComponent : "vorlage.\($0.pathExtension)" }
        let editable = lastEditable
        let contents = messages.map { item in var value = item; if !value.files.isEmpty { value.preview = nil }; return value }
        let record = SavedLLMChat(id: previous?.id ?? UUID(), savedAt: Date(), messages: contents,
                                  photoCraftEnabled: photoCraftEnabled, photoCraftEffort: photoCraftEffort,
                                  documentName: isFolder ? nil : documentName,
                                  sourceFolder: isFolder ? source : nil, snapshot: UUID(),
                                  summary: summary, summaryUpTo: summary == nil ? nil : summaryUpTo,
                                  piEnabled: piEnabled ? true : nil)
        savingChat = true
        Task {
            defer { savingChat = false }
            do {
                try await Task.detached(priority: .utility) {
                    try record.save(source: source, editable: editable, replacing: previous)
                }.value
                archive = record
                if restoreArchive { photoCraftDocument = record.source }
                if editable == previous?.editable { lastEditable = record.editable }
                savedChats = SavedLLMChat.all()
                chatSaved = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func modelHistory(before end: Int) -> [[String: String]] {
        ChatCompaction.history(messages, summary: summary, from: summaryUpTo, before: end)
    }

    private func compactionPlan(before end: Int) -> (cut: Int, request: [String: Any])? {
        let perChar = contextTokens.map { Double($0) / Double(max(1, contextChars)) } ?? 1.0 / 3  // 1/3: vorsichtig, gemessen ~1/4,2
        return ChatCompaction.plan(messages, summary: summary, from: summaryUpTo, before: end, tokensPerChar: perChar,
                                   limit: compactThreshold, keep: ChatCompaction.retainedTokens(compactKeep, limit: compactThreshold))
    }

    /// Arbeitsordner (oder Einzeldatei), wie bei Coding-Agenten über Neustarts gemerkt.
    static var savedWorkFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: "llmWorkFolder"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func latestPSD(_ files: [URL]) -> URL? {
        files.filter { $0.pathExtension.lowercased() == "psd" }.compactMap { url -> (URL, Date)? in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (url, date)
        }.max { $0.1 < $1.1 }?.0
    }
}

struct LLMToolView: View {
    @ObservedObject var studio: LLMStudio
    static let textSize: CGFloat = 14.5  // etwas größer als die macOS-Grundschrift (13)
    @State private var instead = ""  // „Nein, stattdessen …“ auf der Rückfrage-Karte

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if studio.messages.isEmpty { start }
                        ForEach(studio.messages) { message in bubble(message).id(message.id) }
                        if let phase = studio.phase, studio.running {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(phase).foregroundStyle(.secondary) }
                        }
                        if let error = studio.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                    }
                    .font(.system(size: LLMToolView.textSize))
                    // Nutzt die Fensterbreite; erst ab sehr breiten Fenstern begrenzt, damit Zeilen lesbar bleiben.
                    .padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: 1600).frame(maxWidth: .infinity)
                }
                .onChange(of: studio.messages.last?.text) { _, _ in
                    if let last = studio.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: studio.messages.last?.reasoning) { _, _ in
                    if let last = studio.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: studio.messages.last?.files) { _, _ in
                    if let last = studio.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        .task { await studio.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(studio.serverRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Qwen3.8 Flash Next · Strata").font(.headline)
                Text("3× MI50 · \(studio.statusText)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(studio.chatSaved ? "Chat gespeichert" : "Chat speichern", systemImage: "tray.and.arrow.down") {
                    studio.saveChat()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(studio.messages.isEmpty || studio.chatSaved)
                if !studio.savedChats.isEmpty { Divider() }
                ForEach(studio.savedChats) { saved in
                    Button(saved.title) { studio.openChat(saved) }
                }
            } label: {
                Label("Chats", systemImage: "tray.full")
            }
            .disabled(studio.running || studio.savingChat)
            Toggle("Temporär", systemImage: studio.temporaryChat ? "eye.slash.fill" : "eye.slash", isOn: $studio.temporaryChat)
                .toggleStyle(.button)
                .help(studio.temporaryChat ? "Temporärer Chat: wird nicht gespeichert, solange das an ist." : "Chats werden nach jeder Antwort automatisch gespeichert (Chats-Menü). Einschalten für einen temporären Chat, der nicht gespeichert wird.")
            if !studio.messages.isEmpty {
                Button("Neuer Chat", systemImage: "square.and.pencil") { studio.clear() }
                    .disabled(studio.running || studio.savingChat)
            }
            Button(studio.serverRunning ? "Stoppen" : "Starten") { studio.toggleServer() }
                .disabled(studio.switching || studio.running)
                .help(studio.serverRunning ? "Gibt die drei Karten wieder frei" : "Belegt alle drei MI50, bis Strata stoppt")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat mit dem lokalen Sprachmodell").font(.title2.weight(.semibold))
            Text("Läuft komplett auf bigki. Beim ersten Senden startet Strata (~75 s) und belegt alle drei Karten; nach 20 min ohne Nachricht stoppt es von selbst. Unter jeder Antwort steht die Geschwindigkeit.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(["Schreib eine Python-Funktion, die …", "Erklär mir kurz …", "Fass diesen Text zusammen: …"], id: \.self) { example in
                    Button(example) { studio.input = example }.buttonStyle(.bordered)
                }
            }
        }.padding(.top, 40)
    }

    static let imageTypes: Set<String> = ["psd", "psb", "pcraft", "png", "jpg", "jpeg", "tif", "tiff", "webp", "heic", "gif", "bmp"]
    static let textTypes: Set<String> = ["md", "markdown", "txt", "csv", "json", "log"]

    /// Inhalt einer angehängten Textdatei: Markdown gerendert, sonst Monospace; gekürzt auf 20.000 Zeichen.
    /// Eine Vorschau groß, mehrere (z. B. „zeig mir alle 3 Dateien“) als Raster mit Dateinamen.
    @ViewBuilder private func previewGrid(_ previews: [ChatPreview]) -> some View {
        let single = previews.count == 1
        LazyVGrid(columns: [GridItem(.adaptive(minimum: single ? 600 : 300, maximum: single ? 900 : 560), alignment: .top)],
                  alignment: .leading, spacing: 12) {
            ForEach(Array(previews.enumerated()), id: \.offset) { _, item in
                if let image = NSImage(data: item.data) {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: single ? 560 : 420)
                        if let name = item.name { Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Vorschau \(item.name ?? "der PhotoCraft-Bearbeitung")")
                }
            }
        }
        .frame(maxWidth: single ? 900 : .infinity, alignment: .leading)
    }

    private func textPreview(_ file: URL) -> some View {
        let full = (try? String(contentsOf: file, encoding: .utf8)) ?? "(Datei nicht lesbar)"
        let text = full.count > 20_000 ? String(full.prefix(20_000)) + "\n\n… (gekürzt, ganze Datei mit „Öffnen“)" : full
        return VStack(alignment: .leading, spacing: 6) {
            if ["md", "markdown"].contains(file.pathExtension.lowercased()) {
                ForEach(Array(MarkdownBlock.parse(text, keepLineBreaks: true).enumerated()), id: \.offset) { $0.element.view }
            } else {
                Text(text).font(.caption.monospaced())
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Was Pi gemacht hat, untereinander: Denken (gekürzt, ganz im Tooltip), Werkzeug mit Argumenten, Fehler.
    private func stepList(_ steps: [ChatStep]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: step.kind == "thinking" ? "brain" : step.kind == "failed" ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                        .foregroundStyle(step.kind == "failed" ? Color.orange : Color.secondary).frame(width: 14)
                    Text(step.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .lineLimit(step.kind == "thinking" ? 4 : 3)
                        .foregroundStyle(step.kind == "thinking" ? .secondary : .primary)
                        .help(step.text)
                }
                .font(.caption)
            }
        }
        .textSelection(.enabled)
    }

    private func bubble(_ m: ChatMessage) -> some View {
        let mine = m.role == "user"
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if let reasoning = m.reasoning, !reasoning.isEmpty {
                DisclosureGroup("Gedankengang") {
                    Text(reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: Metrics.radius))
            }
            if let steps = m.steps, !steps.isEmpty {
                let live = studio.running && m.id == studio.messages.last(where: { $0.role == "assistant" })?.id
                let count = steps.filter { $0.kind != "thinking" }.count
                Group {
                    if live {
                        stepList(steps)
                    } else {
                        DisclosureGroup("Verlauf · \(count) \(count == 1 ? "Schritt" : "Schritte")") { stepList(steps).padding(.top, 4) }
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: Metrics.radius))
            }
            if !m.text.isEmpty || (m.reasoning == nil && m.steps == nil) {
                let text = m.text.isEmpty ? " " : m.text
                Group {
                    if mine {
                        Text(text)
                    } else {  // Antworten des Modells: Markdown mit Tabellen, Listen, Überschriften, Code
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(MarkdownBlock.parse(text, keepLineBreaks: true).enumerated()), id: \.offset) { $0.element.view }
                        }
                    }
                }
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(mine ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Metrics.radius))
            }
            // Die gerenderte PhotoCraft-Vorschau gehört zu Bild-Ergebnissen; hängt er nur Textdateien an, passt sie nicht dazu.
            let images = m.files.filter { Self.imageTypes.contains($0.pathExtension.lowercased()) }
            if let previews = m.previews, !previews.isEmpty, m.files.isEmpty || !images.isEmpty {
                previewGrid(previews)
            } else if m.files.isEmpty || !images.isEmpty,
               let preview = m.preview.flatMap(NSImage.init(data:)) ?? images.lazy.compactMap(NSImage.init(contentsOf:)).first {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 900, maxHeight: 560)
                    .accessibilityLabel("Vorschau der PhotoCraft-Bearbeitung")
            }
            ForEach(m.files.filter { Self.textTypes.contains($0.pathExtension.lowercased()) }, id: \.self) { file in
                DisclosureGroup("Vorschau: \(file.lastPathComponent)") {
                    textPreview(file).padding(.top, 4)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: Metrics.radius))
            }
            ForEach(m.files, id: \.self) { file in
                HStack {
                    Text(file.lastPathComponent).lineLimit(1)
                    if Self.imageTypes.contains(file.pathExtension.lowercased()) {
                        Button("In PhotoCraft öffnen", systemImage: "arrow.up.forward.app") {
                            NSWorkspace.shared.open([file], withApplicationAt: PhotoCraftSession.app,
                                                    configuration: NSWorkspace.OpenConfiguration())
                        }
                    } else {
                        Button("Öffnen", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(file) }
                    }
                    Button("Im Finder zeigen", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    .labelStyle(.iconOnly)
                }
                .font(.callout)
            }
            HStack(spacing: 8) {
                if !mine, !m.text.isEmpty {
                    Button("Kopieren", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(m.text, forType: .string)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption)
                    .help("Ganze Antwort kopieren (Markdown)")
                }
                if let info = m.info { Text(info).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let approval = studio.approval {
                VStack(alignment: .leading, spacing: 6) {
                    Label(approval.title, systemImage: "hand.raised.fill").font(.callout.weight(.semibold))
                    Text(approval.detail).font(.caption.monospaced()).textSelection(.enabled).lineLimit(8)
                    HStack {
                        Button("Ja") { studio.answer(.once) }.buttonStyle(.borderedProminent)
                            .help("Nur diesen einen Befehl erlauben")
                        if let keys = approval.keys {
                            Button("Ja, in diesem Chat: \(CommandRules.label(keys))") { studio.answer(.chat) }
                                .help("Bis „Neuer Chat“ nicht mehr fragen, wenn ein Befehl nur diese Programme nutzt")
                            Button("Ja, immer hier: \(CommandRules.label(keys))") { studio.answer(.always) }
                                .help("Für diesen Arbeitsordner merken (zurücksetzen im Sicherheitsmenü)")
                        }
                        Spacer()
                    }
                    if approval.keys == nil {
                        Text("Dieser Befehl ruft andere Programme auf oder setzt Befehle ein: nur einzeln freigebbar.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Nein, stattdessen … (optional)", text: $instead)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { studio.answer(.deny(instead)); instead = "" }
                        Button("Nein") { studio.answer(.deny(instead)); instead = "" }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Metrics.radius))
            }
            ForEach(Array(studio.queued.enumerated()), id: \.offset) { index, text in
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text(text).lineLimit(2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Entfernen", systemImage: "xmark") { studio.unqueue(index) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Metrics.radius))
                .help("Folgeprompt \(index + 1): wird nach der laufenden Antwort gesendet")
            }
            if studio.running, let live = studio.live {
                Label(live.line, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Pi", isOn: $studio.piEnabled).toggleStyle(.button)
                    .help("Programmieraufgaben mit Pi im Arbeitsordner ausführen.")
                Toggle("PhotoCraft verwenden", isOn: $studio.photoCraftEnabled).toggleStyle(.button)
                Toggle("Websuche", isOn: $studio.webSearchEnabled).toggleStyle(.button)
                    .help("Erlaubt bei Bedarf öffentliche Suchbegriffe direkt an Bing.")
                Spacer()
                compactMenu
                Menu {
                    Picker("Dateien im Arbeitsordner", selection: $studio.fileMode) {
                        ForEach(PhotoCraftSession.FileMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Text(studio.fileMode.detail)
                    if let summary = studio.rulesSummary {
                        Divider()
                        Text(summary)
                        Button("Freigaben zurücksetzen") { studio.forgetRules() }
                    }
                } label: {
                    Label(studio.fileMode.label, systemImage: studio.fileMode == .sandbox ? "lock.shield" : studio.fileMode == .ask ? "hand.raised" : "exclamationmark.shield")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Was Pi im Arbeitsordner darf: \(studio.fileMode.label). \(studio.fileMode.detail)")
                Button(studio.photoCraftDocument?.lastPathComponent ?? "Arbeitsordner wählen", systemImage: "folder") {
                    studio.pickWorkFolder()
                }
                .lineLimit(1).truncationMode(.middle)
                .help(studio.photoCraftDocument.map { "Arbeitsordner: \($0.path)" }
                      ?? "Arbeitsordner oder einzelne Datei für Pi und PhotoCraft wählen.")
            }
            .disabled(studio.running || studio.savingChat)
            composerInput
        }
        .padding(.horizontal, 28).padding(.vertical, 14).frame(maxWidth: 1600).frame(maxWidth: .infinity)
    }

    /// Kontextanzeige und Auswahl, ab wann automatisch zusammengefasst wird (wie /compact, nur von selbst).
    private var compactMenu: some View {
        let k = { (n: Int) in "\(Int((Double(n) / 1000).rounded()))k" }
        let used = (studio.running ? studio.live?.context : nil) ?? studio.contextTokens
        let limit = studio.contextLimit, latest = limit - LLMStudio.compactReserve
        return Menu {
            Picker("Automatisch zusammenfassen ab", selection: $studio.compactAt) {
                Text("Kurz vor der Grenze (\(k(latest)))").tag(0)
                ForEach([32_000, 64_000, 96_000, 128_000, 160_000, 200_000, 240_000].filter { $0 < latest }, id: \.self) { value in
                    Text("Ab \(k(value))").tag(value)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Bei Auto-Compact wörtlich behalten", selection: $studio.compactKeep) {
                ForEach(ChatCompaction.keepOptions, id: \.self) { value in
                    Text("\(k(value)) Token").tag(value)
                }
            }
            .pickerStyle(.inline)
            let retained = ChatCompaction.retainedTokens(studio.compactKeep, limit: studio.compactThreshold)
            if retained < studio.compactKeep {
                Text("Bei dieser Grenze bleiben höchstens \(retained.formatted()) Token wörtlich.")
            }
            Divider()
            Text("Jetzt sofort: /compact ins Eingabefeld schreiben")
        } label: {
            Text((used.map { "Kontext \(k($0)) / \(k(limit))" } ?? "Kontext \(k(limit))") + " · Compact ab \(k(studio.compactThreshold))")
                .font(.caption.monospacedDigit())
                .foregroundStyle((used ?? 0) > studio.compactThreshold - 20_000 ? .orange : .secondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Auto-Compact für Chat und Pi. Wähle die Grenze und wie viele der letzten Token wörtlich bleiben.")
    }

    private var composerInput: some View {
        let effort = studio.photoCraftEnabled ? $studio.photoCraftEffort : $studio.effort
        return HStack(alignment: .bottom, spacing: 10) {
            TextField("Nachricht an Qwen3.8 … (/compact fasst den Verlauf zusammen)", text: $studio.input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...8).font(.system(size: LLMToolView.textSize))
                .padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Metrics.radius))
                .onSubmit { studio.send() }
            DictationButton(text: $studio.input)
            Menu {
                Picker("", selection: effort) {
                    ForEach(ThinkingEffort.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(effort.wrappedValue == .none ? "Denken" : "Denken: \(effort.wrappedValue.label)",
                      systemImage: effort.wrappedValue == .none ? "brain" : "brain.fill")
            }
            .fixedSize()
            .help("Denkstufe wählen: Aus, Niedrig, Mittel, Hoch")
            if studio.running {
                Button("Stopp", systemImage: "stop.fill") { studio.stop() }
                Button("Danach", systemImage: "text.badge.plus") { studio.queueNext() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(studio.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Folgeprompt: in die Warteschlange, wird nach der laufenden Antwort gesendet (⇧⌘↩).")
                Button("Senden", systemImage: "arrow.up") { studio.send() }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(studio.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Während eines Pi-Auftrags liest das Modell die Nachricht nach dem aktuellen Schritt. Im normalen Chat kommt sie in die Warteschlange.")
            } else {
                Button("Senden", systemImage: "arrow.up") { studio.send() }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(studio.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (studio.photoCraftEnabled && studio.photoCraftDocument == nil))
            }
        }
    }
}

extension AgentOps {
    /// CLI/MCP: action status|start|stop|chat; chat takes prompt (+ system) or messages.
    static func llm(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        let action = (p["action"] as? String) ?? (p["prompt"] != nil || p["messages"] != nil ? "chat" : "status")
        var extra: [String: Any] = [:]
        if action == "chat" {
            var messages = p["messages"] as? [[String: Any]] ?? []
            if messages.isEmpty {
                guard let prompt = p["prompt"] as? String, !prompt.isEmpty else { throw StudioError.message("prompt oder messages fehlt.") }
                if let system = p["system"] as? String, !system.isEmpty { messages.append(["role": "system", "content": system]) }
                messages.append(["role": "user", "content": prompt])
            }
            let level = try ThinkingEffort.parse(p["reasoning_effort"] ?? p["thinking"])
            extra["messages"] = messages
            extra["thinking"] = level != .none
            extra["reasoning_effort"] = level.rawValue
            if let n = int(p, "max_tokens") { extra["max_tokens"] = n }
            if let t = double(p, "temperature") { extra["temperature"] = t }
            if let start = p["start"] as? Bool { extra["start"] = start }
        } else if action == "stop" {
            extra["force"] = (p["force"] as? Bool) ?? ((p["force"] as? String) == "true")
        }
        return try LLMRemote.call(action, extra, control: control, progress: progress)
    }
}
