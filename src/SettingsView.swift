import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var portal: Portal

    var body: some View {
        TabView {
            OverviewSettings().tabItem { Label("Übersicht", systemImage: "square.stack.3d.up") }
            SyncSettings(sync: portal.sync).tabItem { Label("Synchronisation", systemImage: "arrow.triangle.2.circlepath") }
            AgentSettings().tabItem { Label("Agenten", systemImage: "sparkle") }
            StorageSettings().tabItem { Label("Ablage", systemImage: "folder") }
        }
        .frame(width: 720, height: 640)
    }
}

private struct SyncSettings: View {
    @ObservedObject var sync: SyncEngine

    var body: some View {
        Form {
            Section {
                Toggle("MacBook und Mac mini synchronisieren", isOn: $sync.enabled)
                Text(sync.isHub
                     ? "Dieser Mac ist die Zentrale. Das MacBook gleicht seine Bilder, Songs und 3D-Modelle über Tailscale mit diesem Mac ab, solange der Schalter auf beiden Macs an ist."
                     : "Bilder, Songs und 3D-Modelle werden mit dem Mac mini abgeglichen: neue Dateien in beide Richtungen, Gelöschtes wandert auf beiden Macs in den Papierkorb. Nichts wird überschrieben. Funktioniert überall, wo Tailscale verbunden ist.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !sync.isHub {
                Section("Mac mini") {
                    TextField("SSH-Ziel", text: $sync.peer).textFieldStyle(.roundedBorder)
                    HStack {
                        Label(sync.shortStatus, systemImage: sync.lastError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(sync.lastError == nil ? Color.secondary : Color.orange)
                        if !sync.lastSummary.isEmpty && sync.lastError == nil { Text(sync.lastSummary).foregroundStyle(.secondary) }
                        Spacer()
                        Button(sync.running ? "Läuft …" : "Jetzt synchronisieren") { Task { await sync.syncNow() } }
                            .disabled(!sync.enabled || sync.running)
                    }
                }
            } else {
                Section("Status") { Label(sync.shortStatus, systemImage: "clock") }
            }
        }
        .formStyle(.grouped)
        .onAppear { sync.schedule() }
    }
}

private struct AgentSettings: View {
    @State private var commandInstalled = FileManager.default.isExecutableFile(atPath: AgentSetup.command.path)
    @State private var claudeCode = AgentSetup.claudeCodeConfigured()
    @State private var codex = AgentSetup.codexConfigured()
    @State private var desktop = AgentSetup.desktopConfigured()
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("KI-Agenten nutzen StudioPortal ohne Bildschirmsteuerung: über den Befehl `studioportal` oder als MCP-Server. Sie verwenden dieselben Funktionen, dieselbe Warteschlange auf bigki und dieselbe Bibliothek wie du.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Einrichtung") {
                row("Befehl studioportal", detail: AgentSetup.command.path, ok: commandInstalled)
                row("Claude Code", detail: "MCP-Server »studioportal«", ok: claudeCode)
                row("Codex", detail: "~/.codex/config.toml", ok: codex)
                row("Claude (Chat-App)", detail: "claude_desktop_config.json · nach Neustart der App aktiv", ok: desktop)
                HStack {
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    Spacer()
                    Button("Alles einrichten") {
                        let result = AgentSetup.installAll()
                        message = result.filter { ($0.value as? String)?.contains("eingerichtet") == false && $0.key != "command" }
                            .map { "\($0.key): \($0.value)" }.joined(separator: " · ")
                        refresh()
                    }
                }
            }
            Section("Beispiele") {
                Text("studioportal image \"ein roter Würfel\" --aspect 16:9\nstudioportal music \"lofi piano, calm\" --instrumental --duration 40\nstudioportal status")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func refresh() {
        commandInstalled = FileManager.default.isExecutableFile(atPath: AgentSetup.command.path)
        claudeCode = AgentSetup.claudeCodeConfigured(); codex = AgentSetup.codexConfigured(); desktop = AgentSetup.desktopConfigured()
    }

    private func row(_ title: String, detail: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StorageSettings: View {
    var body: some View {
        Form {
            Section("Ordner auf diesem Mac") {
                folder("Bilder", picturesDirectory)
                folder("Musik", musicDirectory)
                folder("3D-Modelle", modelsDirectory)
                folder("Videos", videosDirectory)
            }
            Section("bigki") {
                LabeledContent("Rechner", value: "bigki · 3 × AMD MI50 (Tailscale)")
                LabeledContent("Zugang", value: portalAccessConfigured ? "eingerichtet (eigener Schlüssel, nur StudioPortal)" : "fehlt auf diesem Mac")
                LabeledContent("Dieser Mac", value: machineName)
            }
        }
        .formStyle(.grouped)
    }

    private func folder(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
            }
        }
    }
}


// MARK: - Overview (ARCHITEKTUR.md, bundled with the app)

/// The architecture description shipped in the app bundle (falls back to the project copy when run from the build folder).
let architectureFile: URL? = {
    if let url = Bundle.main.url(forResource: "ARCHITEKTUR", withExtension: "md") { return url }
    return nil
}()

func architectureText() -> String {
    guard let url = architectureFile, let text = try? String(contentsOf: url, encoding: .utf8) else {
        return "ARCHITEKTUR.md fehlt in dieser App-Version."
    }
    return text
}

/// One clickable part of the overview; its explanation is the matching section of ARCHITEKTUR.md (stays current).
private struct OverviewPart: Identifiable, Equatable {
    let id: String, title: String, icon: String, tint: Color, short: String, sections: [String]
}

private let overviewSystem: [OverviewPart] = [
    OverviewPart(id: "macs", title: "Deine Macs", icon: "laptopcomputer", tint: .blue,
                 short: "App, Kommandozeile und Agenten. Der Mac mini ist die Zentrale für Bibliothek und Synchronisation.", sections: ["3.1", "3.2"]),
    OverviewPart(id: "netz", title: "Verbindung", icon: "lock.shield", tint: .teal,
                 short: "Tailscale + SSH: jeder Auftrag ist eine gesicherte Leitung zu bigki.", sections: ["2.", "3.3"]),
    OverviewPart(id: "bigki", title: "bigki", icon: "server.rack", tint: .indigo,
                 short: "Der Linux-Rechner, der rechnet. Worker prüft, Broker verteilt die Karten.", sections: ["3.4", "3.6", "3.7", "3.8"]),
]

private let overviewCards = OverviewPart(id: "karten", title: "3× MI50", icon: "memorychip", tint: .orange,
                                         short: "Je 32 GB, 150 W, eigene Kühlung, Schutz bis 92 °C.", sections: ["3.5"])

/// what was optimised for the MI50 (points) per function – shown only here, not in the tool panels
@MainActor private var overviewPoints: [String: [String]] {
    ["bilder": ImagePreset.points, "musik": MusicPreset.points, "video": VideoPreset.points, "blender": BlenderInfo.points]
}

/// measured improvements shown under a function's text
@MainActor private var overviewImprovements: [String: [Improvement]] {
    ["bilder": ImagePreset.improvements, "musik": MusicPreset.improvements, "video": VideoPreset.improvements,
     "blender": BlenderInfo.improvements, "3d": [BlenderInfo.improvements[0]]]
}

/// Wraps its children onto new lines (for the flow diagrams).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

private let overviewFunctions: [OverviewPart] = [
    OverviewPart(id: "bilder", title: "Bilder", icon: "photo", tint: .pink,
                 short: "Text → Bild und Bearbeiten. MiniMax H3 Image auf 3 Karten.", sections: ["3.10"]),
    OverviewPart(id: "musik", title: "Musik", icon: "music.note", tint: .purple,
                 short: "Songs mit Gesang. MiniMax Music 3 auf 1 Karte.", sections: ["3.11"]),
    OverviewPart(id: "video", title: "Video", icon: "film", tint: .red,
                 short: "Text → Video mit Ton. MiniMax H3 Video auf 2 Karten.", sections: ["3.12"]),
    OverviewPart(id: "3d", title: "3D & Figuren", icon: "cube", tint: .green,
                 short: "Modelle aus Ansichten, Figuren aus einem Bild.", sections: ["3.13"]),
    OverviewPart(id: "blender", title: "Blender", icon: "cube.transparent", tint: .orange,
                 short: "Dauernd offene Sitzung, Prüfungen in Zahlen, Render auf den MI50.", sections: ["3.9"]),
    OverviewPart(id: "regeln", title: "Regeln & Lizenzen", icon: "checkmark.shield", tint: .gray,
                 short: "Fremde Jobs nie anfassen, nur private Nutzung der Modelle.", sections: ["4."]),
    OverviewPart(id: "aendern", title: "Ändern & Ausrollen", icon: "hammer", tint: .brown,
                 short: "Bauen, auf bigki einspielen, auf beide Macs kopieren.", sections: ["5."]),
    OverviewPart(id: "offen", title: "Offene Punkte", icon: "list.bullet.clipboard", tint: .yellow,
                 short: "Was noch eingebaut oder freigegeben werden muss.", sections: ["6."]),
    OverviewPart(id: "neu", title: "Neuigkeiten", icon: "sparkles", tint: .mint,
                 short: "Was zuletzt verbessert wurde.", sections: ["7."]),
]

/// Markdown of the sections whose heading starts with `prefix` (e.g. "3.10", "4."), without the heading line.
private func architectureSection(_ text: String, _ prefix: String) -> String {
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#") else { return false }
        let title = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return title.hasPrefix(prefix + " ") || title.hasPrefix(prefix)
            && !(title.dropFirst(prefix.count).first?.isNumber ?? false)
    }) else { return "" }
    let level = lines[start].prefix(while: { $0 == "#" }).count
    var body: [String] = []
    for line in lines[(start + 1)...] {
        let hashes = line.prefix(while: { $0 == "#" }).count
        if hashes > 0 && hashes <= level { break }
        if line.trimmingCharacters(in: .whitespaces) == "---" { continue }
        body.append(line)
    }
    return body.joined(separator: "\n")
}

private struct OverviewSettings: View {
    private let text = architectureText()
    @State private var selected: OverviewPart?
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("So funktioniert StudioPortal").font(.title2.bold())
                            Text("Du gibst auf dem Mac einen Auftrag. bigki rechnet ihn mit drei Grafikkarten und schickt das Ergebnis zurück. Klick auf ein Teil für die Erklärung.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        diagram(scroller)
                        Text("Was es kann").font(.headline)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(overviewFunctions) { part in
                                OverviewTile(part: part, selected: selected == part) { pick(part, scroller) }
                            }
                        }
                        if let part = selected {
                            OverviewDetail(part: part, text: text) { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } }
                                .id("detail")
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        DisclosureGroup(isExpanded: $showAll) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { $0.element.view }
                            }
                            .padding(.top, 8)
                        } label: {
                            Label("Ganzer Text (ARCHITEKTUR.md)", systemImage: "doc.text").font(.headline)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
            Divider()
            HStack {
                Text("Wird bei jeder Änderung an StudioPortal mitgepflegt · auch per »studioportal info«")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = architectureFile {
                    Button("Als Datei öffnen") { NSWorkspace.shared.open(url) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func pick(_ part: OverviewPart, _ scroller: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.2)) { selected = selected == part ? nil : part }
        if selected != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation { scroller.scrollTo("detail", anchor: .top) } }
        }
    }

    /// Macs ── Verbindung ── bigki, with the three cards under bigki.
    private func diagram(_ scroller: ScrollViewProxy) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 0) {
                OverviewNode(part: overviewSystem[0], selected: selected == overviewSystem[0]) { pick(overviewSystem[0], scroller) }
                OverviewLink(part: overviewSystem[1], selected: selected == overviewSystem[1]) { pick(overviewSystem[1], scroller) }
                VStack(spacing: 8) {
                    OverviewNode(part: overviewSystem[2], selected: selected == overviewSystem[2]) { pick(overviewSystem[2], scroller) }
                    Button { pick(overviewCards, scroller) } label: {
                        HStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { _ in
                                VStack(spacing: 2) {
                                    Image(systemName: "memorychip").font(.system(size: 13))
                                    Text("MI50").font(.system(size: 9, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(selected == overviewCards ? 0.28 : 0.14)))
                            }
                        }
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help(overviewCards.short)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
        )
    }
}

