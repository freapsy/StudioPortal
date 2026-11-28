import SwiftUI
import PhotosUI

struct Bubble: Identifiable { let id = UUID(); var role: String; var text: String; var reasoning: String? = nil; var info: String?; var files: [String] = [] }

enum PhoneThinkingEffort: String, CaseIterable, Identifiable {
    case none = "none", low = "low", medium = "medium", high = "high"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Aus"
        case .low: return "Niedrig"
        case .medium: return "Mittel"
        case .high: return "Hoch"
        }
    }
}

struct ChatView: View {
    @State private var messages: [Bubble] = []
    @State private var input = ""
    @State private var effort: PhoneThinkingEffort = .none
    @State private var server: [String: Any] = [:]
    @State private var webSearch = false
    @State private var photoCraft = false
    @State private var document: LibraryItem?
    @State private var documents: [LibraryItem] = []
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @State private var showingChats = false
    @State private var chats: [[String: String]] = []
    @State private var notice: String?
    @StateObject private var job = Job()
    @StateObject private var control = Job()
    @FocusState private var typing: Bool

    private var running: Bool { server["running"] as? Bool ?? false }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Qwen3.8 Flash Next").font(.title2.bold())
                                Text("Läuft auf bigki. Beim ersten Senden startet das Modell (~75 s) und belegt alle drei Karten; nach 20 min Pause stoppt es von selbst.")
                                    .foregroundStyle(.secondary)
                            }.padding(.top, 30)
                        }
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        if job.running, job.partial.isEmpty {
                            HStack { ProgressView(); Text(job.progress.isEmpty ? "denkt …" : job.progress).foregroundStyle(.secondary) }
                        }
                        if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                        if let error = job.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        Color.clear.frame(height: 1).id("end")
                    }.padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: job.partial) { _, text in
                    if !text.isEmpty, let last = messages.indices.last { messages[last].text = text }
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onChange(of: messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    if photoCraft || webSearch { modes.padding(.horizontal, 12).padding(.top, 8) }
                    composer
                }.background(.bar)
            }
            .navigationTitle("Chat").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 5) {
                        Circle().fill(running ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(control.running ? "…" : running ? "läuft" : "aus").font(.caption)
                    }.fixedSize().padding(.horizontal, 6)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Neuer Chat", systemImage: "square.and.pencil") {
                            messages.removeAll(); job.error = nil; notice = nil
                            photoCraft = false; webSearch = false; document = nil
                        }.disabled(job.running)
                        Button("Gespeicherte Chats", systemImage: "clock.arrow.circlepath") { showingChats = true }.disabled(job.running)
                        Button("Chat auf dem Mac mini speichern", systemImage: "tray.and.arrow.down") {
                            Task { await saveChat() }
                        }.disabled(messages.isEmpty || job.running)
                        Toggle("Websuche", isOn: $webSearch).disabled(job.running)
                        Toggle("PhotoCraft", isOn: $photoCraft).disabled(job.running)
                        Button(running ? "Modell stoppen" : "Modell starten", systemImage: running ? "stop.circle" : "play.circle") {
                            control.start("llm", running ? ["action": "stop", "force": true] : ["action": "start"], interval: 2)
                        }.disabled(control.running || job.running)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showingChats) { archive }
            .onChange(of: photoCraft) { _, enabled in
                if enabled {
                    if effort == .none { effort = .medium }
                    Task { await loadDocuments() }
                }
            }
            .onChange(of: photo) { _, selection in
                guard let selection else { return }
                Task {
                    uploading = true; defer { uploading = false }
                    do {
                        guard let data = try await selection.loadTransferable(type: Data.self) else { return }
                        document = .placeholder(try await API.upload(data))
                    } catch { notice = error.localizedDescription }
                }
            }
            .task { control.start("llm", ["action": "status"], interval: 0.5) }
            .onChange(of: control.running) { _, busy in if !busy, let r = control.result { server = r } }
            .onChange(of: job.running) { _, busy in if !busy { finish() } }
            .onChange(of: job.error) { _, error in if error != nil, messages.last?.text.isEmpty == true { messages.removeLast() } }
        }
    }

    private func bubble(_ m: Bubble) -> some View {
        let mine = m.role == "user"
        return VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if let reasoning = m.reasoning, !reasoning.isEmpty {
                DisclosureGroup("Gedankengang") {
                    Text(reasoning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(m.text.isEmpty ? " " : m.text).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(mine ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            ForEach(m.files, id: \.self) { file in
                NavigationLink {
                    FileDetail(path: file)
                } label: {
                    Label((file as NSString).lastPathComponent, systemImage: "doc")
                }.buttonStyle(.bordered)
            }
            if let info = m.info { Text(info).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Picker("", selection: $effort) {
                    ForEach(PhoneThinkingEffort.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: effort == .none ? "brain" : "brain.fill").font(.body)
                    if effort != .none { Text(effort.label).font(.caption2.weight(.semibold)) }
                }
            }
            .foregroundStyle(effort == .none ? Color.secondary : Color.accentColor).accessibilityLabel("Denkstufe")
            TextField("Nachricht", text: $input, axis: .vertical).lineLimit(1...6).focused($typing)
                .padding(.horizontal, 12).padding(.vertical, 8).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
            PhoneDictation(text: $input).disabled(job.running)
            if job.running {
                Button { job.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title) }.accessibilityLabel("Stopp")
            } else {
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || uploading || (photoCraft && document == nil))
                    .accessibilityLabel("Senden")
            }
        }
        .padding(.horizontal).padding(.vertical, 8).background(.bar)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !photoCraft || document != nil else { return }
        input = ""
        notice = nil
        messages.append(Bubble(role: "user", text: text))
        let history = messages.map { ["role": $0.role, "content": $0.text] }
        messages.append(Bubble(role: "assistant", text: ""))
        var arguments: [String: Any] = ["messages": history, "thinking": effort != .none, "reasoning_effort": effort.rawValue, "max_tokens": 8192]
        if photoCraft { arguments["document"] = document?.file }
        arguments["webSearch"] = webSearch
        job.start(photoCraft || webSearch ? "llm_pi" : "llm_chat", arguments, interval: 0.3)
    }

    private func finish() {
        guard let r = job.result, let last = messages.indices.last else { return }
        if let text = r["text"] as? String { messages[last].text = text }
        if let reasoning = r["reasoning"] as? String, !reasoning.isEmpty { messages[last].reasoning = reasoning }
        var parts: [String] = []
        if let tps = r["tokens_per_second"] as? Double { parts.append(String(format: "%.0f t/s", tps)) }
        if let pp = r["prompt_tokens_per_second"] as? Double { parts.append(String(format: "Prompt %.0f t/s", pp)) }
        if let n = r["completion_tokens"] as? Int { parts.append("\(n) Tokens") }
        if let s = r["seconds"] as? Double { parts.append(String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",")) }
        if let eff = r["reasoning_effort"] as? String, let level = PhoneThinkingEffort(rawValue: eff), level != .none {
            parts.append("Denken: \(level.label)")
        }
        messages[last].info = parts.joined(separator: " · ")
        server["running"] = true
        let files = r["files"] as? [String] ?? []
        messages[last].files = files
        if photoCraft, let edited = files.first(where: { $0.lowercased().hasSuffix(".psd") }) {
            document = .placeholder(edited)
        }
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if photoCraft {
                HStack {
                    Menu {
                        ForEach(documents) { item in Button(item.title) { document = item } }
                    } label: { Pill(icon: "folder", title: document?.title ?? "Bild aus Bibliothek") }
                    PhotosPicker(selection: $photo, matching: .images) {
                        Pill(icon: "photo", title: uploading ? "Lädt …" : "Fotos")
                    }
                }
            }
            if webSearch { Label("Websuche · Bing", systemImage: "globe").font(.caption).foregroundStyle(.secondary) }
        }.disabled(job.running || uploading)
    }

    private var archive: some View {
        NavigationStack {
            List(chats, id: \.self) { chat in
                Button(chat["title"] ?? "Chat") {
                    guard let id = chat["id"] else { return }
                    Task {
                        do {
                            let value = try await API.json("/api/chats/" + id)
                            let rows = value["messages"] as? [[String: String]] ?? []
                            messages = rows.map {
                                Bubble(role: $0["role"] ?? "user", text: $0["text"] ?? "", reasoning: $0["reasoning"], info: $0["info"])
                            }
                            webSearch = false; photoCraft = false; document = nil
                            notice = nil; showingChats = false
                        } catch { notice = error.localizedDescription; showingChats = false }
                    }
                }
            }
            .navigationTitle("Gespeicherte Chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showingChats = false } } }
            .task {
                do {
                    let value = try await API.json("/api/chats")
                    chats = (value["chats"] as? [[String: Any]] ?? []).map { ["id": $0["id"] as? String ?? "", "title": $0["title"] as? String ?? "Chat"] }
                } catch { notice = error.localizedDescription; showingChats = false }
            }
        }
    }

    private func saveChat() async {
        let rows = messages.filter { !$0.text.isEmpty }.map { message in
            var values = ["role": message.role, "text": message.text]
            values["reasoning"] = message.reasoning
            values["info"] = message.info
            return values
        }
        do {
            _ = try await API.json("/api/chats", method: "POST", body: ["messages": rows])
            notice = "Chat auf dem Mac mini gespeichert."
        } catch { notice = error.localizedDescription }
    }

    private func loadDocuments() async {
        do { documents = LibraryItem.parse(try await API.json("/api/library", ["kind": "image", "limit": "80"])) }
        catch { notice = error.localizedDescription }
    }
}
