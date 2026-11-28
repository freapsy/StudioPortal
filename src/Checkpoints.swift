import Foundation

/// Jede PhotoCraft-Sitzung legt im gemeinsamen Ergebnisordner einen versteckten Arbeitsstand `.studioportal-stand-<id>.psd` an.
/// Gespeicherte Chats haben eine eigene Kopie (`bearbeitungsstand.psd` im Archiv), alte Stände braucht also niemand mehr.
enum Checkpoints {
    static let prefix = ".studioportal-stand-"

    /// Legt Stände, die länger als `age` nicht geändert wurden, in den Papierkorb (wiederherstellbar). Der eigene bleibt.
    @discardableResult
    static func trashOld(in folder: URL, keep: URL, olderThan age: TimeInterval = 7 * 86_400, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        var trashed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) && name.hasSuffix(".psd") {
            let url = folder.appendingPathComponent(name)
            guard name != keep.lastPathComponent, let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true, let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { trashed.append(name) }
        }
        return trashed
    }
}