private struct OverviewNode: View {
    let part: OverviewPart, selected: Bool, action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: part.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(part.tint)
                        .frame(width: 30, height: 30).background(Circle().fill(part.tint.opacity(0.15)))
                    Text(part.title).font(.headline)
                }
                Text(part.short).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? part.tint : Color.secondary.opacity(hover ? 0.35 : 0.18),
                                                                     lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(hover ? 0.10 : 0.04), radius: hover ? 5 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { hover = $0 }
    }
}

private struct OverviewLink: View {
    let part: OverviewPart, selected: Bool, action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: part.icon).font(.system(size: 12, weight: .semibold))
                Text("Tailscale · SSH").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(part.tint)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(part.tint.opacity(selected ? 0.25 : 0.12)))
            .frame(maxWidth: .infinity)
            .background(Rectangle().fill(part.tint.opacity(0.45)).frame(height: 1.5))
        }
        .buttonStyle(.plain)
        .frame(width: 120)
        .help(part.short)
    }
}

private struct OverviewTile: View {
    let part: OverviewPart, selected: Bool, action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: part.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(part.tint)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(part.tint.opacity(0.15)))
                Text(part.title).font(.headline)
                Text(part.short).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? part.tint : Color.secondary.opacity(hover ? 0.35 : 0.16),
                                                                     lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(hover ? 0.10 : 0.03), radius: hover ? 5 : 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct OverviewDetail: View {
    let part: OverviewPart, text: String, close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: part.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(part.tint)
                    .frame(width: 36, height: 36).background(Circle().fill(part.tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.title).font(.title3.bold())
                    Text(part.short).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Schließen")
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(part.sections.enumerated()), id: \.offset) { _, prefix in
                    ForEach(Array(MarkdownBlock.parse(architectureSection(text, prefix)).enumerated()), id: \.offset) { $0.element.view }
                }
                if let points = overviewPoints[part.id], !points.isEmpty {
                    Text("Optimiert für die MI50").font(.headline).padding(.top, 6)
                    ForEach(points, id: \.self) { point in
                        Label { Text(point).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "bolt.fill").foregroundStyle(.orange) }
                            .font(.callout)
                    }
                }
                if let measured = overviewImprovements[part.id], !measured.isEmpty {
                    ImprovementChart(title: "Gemessen auf bigki – vorher / jetzt", items: measured)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(part.tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(part.tint.opacity(0.35)))
    }
}

