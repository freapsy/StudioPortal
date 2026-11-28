import Foundation

/// Live-Werte von Strata (GET /metrics, nur lesend) für die Anzeige im Mac-Chat, während eine Antwort läuft:
/// Prompt lesen (Token, davon aus dem Zwischenspeicher, t/s), Schreiben (t/s, Token) und der belegte Kontext.
enum StrataLive {
    struct Snapshot: Equatable {
        var line: String
        var context: Int?
        var limit: Int?
    }

    /// Strata-Schlüssel aus Pis Konfiguration (dieselbe Quelle wie der PhotoCraft-Modus); ohne ihn keine Live-Werte.
    static let key: String? = {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/models.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strata = (json["providers"] as? [String: Any])?["strata"] as? [String: Any],
              let key = strata["apiKey"] as? String, !key.isEmpty, !key.hasPrefix("$"), !key.hasPrefix("!") else { return nil }
        return key
    }()

    // LAN zuerst, sonst Tailscale (MacBook unterwegs); der zuletzt erreichbare Weg wird zuerst versucht.
    nonisolated(unsafe) private static var hosts = ["GPU-SERVER-LAN-IP", String(remoteHost.split(separator: "@").last!)]

    static func fetch() async -> Snapshot? {
        guard let key else { return nil }
        for host in hosts {
            guard let url = URL(string: "http://\(host):8080/metrics") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 1.5)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            guard let (data, reply) = try? await URLSession.shared.data(for: request),
                  (reply as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if host != hosts[0] { hosts.removeAll { $0 == host }; hosts.insert(host, at: 0) }
            return describe(json)
        }
        return nil
    }

    /// Reine Umwandlung der /metrics-Antwort in eine Zeile (getestet in tests/test_strata_live.py).
    static func describe(_ json: [String: Any]) -> Snapshot? {
        let live = json["live"] as? [String: Any] ?? [:]
        let limit = (json["engine"] as? [String: Any])?["max_context"] as? Int
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        func rate(_ value: Any?) -> String? { (value as? NSNumber).map { "\(Int($0.doubleValue.rounded())) t/s" } }
        let prompt = int(live["prompt_tokens"]), generated = int(live["generated"]) ?? 0
        let queued = int(live["queued"]) ?? 0
        let waiting = queued > 0 ? " · \(queued) wartend" : ""
        switch live["state"] as? String {
        case "reading":
            var parts = ["Liest Prompt"]
            if let read = int(live["prompt_read"]), let total = int(live["prompt_total"]), total > 0 {
                parts.append("\(tokens(read)) / \(tokens(total))")
            } else if let prompt {
                parts.append(tokens(prompt))
            }
            if let reused = int(live["reused"]), reused > 0 { parts.append("\(tokens(reused)) aus dem Zwischenspeicher") }
            if let speed = rate(live["prefill_tok_s_mean"]) { parts.append(speed) }
            return Snapshot(line: parts.joined(separator: " · ") + waiting, context: prompt, limit: limit)
        case nil, "idle":
            guard let last = (json["requests"] as? [[String: Any]])?.first else { return nil }
            var parts = ["Zuletzt"]
            if let speed = rate(last["decode_tok_s"]) { parts.append(speed) }
            if let read = int(last["prompt_read"]), let ms = (last["prompt_ms"] as? NSNumber)?.doubleValue, read > 0, ms > 0 {
                parts.append("Prompt \(Int((Double(read) / ms * 1000).rounded())) t/s")
            }
            if let out = int(last["output_tokens"]) { parts.append("\(out) Token") }
            let context = int(last["prompt_tokens"]).map { $0 + (int(last["output_tokens"]) ?? 0) }
            return Snapshot(line: parts.joined(separator: " · ") + waiting, context: context, limit: limit)
        default:  // Antwort wird geschrieben
            var parts = ["Schreibt"]
            if let speed = rate(live["tok_s"]) ?? rate(live["tok_s_mean"]) { parts.append(speed) }
            parts.append("\(generated) Token")
            return Snapshot(line: parts.joined(separator: " · ") + waiting, context: prompt.map { $0 + generated }, limit: limit)
        }
    }

    /// 950 → "950", 17_861 → "17,9k"
    static func tokens(_ n: Int) -> String {
        n < 1000 ? "\(n)" : String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".", with: ",")
    }
}
