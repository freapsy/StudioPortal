import SwiftUI

/// Live state of the three MI50 on bigki, as reported by the StudioPortal card broker.
struct GPUCard: Equatable, Identifiable {
    var index: Int
    var temp: Int?
    var busy: Int?
    var vram: Int64?
    var job: String?
    var origin: String?
    var foreign: Bool
    /// "Blender · bigki" style labels of the foreign programs on this card (broker reads /proc)
    var foreignBy: [String] = []
    var id: Int { index }
    var vramGB: Double { Double(vram ?? 0) / 1_073_741_824 }
}

struct QueueEntry: Equatable, Identifiable {
    var label: String
    var origin: String
    var cards: Int
    var reason: String?
    var id: String { label + origin + (reason ?? "") }
}

/// A running Blender session on bigki (CPU/RAM only, no GPU).
struct BlenderSessionInfo: Equatable, Identifiable {
    var name: String
    var memoryGB: Double?
    var current: String?
    var last: String?
    var objects: Int?
    var blender: String?
    var buildType: String?
    var id: String { name }
    /// who the session belongs to: mac-mini / macbook = agents on that Mac, otherwise a named working session
    var owner: String {
        switch name {
        case "mac-mini": return "Agenten auf dem Mac mini"
        case "macbook": return "Agenten auf dem MacBook"
        case "werkzeug": return "StudioPortal (Wartung)"
        default: return "Sitzung „\(name)“"
        }
    }
}

/// CPU telemetry on bigki (governor, clock MHz, load average).
struct HostCPUInfo: Equatable {
    var cores: Int?
    var loadavg: [Double] = []
    var governor: String?
    var epp: String?
    var freqMHzMin: Int?
    var freqMHzMax: Int?
    var freqMHzAvg: Int?

    var json: [String: Any] {
        var out: [String: Any] = [:]
        if let cores { out["cores"] = cores }
        if !loadavg.isEmpty { out["loadavg"] = loadavg }
        if let governor { out["governor"] = governor }
        if let epp { out["epp"] = epp }
        if let freqMHzMin { out["freq_mhz_min"] = freqMHzMin }
        if let freqMHzMax { out["freq_mhz_max"] = freqMHzMax }
        if let freqMHzAvg { out["freq_mhz_avg"] = freqMHzAvg }
        return out
    }
}

/// Origin "Mac mini · Agent" → icon + friendly text ("Agent · Mac mini", "App · MacBook").
func originDisplay(_ origin: String?) -> (icon: String, text: String) {
    guard let origin, !origin.isEmpty else { return ("questionmark.circle", "unbekannt") }
    let parts = origin.components(separatedBy: " · ")
    let mac = parts.first ?? origin, kind = parts.count > 1 ? parts[1] : ""
    let mine = mac == machineName
    switch kind {
    case "Agent": return ("sparkle", "Agent auf \(mine ? "diesem Mac" : mac)")
    case "App": return (mac.contains("mini") ? "macmini" : "laptopcomputer", mine ? "Du (diese App)" : "App auf \(mac)")
    default: return ("terminal", origin)
    }
}

struct MachineStatus: Equatable {
    var reachable = false
    var checked = false
    var cards: [GPUCard] = []
    var queue: [QueueEntry] = []
    var sessions: [BlenderSessionInfo] = []
    var cpu: HostCPUInfo?
    var lock = "unknown"
    var updated = Date.distantPast

    var temperatures: [Int] { cards.compactMap(\.temp) }
    var ownJobs: Int { cards.filter { $0.job != nil }.count }
    var freeCards: Int { cards.filter { $0.job == nil && !$0.foreign && ($0.temp ?? 99) < 92 }.count }
    var summary: String {
        guard checked else { return "prüfe …" }
        guard reachable else { return "nicht erreichbar" }
        if let first = cards.first(where: \.foreign) { return first.foreignBy.first.map { "belegt: " + $0.components(separatedBy: " · ")[0] } ?? "fremd belegt" }
        if lock == "foreign" && ownJobs == 0 { return "belegt" }
        if ownJobs > 0 {
            let who = Set(cards.compactMap { $0.job == nil ? nil : originDisplay($0.origin).text })
            return who.count == 1 ? "\(ownJobs)/3 · \(who.first!)" : "\(ownJobs)/3 Karten rechnen"
        }
        return "frei"
    }
    var color: Color {
        guard reachable else { return checked ? .red : .secondary }
        if cards.contains(where: \.foreign) || lock == "foreign" { return .orange }
        return ownJobs > 0 ? .blue : .green
    }

