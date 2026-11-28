import CryptoKit
import SwiftUI

@MainActor
final class Downloads: ObservableObject {
    struct Entry: Codable, Identifiable {
        let item: LibraryItem
        let saved: Bool
        let bytes: Int64
        let added: Date
        var id: String { item.file }
    }

    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var fetching: Set<String> = []
    @Published private(set) var syncError: String?
    @Published var autoKinds: Set<String> = [] { didSet { defaults.set(Array(autoKinds), forKey: "autoDownloadKinds") } }
    @Published var autoWiFi = true { didSet { defaults.set(autoWiFi, forKey: "autoDownloadWiFi") } }
    @Published var keepAutomatic = false { didSet { defaults.set(keepAutomatic, forKey: "keepAutomaticDownloads") } }
    @Published var discardAfterViewing = false { didSet { defaults.set(discardAfterViewing, forKey: "discardViewedDownloads") } }
    @Published var autoCount = 5 { didSet { defaults.set(autoCount, forKey: "autoDownloadCount") } }
    @Published var autoLimitMB = 1000 { didSet { defaults.set(autoLimitMB, forKey: "autoDownloadLimitMB") } }
    private let defaults = UserDefaults.standard
    private let fm = FileManager.default
    private var transfers: [String: Task<URL, Error>] = [:]
    private var desiredOffline: Set<String> = []
    private var syncing = false
    private let root: URL

    init(storageRoot: URL? = nil) {
        let key = Self.hash(API.baseURL)
        root = storageRoot ?? URL.applicationSupportDirectory.appending(path: "StudioPortal/Downloads/\(key)", directoryHint: .isDirectory)
        autoKinds = Set(defaults.stringArray(forKey: "autoDownloadKinds") ?? [])
        autoWiFi = defaults.object(forKey: "autoDownloadWiFi") == nil || defaults.bool(forKey: "autoDownloadWiFi")
        keepAutomatic = defaults.bool(forKey: "keepAutomaticDownloads")
        discardAfterViewing = defaults.bool(forKey: "discardViewedDownloads")
        autoCount = defaults.object(forKey: "autoDownloadCount") as? Int ?? 5
        autoLimitMB = defaults.object(forKey: "autoDownloadLimitMB") as? Int ?? 1000
        if let data = try? Data(contentsOf: manifest), let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored.filter { fm.fileExists(atPath: location($0.value).path) }
        }
    }

    private var manifest: URL { root.appending(path: "index.json") }

    nonisolated private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func location(_ entry: Entry) -> URL {
        root.appending(path: Self.hash(entry.item.file), directoryHint: .isDirectory)
            .appending(path: (entry.item.file as NSString).lastPathComponent)
    }

    private func publish(_ updated: [String: Entry]) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        entries = updated
    }

    func local(_ path: String) -> URL? {
        guard let entry = entries[path], fm.fileExists(atPath: location(entry).path) else { return nil }
        return location(entry)
    }

    func fetch(_ item: LibraryItem, keep: Bool = false, wifiOnly: Bool = false, limit: Int64? = nil) async throws -> URL {
        if keep { desiredOffline.insert(item.file) }
        if let url = local(item.file), let entry = entries[item.file], entry.item.date == item.date || item.date == nil {
            defer { desiredOffline.remove(item.file) }
            if keep && !entry.saved {
                var updated = entries
                updated[item.file] = Entry(item: entry.item, saved: true, bytes: entry.bytes, added: entry.added)
                try publish(updated)
            }
            return url
        }
        if let transfer = transfers[item.file] { return try await transfer.value }
        fetching.insert(item.file)
        let transfer = Task { () throws -> URL in
            let file = try await API.download(item.file, wifiOnly: wifiOnly)
            defer { try? fm.removeItem(at: file) }
            let bytes = Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            if let limit, bytes > limit {
                throw API.Failure(errorDescription: "Datei passt nicht ins Limit für automatische Downloads.")
            }
            let entry = Entry(item: item, saved: desiredOffline.contains(item.file) || entries[item.file]?.saved == true, bytes: bytes, added: .now)
            let target = location(entry)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: file) }
            else { try fm.moveItem(at: file, to: target) }
            var updated = entries
            updated[item.file] = entry
            try publish(updated)
            return target
        }
        transfers[item.file] = transfer
        defer {
            transfers[item.file] = nil
            fetching.remove(item.file)
            desiredOffline.remove(item.file)
        }
        return try await transfer.value
    }

    func remove(_ path: String, cacheOnly: Bool) throws {
        guard let entry = entries[path], !cacheOnly || !entry.saved else { return }
        let url = location(entry).deletingLastPathComponent()
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        var updated = entries
        updated.removeValue(forKey: path)
        try publish(updated)
    }

    func clearCache(kind: String?) throws {
        for entry in Array(entries.values) where !entry.saved && (kind == nil || entry.item.kind == kind) {
            try remove(entry.id, cacheOnly: true)
        }
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    func sync() async {
        guard !syncing, !autoKinds.isEmpty else { return }
        syncing = true
        defer { syncing = false }
        do {
            for kind in Kind.allCases where autoKinds.contains(kind.key) {
                let result = try await API.json("/api/library", ["kind": kind.key, "limit": String(autoCount)])
                for item in LibraryItem.parse(result) where autoKinds.contains(kind.key) {
                    if Task.isCancelled { return }
                    let used = entries.values.reduce(Int64(0)) { $0 + $1.bytes } - (entries[item.file]?.bytes ?? 0)
                    let available = Int64(autoLimitMB) * 1_000_000 - used
                    guard available > 0, item.bytes.map({ $0 <= available }) != false else { continue }
                    _ = try await fetch(item, keep: keepAutomatic, wifiOnly: autoWiFi, limit: available)
                }
            }
            syncError = nil
        } catch {
            if !Task.isCancelled { syncError = error.localizedDescription }
        }
    }
}
