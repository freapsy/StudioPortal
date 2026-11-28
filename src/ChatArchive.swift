import Foundation

struct SavedLLMChat: Codable, Identifiable {
    let id: UUID
    let savedAt: Date
    let messages: [ChatMessage]
    let photoCraftEnabled: Bool
    let photoCraftEffort: ThinkingEffort
    let documentName: String?
    let sourceFolder: URL?
    let snapshot: UUID
    /// Auto-Compact: Zusammenfassung ersetzt für das Modell die Nachrichten vor summaryUpTo.
    var summary: String? = nil
    var summaryUpTo: Int? = nil
    var piEnabled: Bool? = nil

    var title: String { String((messages.first { $0.role == "user" }?.text ?? "Chat").prefix(60)) }
    var folder: URL { Self.root.appendingPathComponent(id.uuidString).appendingPathComponent(snapshot.uuidString) }
    var source: URL? {
        if let sourceFolder { return sourceFolder }
        guard let documentName else { return nil }
        return folder.appendingPathComponent(documentName)
    }
    var editable: URL? { existing("bearbeitungsstand.psd") }

    private func existing(_ name: String) -> URL? {
        let file = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StudioPortal/Chats")
    }

    static func all() -> [Self] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("chat.json")) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }.sorted { $0.savedAt > $1.savedAt }
    }

    func save(source: URL?, editable: URL?, replacing previous: Self?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            if let source, let documentName {
                try fm.copyItem(at: source.resolvingSymlinksInPath(), to: folder.appendingPathComponent(documentName))
            }
            if let editable { try fm.copyItem(at: editable, to: folder.appendingPathComponent("bearbeitungsstand.psd")) }
            let target = folder.deletingLastPathComponent().appendingPathComponent("chat.json")
            try JSONEncoder().encode(self).write(to: target, options: .atomic)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        if let previous, previous.id == id { try? fm.removeItem(at: previous.folder) }
    }
}
