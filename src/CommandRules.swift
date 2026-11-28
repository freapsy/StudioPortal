import Foundation

/// Freigaben wie bei Claude Code: „Ja“ (einmal), „Ja, in diesem Chat für mv“, „Ja, immer hier für mv“.
/// Eine Regel gilt für ein Programm (wie `Bash(mv:*)`), ein Befehl ist frei, wenn alle seine Teile frei sind.
enum CommandRules {
    /// Regel für write/edit an Dateien außerhalb des Ergebnisordners („alle Dateiänderungen“).
    static let files = "Dateien ändern"
    /// Umleitung in eine Datei (`>`), eigene Regel.
    static let redirect = ">"
    // Diese führen andere Befehle aus: eine Regel dafür würde alles erlauben, also immer einzeln fragen.
    private static let wrappers: Set<String> = ["xargs", "env", "sh", "bash", "zsh", "dash", "eval", "exec", "nohup", "time", "nice",
        "sudo", "command", "builtin", "source", ".", "osascript", "python", "python3", "node", "perl", "ruby", "find", "awk", "open"]

    /// Regelschlüssel einer Rückfrage; nil, wenn sich der Befehl nicht sicher zerlegen lässt (dann nur „Ja“ einmal).
    static func keys(title: String, detail: String) -> [String]? {
        guard title.hasPrefix("Befehl") else { return [files] }
        if detail.contains("$(") || detail.contains("`") || detail.contains("<(") || detail.contains(">(") { return nil }
        // harmlose Umleitungen (Fehler ins Nichts bzw. in die Ausgabe) zählen nicht als Schreiben
        let command = detail.replacingOccurrences(of: #"\d?>&\d|\d?>\s*/dev/null"#, with: " ", options: .regularExpression)
        var keys: [String] = []
        for segment in command.components(separatedBy: CharacterSet(charactersIn: ";|&\n")) {
            var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }  // VAR=wert befehl
            guard let first = words.first else { continue }
            let program = (first as NSString).lastPathComponent
            if wrappers.contains(program) { return nil }
            if !keys.contains(program) { keys.append(program) }
        }
        if command.contains(">"), !keys.contains(redirect) { keys.append(redirect) }
        return keys.isEmpty ? nil : keys
    }

    static func allowed(_ keys: [String]?, by rules: Set<String>) -> Bool {
        guard let keys, !keys.isEmpty else { return false }
        return keys.allSatisfy(rules.contains)
    }

    /// Für die Knöpfe: `mv, mkdir` bzw. „Dateiänderungen“.
    static func label(_ keys: [String]) -> String {
        keys == [files] ? "Dateiänderungen" : keys.map { $0 == redirect ? "Umleitung >" : $0 }.joined(separator: ", ")
    }
}
