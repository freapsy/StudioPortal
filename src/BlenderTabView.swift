import SwiftUI
import AppKit

/// Watches the Blender sessions on bigki (also the ones agents use): what runs right now, memory, autosave, history,
/// objects – read from the session's status file without waiting for it – plus a preview on request.
@MainActor
final class BlenderMonitor: ObservableObject {
    @Published var sessions: [(name: String, running: Bool)] = []
    @Published var selected = defaultBlenderSession
    @Published var status: [String: Any] = [:]
    @Published var preview: URL?
    @Published var previewInfo: [String: Any] = [:]
    @Published var mode = "solid"
    @Published var views = "eine"
    @Published var loadingPreview = false
    @Published var message: String?
    @Published var lastUpdate: Date?
    private var timer: Timer?
    private var polling = false

    func start() {
        refreshSessions()
        refreshStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refreshSessions() {
        Task.detached {
            let value = try? BlenderRemote.call("sessions", [:])
            let list = (value?["sessions"] as? [[String: Any]] ?? []).compactMap { item -> (String, Bool)? in
                guard let name = item["name"] as? String else { return nil }
                return (name, item["running"] as? Bool ?? false)
            }
            await MainActor.run {
                self.sessions = list.sorted { ($0.1 ? 0 : 1, $0.0) < ($1.1 ? 0 : 1, $1.0) }.map { (name: $0.0, running: $0.1) }
                if !self.sessions.contains(where: { $0.name == self.selected }), let first = self.sessions.first(where: { $0.running }) ?? self.sessions.first {
                    self.selected = first.name
                }
            }
        }
    }

    func refreshStatus() {
        guard !polling else { return }
        polling = true
        let name = selected
        Task.detached {
            let value = try? BlenderRemote.call("status", ["session": name])
            await MainActor.run {
                self.polling = false
                guard name == self.selected else { return }
                if let value { self.status = value; self.lastUpdate = Date() }
            }
        }
    }

    func select(_ name: String) {
        selected = name; status = [:]; preview = nil; previewInfo = [:]
        refreshStatus()
    }

    func look() {
        loadingPreview = true; message = nil
        var params: [String: Any] = ["session": selected, "mode": mode, "name": "app-\(selected)"]
        if views == "vier" { params["views"] = "vier" } else if views == "rund" { params["views"] = "rund" }
        Task.detached {
            do {
                let value = try BlenderRemote.call("look", params)
                await MainActor.run {
                    self.loadingPreview = false
                    self.previewInfo = value
                    if let path = value["image"] as? String { self.preview = URL(fileURLWithPath: path) }
                    if (value["ok"] as? Bool) == false { self.message = value["error"] as? String }
                    self.refreshStatus()
                }
            } catch {
                await MainActor.run { self.loadingPreview = false; self.message = error.localizedDescription }
            }
        }
    }

    @Published var rigging: String?

    /// UniRig on bigki's CPU (figur.auto_rig): ~8 min, 52 bones, weights; the original mesh is hidden, placement kept.
    func autoRig(_ object: String) {
        guard rigging == nil else { return }
        rigging = object; message = "„\(object)“ wird geriggt (UniRig auf der CPU, ~8 min) …"
        let name = selected
        let literal = String(data: try! JSONSerialization.data(withJSONObject: [object]), encoding: .utf8)!.dropFirst().dropLast()
        Task.detached {
            let value = try? BlenderRemote.call("python", ["session": name, "code": "r = figur.auto_rig(\(literal))\nr.pop('skelett', None)\nresult = r", "timeout": 3000])
            await MainActor.run {
                self.rigging = nil
                if let result = value?["result"] as? [String: Any], let rig = result["rig"] as? String {
                    self.message = "Fertig: \(rig) mit \(result["knochen"] as? Int ?? 0) Knochen in \(Int(result["sekunden"] as? Double ?? 0) / 60) min. Original ausgeblendet."
                } else {
                    self.message = "Riggen fehlgeschlagen: " + (value?["error"] as? String ?? "keine Antwort")
                }
                self.refreshStatus()
            }
        }
    }

    func snapshot() {
        let name = selected
        Task.detached {
            let value = try? BlenderRemote.call("snapshot", ["session": name, "note": "aus der App"])
            await MainActor.run { self.message = (value?["ok"] as? Bool) == true ? "Zwischenstand gesichert." : (value?["error"] as? String ?? "Sichern fehlgeschlagen.") }
        }
    }
}

struct BlenderTabView: View {
    @ObservedObject var monitor: BlenderMonitor

