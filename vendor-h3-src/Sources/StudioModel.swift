import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistoryItem: Identifiable {
    var url: URL
    var metadata: RunMetadata?
    var date: Date
    var id: String { url.path }
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var settings = Settings() { didSet { saveSettings() } }
    @Published var history: [HistoryItem] = []
    @Published var selected: HistoryItem?
    @Published var running = false
    @Published var started = Date()
    @Published var progress = LogParser()
    @Published var machine = MachineStatus()
    @Published var errorMessage: String?
    private var control: RunControl?
    private let backend = Backend()
    private let settingsURL = studioRoot.appendingPathComponent("Einstellungen.json")

    init() {
        if (try? requireStori()) != nil, let data = try? Data(contentsOf: settingsURL), let saved = try? jsonDecoder().decode(Settings.self, from: data) { settings = saved }
        refreshHistory()
    }

    private func saveSettings() {
        guard (try? requireStori()) != nil else { return }
        do {
            try FileManager.default.createDirectory(at: studioRoot, withIntermediateDirectories: true)
            try jsonEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        } catch { errorMessage = "Die Einstellungen konnten nicht auf Stori gespeichert werden: \(error.localizedDescription)" }
    }

    func refreshHistory(select url: URL? = nil) {
        guard (try? requireStori()) != nil else { history = []; selected = nil; return }
        let files = (try? FileManager.default.contentsOfDirectory(at: picturesDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        history = files.filter { $0.pathExtension.lowercased() == "png" }.map { url in
            let sidecar = url.deletingPathExtension().appendingPathExtension("json")
            let metadata = (try? Data(contentsOf: sidecar)).flatMap { try? jsonDecoder().decode(RunMetadata.self, from: $0) }
            return HistoryItem(url: url, metadata: metadata, date: metadata?.date ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.date > $1.date }
        if let url { selected = history.first { $0.url == url } }
        else if let selected { self.selected = history.first { $0.url == selected.url } }
    }

    func refreshStatus() async {
        let current = await Task.detached(priority: .utility) { Backend().status() }.value
        if !Task.isCancelled { machine = current }
    }

    func start(forceNewSeed: Bool = false) {
        guard !running else { return }
        do { try requireStori() } catch { errorMessage = error.localizedDescription; return }
        settings.normalizeSize()
        if forceNewSeed || !settings.seedLocked { settings.seed = Int64.random(in: 0...Int64(Int32.max)) }
        let snapshot = settings
        do { _ = try snapshot.arguments(remoteReferences: snapshot.mode == "Bearbeiten" ? snapshot.references.map(\.path) : []) }
        catch { errorMessage = error.localizedDescription; return }
        let newControl = RunControl(); control = newControl; running = true; started = Date(); progress = LogParser()
        let service = backend
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let urls = try service.generate(snapshot, control: newControl) { state in
                    Task { @MainActor [weak self] in self?.progress = state }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.running = false; self.control = nil; self.refreshHistory(select: urls.last)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.running = false; self.control = nil; self.refreshHistory()
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func copyAccessKey() {
        do {
            let key = try ensureKey()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
            errorMessage = "Der Schlüssel dieses Macs ist kopiert. Schick ihn an Claude, damit bigki ihn freigibt. Außerdem muss Tailscale auf diesem Mac verbunden sein."
        } catch { errorMessage = "Der Schlüssel konnte nicht angelegt werden: \(error.localizedDescription)" }
    }

    func cancel() { progress.phase = "Wird abgebrochen"; control?.cancel() }

    func useSettings(_ item: HistoryItem, newSeed: Bool = false) {
        guard let saved = item.metadata?.settings else { errorMessage = "Für dieses Bild sind keine gespeicherten Einstellungen vorhanden."; return }
        settings = saved
        if newSeed { start(forceNewSeed: true) }
    }

    func addReferences(_ urls: [URL]) {
        let valid = urls.filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
        guard settings.references.count + valid.count <= 16 else { errorMessage = "Es sind höchstens 16 Referenzbilder möglich."; return }
        guard valid.count == urls.count else { errorMessage = "Bitte wähle PNG-, JPG- oder HEIC-Dateien."; return }
        settings.references.append(contentsOf: valid.map { Reference(path: $0.path) })
        if !valid.isEmpty { settings.mode = "Bearbeiten" }
    }

    func chooseReferences() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { addReferences(panel.urls) }
    }

    func moveReference(id: UUID, before target: UUID) {
        guard id != target, let from = settings.references.firstIndex(where: { $0.id == id }), let to = settings.references.firstIndex(where: { $0.id == target }) else { return }
        let item = settings.references.remove(at: from)
        settings.references.insert(item, at: min(to, settings.references.count))
    }

    func copy(_ item: HistoryItem) {
        guard let image = NSImage(contentsOf: item.url) else { errorMessage = "Das Bild konnte nicht geöffnet werden."; return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
    }

    func reveal(_ item: HistoryItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func trash(_ item: HistoryItem) {
        do {
            try requireStori()
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            let sidecar = item.url.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.trashItem(at: sidecar, resultingItemURL: nil) }
            refreshHistory()
        } catch { errorMessage = "Das Bild konnte nicht vollständig in den Papierkorb gelegt werden: \(error.localizedDescription)"; refreshHistory() }
    }
}
