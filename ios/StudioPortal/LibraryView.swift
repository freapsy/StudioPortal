import SwiftUI

struct LibraryItem: Identifiable, Codable, Hashable {
    var id: String { file }
    let kind, file, title, detail: String
    var preview: String?
    var date: String?
    var bytes: Int64?

    static func parse(_ response: [String: Any]) -> [Self] {
        (response["items"] as? [[String: Any]] ?? []).compactMap { row in
            guard let kind = row["kind"] as? String, let file = row["file"] as? String else { return nil }
            return .init(kind: kind, file: file, title: row["title"] as? String ?? "", detail: row["detail"] as? String ?? "",
                         preview: row["preview"] as? String, date: row["date"] as? String, bytes: (row["bytes"] as? NSNumber)?.int64Value)
        }
    }

    static func placeholder(_ path: String) -> Self {
        let ext = (path as NSString).pathExtension.lowercased()
        let kind: Kind
        switch ext {
        case "png", "jpg", "jpeg", "webp", "heic": kind = .image
        case "wav", "mp3", "m4a", "flac": kind = .music
        case "mp4", "mov": kind = .video
        default: kind = .model
        }
        return .init(kind: kind.key, file: path, title: (path as NSString).lastPathComponent, detail: "")
    }
}

struct LibraryView: View {
    @EnvironmentObject private var downloads: Downloads
    @State private var kind: Kind = .image
    @State private var downloaded = false
    @State private var search = ""
    @State private var items: [LibraryItem] = []
    @State private var error: String?
    @State private var loading = false
    @State private var settings = false

