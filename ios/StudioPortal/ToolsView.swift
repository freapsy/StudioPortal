import SwiftUI

struct ToolsView: View {
    @StateObject private var job = Job()
    @State private var selected: Set<String> = []
    @State private var images: [LibraryItem] = []
    @State private var models: [LibraryItem] = []
    @State private var model: String?
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("3D-Import") {
                    TextField("HTTPS-Modell-Link", text: $link).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Modell importieren", systemImage: "square.and.arrow.down") {
                        job.start("import_model", ["source": link])
                    }.disabled(job.running || link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Blender · iPhone-Sitzung auf bigki") {
                    Picker("3D-Datei", selection: $model) {
                        Text("Auswählen").tag(String?.none)
                        ForEach(models) { Text($0.title).tag(Optional($0.file)) }
                    }
                    Button("Datei in Blender öffnen", systemImage: "folder") {
                        if let model { job.start("blender_mobile", ["action": "open", "file": model]) }
                    }.disabled(model == nil || job.running)
                    Button("Szene anzeigen", systemImage: "list.bullet") { blender("scene") }.disabled(job.running)
                    Button("Vorschau erstellen", systemImage: "viewfinder") { blender("look") }.disabled(job.running)
                    Button("Mesh prüfen", systemImage: "checkmark.shield") { blender("check") }.disabled(job.running)
                    Button("Einzelbild rendern", systemImage: "camera.aperture") { blender("render") }.disabled(job.running)
                    Button("Szene in Bibliothek speichern", systemImage: "externaldrive") { blender("save") }.disabled(job.running)
                }
                Section("Bilder vergleichen") {
                    NavigationLink {
                        List(images) { item in
                            Button {
                                if selected.contains(item.file) { selected.remove(item.file) }
                                else if selected.count < 8 { selected.insert(item.file) }
                            } label: {
                                HStack {
                                    RemoteImage(path: item.file, size: 128).frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(item.title).foregroundStyle(.primary)
                                    Spacer()
                                    if selected.contains(item.file) { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }.navigationTitle("Vergleichsbilder")
                    } label: { LabeledContent("Bilder wählen", value: String(selected.count)) }
                    Button("Vergleich erstellen", systemImage: "rectangle.split.2x1") {
                        job.start("compare_images", ["images": images.map(\.file).filter { selected.contains($0) }])
                    }.disabled(selected.count < 2 || job.running)
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                if job.running {
                    Section {
                        ProgressView(job.progress)
                        Button("Abbrechen", role: .cancel) { job.cancel() }
                    }
                } else if let error = job.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                } else if let result = job.result {
                    Section("Ergebnis") {
                        if let path = (result["saved"] ?? result["file"] ?? result["image"]) as? String {
                            NavigationLink { FileDetail(path: path, preview: result["preview"] as? String) } label: {
                                Label("Datei ansehen", systemImage: "eye")
                            }
                        } else {
                            let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                            Text(data.flatMap { String(data: $0, encoding: .utf8) } ?? "Fertig")
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Werkzeuge")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func blender(_ action: String) { job.start("blender_mobile", ["action": action], interval: 1) }
    private func load() async {
        do {
            images = LibraryItem.parse(try await API.json("/api/library", ["kind": "image", "limit": "100"]))
            models = LibraryItem.parse(try await API.json("/api/library", ["kind": "model", "limit": "100"]))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
