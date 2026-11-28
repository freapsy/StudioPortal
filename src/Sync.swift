import Foundation
import SwiftUI

/// MacBook ↔ Mac mini: the Mac mini (with Stori) is the hub, the MacBook syncs to it over Tailscale/SSH.
/// Files are never changed after they are made, so sync only copies missing files in both directions
/// (rsync --ignore-existing) and applies deletions recorded in each Mac's ledger. Both Macs have a switch;
/// the MacBook only syncs while the switch is on on both sides.
let supportDirectory: URL = {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StudioPortal", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

struct DeletionRecord: Codable, Hashable {
    var kind: String
    var path: String
    var date: Date
}

enum SyncLedger {
    static let url = supportDirectory.appendingPathComponent("geloescht.json")
    private static let lock = NSLock()

    static func folders() -> [String: URL] {
        ["image": picturesDirectory, "music": musicDirectory, "speech": speechDirectory, "video": videosDirectory, "model": modelsDirectory]
    }

    static func load() -> [DeletionRecord] {
        (try? Data(contentsOf: url)).flatMap { try? jsonDecoder().decode([DeletionRecord].self, from: $0) } ?? []
    }

    static func append(_ records: [DeletionRecord]) {
        guard !records.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        let known = Set(all.map { $0.kind + "/" + $0.path })
        all += records.filter { !known.contains($0.kind + "/" + $0.path) }
        if all.count > 5000 { all.removeFirst(all.count - 5000) }
        try? jsonEncoder().encode(all).write(to: url, options: .atomic)
    }

    static func record(for file: URL) -> DeletionRecord? {
        let path = file.standardizedFileURL.path
        for (kind, folder) in folders() {
            let base = folder.standardizedFileURL.path + "/"
            if path.hasPrefix(base) {
                let relative = String(path.dropFirst(base.count))
                guard !relative.isEmpty, !relative.contains("..") else { return nil }
                return DeletionRecord(kind: kind, path: relative, date: Date())
            }
        }
        return nil
    }

    /// Moves the given library files of this Mac to the Trash (used for deletions made on the other Mac).
    @discardableResult
    static func apply(_ records: [DeletionRecord]) -> Int {
        var count = 0
        let folders = folders()
        for record in records {
            guard let folder = folders[record.kind], !record.path.contains(".."), !record.path.hasPrefix("/") else { continue }
            let file = folder.appendingPathComponent(record.path)
            if FileManager.default.fileExists(atPath: file.path), (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) != nil {
                count += 1
            }
        }
        append(records)
        return count
    }
}

@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()
    nonisolated static let defaultPeer = "du@DEIN-MAC"

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "syncEnabled"); writeFlag(); if enabled { schedule() } } }
    @Published var peer: String { didSet { UserDefaults.standard.set(peer, forKey: "syncPeer") } }
    @Published var running = false
    @Published var lastSync: Date?
    @Published var lastError: String?
    @Published var lastSummary = ""
    var onReceived: (() -> Void)?
    private var pending: Task<Void, Never>?
    private var timer: Timer?

    /// The Mac mini is the hub: it does not start syncs itself, the MacBook comes to it.
    var isHub: Bool { peer.isEmpty }

    nonisolated static func recordDeletion(_ urls: [URL]) {
        SyncLedger.append(urls.compactMap { SyncLedger.record(for: $0) })
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "syncEnabled")
        peer = UserDefaults.standard.string(forKey: "syncPeer") ?? (machineName == "Mac mini" ? "" : Self.defaultPeer)
        if let mark = Self.readMark() { lastSync = mark.date; lastSummary = isHub ? "mit \(mark.from)" : "" }
        writeFlag()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in Task { @MainActor in self?.schedule() } }
    }

    var shortStatus: String {
        if running { return "Synchronisiere …" }
        if let lastError { return lastError }
        if isHub { return lastSync.map { "Zuletzt \($0.formatted(.relative(presentation: .named))) \(lastSummary)" } ?? "Wartet auf das MacBook" }
        return lastSync.map { "Synchronisiert \($0.formatted(.relative(presentation: .named)))" } ?? "Noch nicht synchronisiert"
    }

    private func writeFlag() {
        try? Data((enabled ? "1" : "0").utf8).write(to: supportDirectory.appendingPathComponent("sync-an"))
    }

    nonisolated static func flagEnabled() -> Bool {
        (try? String(contentsOf: supportDirectory.appendingPathComponent("sync-an"), encoding: .utf8)) == "1"
    }

    struct Mark: Codable { var from: String; var date: Date }
    nonisolated static func readMark() -> Mark? {
        (try? Data(contentsOf: supportDirectory.appendingPathComponent("letzter-sync.json"))).flatMap { try? jsonDecoder().decode(Mark.self, from: $0) }
    }
    nonisolated static func writeMark(_ mark: Mark) {
        try? jsonEncoder().encode(mark).write(to: supportDirectory.appendingPathComponent("letzter-sync.json"), options: .atomic)
    }

    /// Debounced: syncs a few seconds after a job finished, on launch and every ten minutes.
    func schedule() {
        guard enabled, !isHub else {
            if isHub, let mark = Self.readMark() { lastSync = mark.date; lastSummary = "mit \(mark.from)" }
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard enabled, !isHub, !running else { return }
        running = true; lastError = nil
        let peer = self.peer
        let result = await Task.detached(priority: .utility) { () -> Result<(Int, Int, Int), Error> in
            do { return .success(try SyncEngine.run(peer: peer)) } catch { return .failure(error) }
        }.value
        running = false
        switch result {
        case let .success((pulled, pushed, deleted)):
            lastSync = Date(); lastError = nil
            var parts: [String] = []
            if pulled > 0 { parts.append("↓ \(pulled)") }
            if pushed > 0 { parts.append("↑ \(pushed)") }
            if deleted > 0 { parts.append("🗑 \(deleted)") }
            lastSummary = parts.joined(separator: " ")
            if pulled > 0 || deleted > 0 { onReceived?() }
        case let .failure(error):
            lastError = error.localizedDescription
        }
    }

    // MARK: - The actual work (background thread)

    nonisolated private static func shell(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 600) throws -> String {
        let process = Process(), output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output; process.standardError = errors; process.standardInput = stdin
        try process.run()
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errorText = ""
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async { errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().suffix(800), as: UTF8.self); group.leave() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); group.wait(); killer.cancel()
        guard process.terminationStatus == 0 else {
            throw StudioError.message(errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Fehler \(process.terminationStatus)" : errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=20"]

    nonisolated private static func remote(_ peer: String, _ command: String, input: Data? = nil) throws -> String {
        try shell("/usr/bin/ssh", sshOptions + [peer, "\"$HOME/.local/bin/studioportal\" \(command)"], input: input)
    }

    nonisolated static func run(peer: String) throws -> (Int, Int, Int) {
        let infoText: String
        do { infoText = try remote(peer, "sync-info") }
        catch { throw StudioError.message("Mac mini nicht erreichbar oder StudioPortal dort nicht eingerichtet.") }
        guard let info = try? JSONSerialization.jsonObject(with: Data(infoText.utf8)) as? [String: Any],
              let folders = info["folders"] as? [String: String] else { throw StudioError.message("Antwort vom Mac mini unlesbar.") }
        guard info["enabled"] as? Bool == true else { throw StudioError.message("Sync ist auf dem Mac mini ausgeschaltet.") }
        if info["storiMissing"] as? Bool == true { throw StudioError.message("Stori ist am Mac mini nicht eingebunden.") }

        // 1. deletions both ways
        let remoteDeleted = (info["deleted"] as? [[String: Any]] ?? []).compactMap { item -> DeletionRecord? in
            guard let kind = item["kind"] as? String, let path = item["path"] as? String else { return nil }
            return DeletionRecord(kind: kind, path: path, date: (item["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date())
        }
        let known = Set(SyncLedger.load().map { $0.kind + "/" + $0.path })
        let deletedHere = SyncLedger.apply(remoteDeleted.filter { !known.contains($0.kind + "/" + $0.path) })
        let local = SyncLedger.load()
        let remoteKnown = Set(remoteDeleted.map { $0.kind + "/" + $0.path })
        let toSend = local.filter { !remoteKnown.contains($0.kind + "/" + $0.path) }
        if !toSend.isEmpty { _ = try remote(peer, "sync-delete", input: try jsonEncoder().encode(toSend)) }

        // 2. files both ways (never overwrite, never delete)
        var pulled = 0, pushed = 0
        let excludes = ["--exclude", ".studioportal-*", "--exclude", ".auftrag-*", "--exclude", ".DS_Store", "--exclude", "*.tmp", "--exclude", "*.blend@", "--exclude", "*.blend1"]
        for (kind, folder) in SyncLedger.folders() {
            guard let remoteFolder = folders[kind] else { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let escaped = remoteFolder.replacingOccurrences(of: " ", with: "\\ ") + "/"
            let before = count(folder)
            _ = try remote(peer, "sync-prepare \(kind)")
            let pushOut = try shell("/usr/bin/rsync", ["-a", "--ignore-existing", "--out-format=%n"] + excludes +
                                    ["-e", "ssh " + sshOptions.joined(separator: " "), folder.path + "/", "\(peer):\(escaped)"])
            pushed += pushOut.split(separator: "\n").filter { !$0.hasSuffix("/") }.count
            _ = try shell("/usr/bin/rsync", ["-a", "--ignore-existing"] + excludes +
                          ["-e", "ssh " + sshOptions.joined(separator: " "), "\(peer):\(escaped)", folder.path + "/"])
            pulled += max(0, count(folder) - before)
        }
        let mark = try jsonEncoder().encode(Mark(from: machineName, date: Date()))
        _ = try? remote(peer, "sync-mark", input: mark)
        writeMark(Mark(from: info["machine"] as? String ?? "Mac mini", date: Date()))
        return (pulled, pushed, deletedHere)
    }

    nonisolated private static func count(_ folder: URL) -> Int {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var total = 0
        while let item = enumerator?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { total += 1 }
        }
        return total
    }
}