    var body: some View {
        HStack(spacing: 0) {
            BlenderControls(monitor: monitor)
            Divider()
            BlenderWorkspace(monitor: monitor)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

private struct BlenderControls: View {
    @ObservedObject var monitor: BlenderMonitor

    private var status: [String: Any] { monitor.status["status"] as? [String: Any] ?? [:] }
    private var running: Bool { monitor.status["running"] as? Bool ?? false }

    var body: some View {
        ToolPanel(title: "Blender", subtitle: "Sitzung auf bigki · Blender 5.3 ohne Bildschirm", icon: "rotate.3d") {
            PanelSection(title: "Sitzung", accessory: {
                Button { monitor.refreshSessions(); monitor.refreshStatus() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }) {
                Picker("Sitzung", selection: Binding(get: { monitor.selected }, set: { monitor.select($0) })) {
                    ForEach(monitor.sessions, id: \.name) { item in
                        Text(item.running ? "● \(item.name)" : item.name).tag(item.name)
                    }
                    if !monitor.sessions.contains(where: { $0.name == monitor.selected }) { Text(monitor.selected).tag(monitor.selected) }
                }.labelsHidden()
                Text("mac-mini / macbook = Sitzung der Agenten auf dem jeweiligen Mac. Zuschauen ändert nichts an der Szene.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            PanelSection("Gerade") { nowCard }

            PanelSection(title: "Speicher", accessory: { Text(memoryText) }) {
                let used = (monitor.status["memory_gb"] as? Double) ?? (status["memory_gb"] as? Double) ?? 0
                let limit = status["memory_limit_gb"] as? Double ?? 40
                ProgressView(value: min(used, limit), total: limit).tint(used > limit * 0.75 ? .orange : .accentColor)
                Text("Über \(Int(limit)) GB stoppt sich die Sitzung mit Meldung, statt bigki einzufrieren.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PanelSection("Vorschau") {
                ChipPicker(options: [("Form", "solid"), ("Material", "eevee")], selection: $monitor.mode)
                ChipPicker(options: [("Kamera", "eine"), ("4 Seiten", "vier"), ("Rundum", "rund")], selection: $monitor.views)
                Button { monitor.look() } label: {
                    Label(monitor.loadingPreview ? "Wird gerendert …" : "Vorschau holen", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).disabled(monitor.loadingPreview)
                Text("Rendert auf der Intel-Grafik von bigki (belegt keine MI50). Wartet, bis ein laufender Agenten-Aufruf fertig ist.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Zwischenstand sichern") { monitor.snapshot() }.buttonStyle(.link).font(.callout)
            }

        } footer: {
            HStack {
                Circle().fill(running ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(running ? "Sitzung läuft" : "Sitzung schläft (startet beim nächsten Aufruf)").font(.callout)
                Spacer()
                if let date = monitor.lastUpdate { Text(date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }

    private var memoryText: String {
        let used = (monitor.status["memory_gb"] as? Double) ?? (status["memory_gb"] as? Double)
        let free = status["bigki_free_gb"] as? Double
        return [used.map { String(format: "%.1f GB", $0) }, free.map { String(format: "bigki frei %.0f GB", $0) }].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var nowCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let current = monitor.status["current"] as? [String: Any] {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(current["command"] as? String ?? "?") läuft seit \(current["seconds"] as? Int ?? 0) s").fontWeight(.semibold)
                }
                if let code = current["code"] as? String, !code.isEmpty {
                    Text(code.prefix(300)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(5)
                }
            } else {
                Text(running ? "Wartet auf den nächsten Aufruf." : "Kein Aufruf aktiv.").foregroundStyle(.secondary)
            }
            if let auto = status["autosave"] as? [String: Any], let last = auto["last"] as? String {
                Label("Automatisch gespeichert \(last)" + ((auto["seconds"] as? Double).map { String(format: " (%.1f s)", $0) } ?? ""), systemImage: "externaldrive.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let saved = monitor.status["saved"] as? String {
                Label("Gespeicherter Stand \(saved.suffix(8))", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
            }
            if let crash = monitor.status["last_crash"] as? [String: Any], let reason = crash["reason"] as? String {
                Label("Letzter Absturz \(crash["time"] as? String ?? ""): \(reason)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let message = monitor.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct BlenderWorkspace: View {
    @ObservedObject var monitor: BlenderMonitor
    private var status: [String: Any] { monitor.status["status"] as? [String: Any] ?? [:] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let url = monitor.preview, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 5).padding(24)
                        .onDrag { NSItemProvider(object: url as NSURL) }
                } else {
                    EmptyStateView(icon: "rotate.3d", title: monitor.loadingPreview ? "Vorschau wird gerendert …" : "Noch keine Vorschau",
                                   message: "Links „Vorschau holen“ – zeigt die Szene so, wie der Agent sie gerade hat.")
                }
                if let names = monitor.previewInfo["im_bild"] as? [String], !names.isEmpty {
                    VStack { Spacer(); HStack {
                        Text("Im Bild: " + names.prefix(8).joined(separator: ", ") + (names.count > 8 ? " …" : ""))
                            .font(.caption).padding(.horizontal, 10).padding(.vertical, 5).background(.regularMaterial, in: Capsule())
                        Spacer() }.padding(14) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                objects.frame(maxWidth: .infinity)
                Divider()
                history.frame(maxWidth: .infinity)
            }
            .frame(height: 230)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var objects: some View {
        let list = status["objects"] as? [[String: Any]] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("OBJEKTE · \(status["object_count"] as? Int ?? list.count)").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                Text("Rechtsklick auf ein Mesh: automatisch riggen").font(.caption2).foregroundStyle(.tertiary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(list.indices, id: \.self) { index in
                        let item = list[index]
                        HStack(spacing: 6) {
                            Image(systemName: icon(item["type"] as? String)).foregroundStyle(.secondary).frame(width: 16)
                            Text(item["name"] as? String ?? "?").lineLimit(1)
                            Spacer()
                            if let v = item["vertices"] as? Int { Text(v >= 1000 ? "\(v / 1000)k" : "\(v)").font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
                            if (item["render"] as? Bool) == false { Image(systemName: "camera.metering.none").foregroundStyle(.orange).help("nicht im Bild (hide_render)") }
                            if (item["viewport"] as? Bool) == false { Image(systemName: "eye.slash").foregroundStyle(.secondary).help("im Viewport ausgeblendet") }
                        }.font(.callout)
                        .contentShape(Rectangle())
                        .contextMenu {
                            if item["type"] as? String == "MESH", let name = item["name"] as? String {
                                Button("Automatisch riggen (UniRig, ~8 min)") { monitor.autoRig(name) }.disabled(monitor.rigging != nil)
                            }
                        }
                    }
                }
            }
        }.padding(12)
    }

    private var history: some View {
        let list = (status["history"] as? [[String: Any]] ?? []).reversed()
        return VStack(alignment: .leading, spacing: 6) {
            Text("LETZTE AUFRUFE").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Image(systemName: (item["ok"] as? Bool) == false ? "xmark.circle.fill" : "checkmark.circle")
                                    .foregroundStyle((item["ok"] as? Bool) == false ? .red : .green)
                                Text(item["command"] as? String ?? "?").fontWeight(.medium)
                                Text(item["time"] as? String ?? "").foregroundStyle(.tertiary)
                                Spacer()
                                if let s = item["seconds"] as? Double { Text(String(format: "%.1f s", s)).foregroundStyle(.secondary).monospacedDigit() }
                            }.font(.callout)
                            if let code = item["code"] as? String {
                                Text(code).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if let error = item["error"] as? String { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                        }
                    }
                }
            }
        }.padding(12)
    }

    private func icon(_ type: String?) -> String {
        switch type {
        case "MESH": "cube"; case "CAMERA": "video"; case "LIGHT": "lightbulb"; case "ARMATURE": "figure.stand"; case "EMPTY": "plus.viewfinder"
        case "CURVE": "scribble"; default: "circle.dashed"
        }
    }
}

enum BlenderInfo {
    static let points = [
        "Blender 5.3 läuft ohne Bildschirm dauerhaft auf bigki; Vorschauen rendern auf der Intel-Grafik (OpenGL), damit die drei MI50 frei bleiben – ohne diesen Umweg belegt Blender über Vulkan Karte 0.",
        "Endgültige Renders mit Cycles (HIP) auf den MI50 über den Karten-Broker: zwei Blender je Karte, jede Kamera parallel; reißt die Verbindung ab, rendert bigki weiter und die App holt das Bild mit einem Abholschein.",
        "Automatisches Speichern nach jedem Aufruf, Speicherwächter (40 GB) mit klarer Absturzmeldung, Sichtbarkeit bleibt erhalten.",
        "Fertige Bausteine für Agenten: figur (MPFB-Mensch, Gewichte, Greifen, Kleid anlegen/simulieren, Porzellan), helfer (Kamera, Glätten, Remesh mit Größenprüfung), blender_check (lose Teile, Dicke, Löcher, Kontakt, Ausreißer).",
        "Figuren aus einem Bild: Hunyuan3D-Omni mit FlashVDM-Dekodierung (nur Voxel nahe der Oberfläche) – auf gfx906 ohne Flash-Attention sonst unbrauchbar langsam.",
    ]
    static let improvements: [Improvement] = [
        Improvement(label: "Figur aus einem Bild (Omni)", before: 1800, after: 413, unit: "s", note: "vorher nach 30 min abgebrochen, ohne Ergebnis"),
        Improvement(label: "MI50-Speicher je Blender-Vorschau", before: 1.2, after: 0, unit: "GB", note: "Vorschau auf der Intel-Grafik statt per Vulkan auf Karte 0"),
    ]
}