/// A deliberately small Markdown renderer: headings, paragraphs, bullet lists, tables, code blocks, rules.
enum MarkdownBlock {
    case heading(Int, String), paragraph(String), bullet(Int, String), table([[String]]), code(String), rule, flow([String])

    /// keepLineBreaks: Chat-Antworten behalten einfache Zeilenumbrüche (die Doku bricht dagegen nur für die Breite um).
    static func parse(_ text: String, keepLineBreaks: Bool = false) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = text.components(separatedBy: "\n")[...]
        var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: keepLineBreaks ? "\n" : " "))); paragraph = [] } }
        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(next) }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [trimmed]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(next.trimmingCharacters(in: .whitespaces)); lines.removeFirst() }
                let cells = rows.map { row in row.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
                    .filter { !$0.allSatisfy { cell in cell.allSatisfy { "-: ".contains($0) } } }
                blocks.append(.table(cells))
            } else if trimmed == "---" {
                flush(); blocks.append(.rule)
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#") {
                flush(); blocks.append(.heading(trimmed.distance(from: trimmed.startIndex, to: hashes), String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- **Weg**:") {
                // "- **Weg**: Mac → SSH → Worker → …" becomes a small flow diagram
                flush()
                var body = String(trimmed.dropFirst("- **Weg**:".count))
                while let next = lines.first, next.hasPrefix("  "), !next.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                    body += " " + next.trimmingCharacters(in: .whitespaces); lines.removeFirst()
                }
                blocks.append(.flow(body.components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            } else if trimmed.hasPrefix("- ") || trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                flush()
                let indent = line.prefix(while: { $0 == " " }).count / 2
                blocks.append(.bullet(indent, trimmed))
            } else if trimmed.isEmpty {
                flush()
            } else if case .bullet(let level, let text)? = blocks.last, paragraph.isEmpty, line.hasPrefix("  ") {
                blocks[blocks.count - 1] = .bullet(level, text + " " + trimmed)   // continuation of a list item
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    private static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    @ViewBuilder var view: some View {
        switch self {
        case .heading(let level, let text):
            Self.inline(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 10 : 4)
        case .paragraph(let text):
            Self.inline(text).fixedSize(horizontal: false, vertical: true)
        case .bullet(let level, let text):
            let marker = text.hasPrefix("- ") ? "•" : String(text.prefix(while: { $0 != " " }))
            let body = text.hasPrefix("- ") ? String(text.dropFirst(2)) : String(text.drop(while: { $0 != " " }).dropFirst())
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                Self.inline(body).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 16)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Self.inline(rows[r][c]).font(r == 0 ? .callout.bold() : .callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if r == 0 { Divider() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text).font(.caption.monospaced()).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
        case .rule:
            Divider().padding(.vertical, 4)
        case .flow(let steps):
            VStack(alignment: .leading, spacing: 4) {
                Text("WEG").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                FlowLayout(spacing: 4) {
                    ForEach(steps.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            Self.inline(steps[index]).font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(index == steps.count - 1 ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1)))
                            if index < steps.count - 1 { Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