    static func fetch() -> MachineStatus {
        var status = MachineStatus(reachable: false, checked: true)
        do {
            try runWorker(["operation": "machine"], timeout: 25) { event in
                guard event["type"] as? String == "machine" else { return }
                status.reachable = true
                status.lock = event["lock"] as? String ?? "unknown"
                status.cards = (event["cards"] as? [[String: Any]] ?? []).compactMap { card in
                    guard let index = card["index"] as? Int else { return nil }
                    return GPUCard(index: index, temp: card["temp"] as? Int, busy: card["busy"] as? Int,
                                   vram: (card["vram"] as? NSNumber)?.int64Value, job: card["job"] as? String,
                                   origin: card["origin"] as? String, foreign: card["foreign"] as? Bool ?? false,
                                   foreignBy: card["foreign_by"] as? [String] ?? [])
                }
                status.sessions = (event["sessions"] as? [[String: Any]] ?? []).compactMap { item in
                    guard let name = item["name"] as? String else { return nil }
                    return BlenderSessionInfo(name: name, memoryGB: (item["memory_gb"] as? NSNumber)?.doubleValue, current: item["current"] as? String,
                                              last: item["last"] as? String, objects: item["objects"] as? Int,
                                              blender: item["blender"] as? String, buildType: item["build_type"] as? String)
                }
                if let cpu = event["cpu"] as? [String: Any] {
                    status.cpu = HostCPUInfo(
                        cores: cpu["cores"] as? Int,
                        loadavg: (cpu["loadavg"] as? [NSNumber] ?? []).map(\.doubleValue),
                        governor: cpu["governor"] as? String,
                        epp: cpu["epp"] as? String,
                        freqMHzMin: cpu["freq_mhz_min"] as? Int,
                        freqMHzMax: cpu["freq_mhz_max"] as? Int,
                        freqMHzAvg: cpu["freq_mhz_avg"] as? Int
                    )
                }
                status.queue = (event["queue"] as? [[String: Any]] ?? []).map { item in
                    QueueEntry(label: item["label"] as? String ?? "Auftrag", origin: item["origin"] as? String ?? "",
                               cards: item["cards"] as? Int ?? 1, reason: item["reason"] as? String)
                }
            }
        } catch { return status }
        status.updated = Date()
        return status
    }
}

func temperatureColor(_ value: Int?) -> Color {
    guard let value else { return .secondary }
    return value >= 85 ? .red : value >= 70 ? .orange : value >= 55 ? .yellow : .green
}

