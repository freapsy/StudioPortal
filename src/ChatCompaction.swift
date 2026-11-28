import Foundation

/// Auto-Compact für den normalen LLM-Chat (Pi macht es in PhotoCraft selbst, mit denselben Grenzen).
enum ChatCompaction {
    static let defaultKeep = 20_000
    static let keepOptions = [defaultKeep, 30_000, 40_000]

    static func retainedTokens(_ requested: Int, limit: Int) -> Int {
        min(requested, max(0, limit / 3))
    }

    /// Was das Modell sieht: ggf. die Zusammenfassung, dann die Nachrichten ab `from` bis vor `end`.
    static func history(_ messages: [ChatMessage], summary: String?, from: Int, before end: Int) -> [[String: String]] {
        let head = summary.map { [["role": "system", "content": "Zusammenfassung des bisherigen Gesprächs (ersetzt die älteren Nachrichten):\n\($0)"]] } ?? []
        return head + messages[min(from, end)..<end].map { ["role": $0.role, "content": $0.text] }
    }

    /// nil, solange der Verlauf geschätzt unter `limit` Token bleibt (und unter 380 Nachrichten, Grenze des Workers: 400).
    /// Sonst die Anfrage, die alles vor `cut` zusammenfasst; ab `cut` (eine Nutzernachricht, ~`keep` Token) bleibt wörtlich.
    /// `force` (/compact): alles bis `end` zusammenfassen, egal wie groß; `focus` ergänzt die Anweisung.
    static func plan(_ messages: [ChatMessage], summary: String?, from: Int, before end: Int, tokensPerChar: Double,
                     limit: Int, keep: Int, force: Bool = false, focus: String? = nil) -> (cut: Int, request: [String: Any])? {
        var cut = end
        if !force {
            let sent = history(messages, summary: summary, from: from, before: end)
            let chars = sent.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
            guard Double(chars) * tokensPerChar > Double(limit) || sent.count > 380 else { return nil }
            cut = end - 1  // die neue Nachricht bleibt immer
            var kept = messages[cut].text.count
            while cut > from, Double(kept + messages[cut - 1].text.count) * tokensPerChar < Double(keep), end - cut < 300 {
                cut -= 1; kept += messages[cut].text.count
            }
            while cut < end - 1, messages[cut].role != "user" { cut += 1 }
        }
        guard cut > from else { return nil }
        let earlier = summary.map { "Bisherige Zusammenfassung:\n\($0)\n\n" } ?? ""
        let transcript = earlier + messages[from..<cut].map { "\($0.role == "user" ? "Nutzer" : "Assistent"): \($0.text)" }.joined(separator: "\n\n")
        let instruction = "Fasse das folgende Gespräch so zusammen, dass es nahtlos fortgesetzt werden kann. Behalte alle Fakten, Entscheidungen, Zahlen, Namen, Dateinamen, Code-Stellen, offenen Fragen und Wünsche des Nutzers. Knapp, in Stichpunkten, auf Deutsch, ohne Einleitung."
            + (focus.map { " Besonders wichtig: \($0)" } ?? "")
        return (cut, ["messages": [["role": "system", "content": instruction], ["role": "user", "content": transcript]],
                      "thinking": false, "reasoning_effort": "none", "max_tokens": 4096])
    }
}