    private var visible: [LibraryItem] {
        if !downloaded { return items }
        return downloads.entries.values.filter {
            $0.item.kind == kind.key && (search.isEmpty || $0.item.title.localizedCaseInsensitiveContains(search))
        }.sorted { $0.added > $1.added }.map(\.item)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Dateityp", selection: $kind) {
                        ForEach(Kind.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Button { downloaded = false } label: { Pill(icon: "square.stack", title: "Alle", on: !downloaded) }
                        Button { downloaded = true } label: { Pill(icon: "arrow.down.circle", title: "Auf dem iPhone", on: downloaded) }
                        Spacer()
                    }.buttonStyle(.plain)
                    if !downloaded, let error {
                        Label(error, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary)
                    }
                    if loading && !downloaded && visible.isEmpty { ProgressView().padding() }
                    else if visible.isEmpty {
                        ContentUnavailableView(downloaded ? "Keine lokalen Dateien" : "Keine Ergebnisse",
                                               systemImage: downloaded ? "arrow.down.circle" : kind.icon)
                    } else if kind == .music {
                        LazyVStack(spacing: 4) {
                            ForEach(visible) { item in link(item) { row(item) } }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 146), spacing: 12)], spacing: 14) {
                            ForEach(visible) { item in link(item) { tile(item) } }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
            .navigationTitle("Bibliothek")
            .searchable(text: $search, prompt: "Dateien suchen")
            .toolbar {
                Button("Downloads und Cache", systemImage: "gearshape") { settings = true }
            }
            .sheet(isPresented: $settings) { DownloadSettings() }
            .refreshable { if !downloaded { await load() }; await downloads.sync() }
            .task(id: "\(kind.key)|\(search)|\(downloaded)") { if !downloaded { await load() } }
        }
    }

    private func link<Content: View>(_ item: LibraryItem, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink { FileDetail(path: item.file, title: item.title, preview: item.preview, item: item) } label: { content() }
            .buttonStyle(.plain)
    }

    private func row(_ item: LibraryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.headline)
                .frame(width: 48, height: 48).foregroundStyle(.tint)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            indicator(item)
        }.padding(.vertical, 7)
    }

    private func tile(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.secondary.opacity(0.08).aspectRatio(1, contentMode: .fit)
                .overlay {
                    if item.kind == "model" && item.preview == nil { Image(systemName: "cube").font(.title).foregroundStyle(.secondary) }
                    else { RemoteImage(path: item.preview ?? item.file, size: 320).scaledToFill() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) { indicator(item).padding(8) }
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
            if !item.detail.isEmpty { Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    @ViewBuilder private func indicator(_ item: LibraryItem) -> some View {
        if downloads.fetching.contains(item.file) {
            ProgressView().controlSize(.small)
        } else if let entry = downloads.entries[item.file] {
            Image(systemName: entry.saved ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                .font(.callout).padding(5).background(.regularMaterial, in: Circle())
                .accessibilityLabel(entry.saved ? "Offline gespeichert" : "Im Cache")
        }
    }

    private func load() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let response = try await API.json("/api/library", ["kind": kind.key, "search": search, "limit": "200"])
            guard !Task.isCancelled else { return }
            items = LibraryItem.parse(response)
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct DownloadSettings: View {
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.dismiss) private var dismiss
    @State private var clearSelection: Kind?
    @State private var confirmClear = false
    @State private var error: String?
    private var cache: [Downloads.Entry] { downloads.entries.values.filter { !$0.saved } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Kind.allCases) { kind in
                        Toggle(isOn: Binding(get: { downloads.autoKinds.contains(kind.key) }, set: { enabled in
                            if enabled { downloads.autoKinds.insert(kind.key) } else { downloads.autoKinds.remove(kind.key) }
                        })) { Label(kind.rawValue, systemImage: kind.icon) }
                    }
                    Stepper("Neueste je Dateityp: \(downloads.autoCount)", value: $downloads.autoCount, in: 1...30)
                    Picker("Speicherlimit", selection: $downloads.autoLimitMB) {
                        Text("250 MB").tag(250)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1000)
                        Text("2 GB").tag(2000)
                    }
                    Toggle("Nur über WLAN", isOn: $downloads.autoWiFi)
                    Toggle("Automatische Downloads behalten", isOn: $downloads.keepAutomatic)
                    Button("Jetzt synchronisieren", systemImage: "arrow.trianglehead.clockwise") { Task { await downloads.sync() } }
                        .disabled(downloads.autoKinds.isEmpty)
                    if let error = downloads.syncError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Automatisch laden")
                } footer: {
                    Text("StudioPortal lädt neue Ergebnisse je gewähltem Typ, solange die App aktiv ist. Dateien, die du selbst öffnest oder speicherst, können das Limit überschreiten.")
                }
                Section {
                    Toggle("Cache-Datei nach dem Ansehen entfernen", isOn: $downloads.discardAfterViewing)
                    ForEach(Kind.allCases) { kind in
                        let bytes = cache.filter { $0.item.kind == kind.key }.reduce(Int64(0)) { $0 + $1.bytes }
                        Button(role: .destructive) { clearSelection = kind; confirmClear = true } label: {
                            LabeledContent("Cache · " + kind.rawValue, value: Downloads.bytes(bytes))
                        }.disabled(bytes == 0)
                    }
                    Button("Gesamten Cache löschen", systemImage: "trash", role: .destructive) {
                        clearSelection = nil
                        confirmClear = true
                    }.disabled(cache.isEmpty)
                    LabeledContent("Offline gespeichert", value: Downloads.bytes(downloads.entries.values.filter(\.saved).reduce(0) { $0 + $1.bytes }))
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("Speicher")
                } footer: {
                    Text("Offline gespeicherte Dateien bleiben beim Leeren des Cache erhalten. Du kannst sie in der Dateiansicht einzeln entfernen.")
                }
            }
            .navigationTitle("Downloads & Cache")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .confirmationDialog(clearSelection.map { "Cache für \($0.rawValue) löschen?" } ?? "Gesamten Cache löschen?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Cache löschen", role: .destructive) {
                    do { try downloads.clearCache(kind: clearSelection?.key); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}