/// Compact status in the sidebar: one bar per card.
struct MachineCard: View {
    var machine: MachineStatus
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(machine.color).frame(width: 7, height: 7)
                    Text("bigki").font(.callout.weight(.semibold))
                    Spacer()
                    Text(machine.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if machine.reachable && !machine.cards.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(machine.cards) { card in
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(card.foreign ? Color.orange : card.job != nil ? Color.accentColor : Color.secondary.opacity(0.25))
                                    .frame(height: 4)
                                Text(card.temp.map { "\($0)°" } ?? "–").font(.system(size: 9.5).monospacedDigit())
                                    .foregroundStyle(temperatureColor(card.temp))
                            }
                        }
                    }
                    if !machine.queue.isEmpty {
                        Text("\(machine.queue.count) in der Warteschlange").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !machine.sessions.isEmpty {
                        let active = machine.sessions.filter { $0.current != nil }.count
                        Label(active > 0 ? "Blender: \(active) arbeitet · \(machine.sessions.count) offen" : "Blender: \(machine.sessions.count) Sitzung\(machine.sessions.count == 1 ? "" : "en") offen",
                              systemImage: "cube").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if machine.checked && !machine.reachable {
                    Text(portalAccessConfigured ? "Tailscale auf diesem Mac verbinden." : "Zugang zu bigki fehlt auf diesem Mac.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Grafikkarten und Warteschlange anzeigen")
    }
}

/// Full page: the three cards, what runs where, and the queue across MacBook, Mac mini and agents.
struct MachineView: View {
    @ObservedObject var portal: Portal

    var body: some View {
        let machine = portal.machine
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rechner").font(.largeTitle.weight(.semibold))
                        Text("bigki · 3 × AMD MI50 · Aufträge laufen in Startreihenfolge, jede Karte einzeln")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if machine.updated != .distantPast {
                        Text("Stand \(machine.updated.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { Task { await portal.refreshStatus() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Jetzt aktualisieren")
                }
                if !machine.reachable {
                    Card {
                        Label(machine.checked ? (portalAccessConfigured ? "bigki ist nicht erreichbar. Ist Tailscale verbunden?" : "Der Zugang zu bigki ist auf diesem Mac noch nicht eingerichtet.") : "Verbinde …",
                              systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 14) {
                        ForEach(machine.cards) { card in CardTile(card: card) }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("WARTESCHLANGE").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        if machine.queue.isEmpty {
                            Text(machine.ownJobs == 0 ? "Nichts in der Warteschlange – neue Aufträge starten sofort." : "Keine wartenden Aufträge.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(machine.queue.enumerated()), id: \.offset) { index, entry in
                                    HStack(spacing: 12) {
                                        Text("\(index + 1)").font(.callout.monospacedDigit().weight(.semibold)).frame(width: 22)
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.label).font(.callout.weight(.medium))
                                            Text([originDisplay(entry.origin).text, entry.reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(entry.cards == 1 ? "1 Karte" : "\(entry.cards) Karten").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    if index < machine.queue.count - 1 { Divider().padding(.leading, 48) }
                                }
                            }
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                        }
                    }
                    if !machine.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("BLENDER-SITZUNGEN · NUR CPU UND ARBEITSSPEICHER").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(Array(machine.sessions.enumerated()), id: \.offset) { index, session in
                                    HStack(spacing: 12) {
                                        Image(systemName: session.current != nil ? "gearshape.2.fill" : "cube")
                                            .foregroundStyle(session.current != nil ? Color.accentColor : .secondary).frame(width: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.owner).font(.callout.weight(.medium))
                                            Text(session.current.map { "arbeitet gerade: \($0)" } ?? session.last.map { "wartet · letzter Aufruf \($0)" } ?? "wartet")
                                                .font(.caption).foregroundStyle(session.current != nil ? Color.accentColor : .secondary)
                                        }
                                        Spacer()
                                        if let objects = session.objects { Text("\(objects) Objekte").font(.caption).foregroundStyle(.secondary) }
                                        if let memory = session.memoryGB {
                                            Text(String(format: "%.1f GB", memory)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                                        }
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    if index < machine.sessions.count - 1 { Divider().padding(.leading, 48) }
                                }
                            }
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("So verteilt StudioPortal die Karten", systemImage: "info.circle").font(.headline)
                            Text("Bilder und die 3D-Oberfläche nutzen alle drei Karten gleichzeitig, drei Song-Varianten je eine Karte. Schritte, die nur eine Karte nutzen können (3D-Form, einzelner Song), lassen die übrigen Karten für den nächsten Auftrag frei. Rechnet Blender oder ein anderer Auftrag auf einer Karte, macht StudioPortal dort Platz und startet danach automatisch neu. Ab 92 °C wird abgebrochen, Musik startet erst unter 65 °C.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .task {
            while !Task.isCancelled {
                await portal.refreshStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct CardTile: View {
    var card: GPUCard
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MI50 · \(card.index)").font(.headline)
                Spacer()
                Text(card.temp.map { "\($0) °C" } ?? "–").font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(temperatureColor(card.temp))
            }
            Gauge(value: Double(min(card.busy ?? 0, 100)), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity).tint(card.foreign ? .orange : .accentColor)
            HStack {
                Text("Last \(card.busy ?? 0) %").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f / 32 GB", card.vramGB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            Group {
                if card.foreign {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(card.foreignBy.first ?? "Fremder Auftrag", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(card.foreignBy.count > 1 ? "+ " + card.foreignBy.dropFirst().joined(separator: ", ") : "nicht von StudioPortal – hat Vorrang")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let job = card.job {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(job, systemImage: "bolt.fill").foregroundStyle(Color.accentColor).lineLimit(2)
                        let who = originDisplay(card.origin)
                        Label(who.text, systemImage: who.icon).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Frei", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }.font(.callout.weight(.medium))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(card.job != nil ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.07)))
    }
}
