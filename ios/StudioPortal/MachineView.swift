import SwiftUI

struct MachineView: View {
    @State private var status: [String: Any] = [:]
    @State private var error: String?
    @State private var setup = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange) }
                if let summary = status["summary"] as? String {
                    Section { Label(summary, systemImage: (status["reachable"] as? Bool ?? false) ? "checkmark.circle.fill" : "xmark.circle") }
                }
                Section("Grafikkarten") {
                    ForEach(Array((status["cards"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, card in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("MI50 #\(card["index"] as? Int ?? 0)").font(.headline)
                                Spacer()
                                if let t = card["temp_c"] as? Double { Text("\(Int(t)) °C").monospacedDigit() }
                                if let b = card["busy_percent"] as? Double { Text("\(Int(b)) %").monospacedDigit().foregroundStyle(.secondary) }
                            }
                            Text(job(card)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                let queue = status["queue"] as? [[String: Any]] ?? []
                if !queue.isEmpty {
                    Section("Warteschlange") {
                        ForEach(Array(queue.enumerated()), id: \.offset) { _, q in
                            VStack(alignment: .leading) { Text(q["label"] as? String ?? ""); Text(q["origin"] as? String ?? "").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                let sessions = status["blender_sessions"] as? [[String: Any]] ?? []
                if !sessions.isEmpty {
                    Section("Blender") {
                        ForEach(Array(sessions.enumerated()), id: \.offset) { _, s in
                            Text("\(s["name"] as? String ?? "") · \(s["owner"] as? String ?? "")")
                        }
                    }
                }
            }
            .navigationTitle("Rechner")
            .toolbar { Button("Verbindung", systemImage: "gearshape") { setup = true } }
            .sheet(isPresented: $setup) { SetupView { setup = false } }
            .refreshable { await load() }
            .task { while !Task.isCancelled { await load(); try? await Task.sleep(for: .seconds(5)) } }
        }
    }

    private func job(_ card: [String: Any]) -> String {
        if card["foreign"] as? Bool == true { return "fremd belegt" + ((card["foreign_by"] as? String).map { " (\($0))" } ?? "") }
        if let job = card["job"] as? String, !job.isEmpty { return job + ((card["origin"] as? String).map { " · \($0)" } ?? "") }
        return String(format: "frei · %.1f GB", card["vram_gb"] as? Double ?? 0)
    }

    private func load() async {
        do { status = try await API.json("/api/status"); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct SetupView: View {
    var done: () -> Void
    @State private var url = API.baseURL
    @State private var token = API.token
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adresse", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Schlüssel", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Den Schlüssel zeigt `studioportal setup-iphone` auf dem Mac mini. Tailscale muss auf dem iPhone an sein.")
                }
                Section {
                    Button { Task { await test() } } label: { testing ? AnyView(ProgressView()) : AnyView(Text("Verbinden")) }
                        .disabled(url.isEmpty || token.isEmpty || testing)
                    if let result { Text(result).foregroundStyle(result.hasPrefix("✓") ? .green : .orange) }
                }
            }
            .navigationTitle("Verbindung")
            .toolbar { if !API.token.isEmpty { Button("Fertig", action: done) } }
        }
    }

    private func test() async {
        testing = true; defer { testing = false }
        API.baseURL = url.trimmingCharacters(in: .whitespaces); API.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let r = try await API.json("/api/ping")
            result = "✓ verbunden mit \(r["mac"] as? String ?? "Mac")"
            try? await Task.sleep(for: .milliseconds(600))
            done()
        } catch { result = error.localizedDescription }
    }
}
