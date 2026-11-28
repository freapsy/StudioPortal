import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ThreeDJob: ObservableObject {
    @Published var images: [String: URL] = [:]
    @Published var model = "standard"
    @Published var resolution = 768
    @Published var color = true
    @Published var person = false
    /// "objekt" = Hunyuan3D-2mv from up to four views, "figur" = Hunyuan3D-Omni human in a chosen pose from one photo
    @Published var mode = "objekt"
    let manager = DownloadManager()
    let figure = FigureJob()

    var ready: Bool { !images.isEmpty && (!color || images.count == 4) }
    func load(_ record: ModelRecord) {
        images = record.inputs
        if let model = record.model { self.model = model }
        if let resolution = record.resolution { self.resolution = resolution }
        color = record.color && record.inputs.count == 4; person = record.person
    }
    func start() { manager.startImages(images, model: model, resolution: resolution, color: color, person: person) }
}

// MARK: - Bild zu 3D

struct ThreeDToolView: View {
    @ObservedObject var job: ThreeDJob
    @ObservedObject var manager: DownloadManager
    private let views = [("front", "Vorne"), ("left", "Links"), ("back", "Hinten"), ("right", "Rechts")]

    var body: some View {
        if job.mode == "figur" { FigureToolView(job: job, figure: job.figure) } else { objectBody }
    }

    private var modePicker: some View {
        ChipPicker(options: [("Objekt", "objekt"), ("Figur mit Pose", "figur")], selection: $job.mode)
    }

    private var objectBody: some View {
        HStack(spacing: 0) {
            ToolPanel(title: "Bild zu 3D", subtitle: "Hunyuan3D-2mv · rechnet auf bigki", icon: "cube.transparent") {
                PanelSection("Art") {
                    modePicker
                    Text("Objekt: aus bis zu vier Ansichten. Figur: ein Mensch aus einem Foto, in einer gewählten Pose.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.disabled(manager.working)
                PanelSection(title: "Ansichten", accessory: { Text("\(job.images.count) / 4") }) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(views, id: \.0) { view, label in
                            DropTile(label: label, url: job.images[view], size: 128, disabled: manager.working,
                                     choose: { choose(view) }, drop: { job.images[view] = $0 },
                                     remove: { job.images.removeValue(forKey: view) })
                        }
                    }
                    Text("Vier Ansichten derselben Pose. Hintergründe werden automatisch freigestellt.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                PanelSection("KI-Modell") {
                    ChipPicker(options: [("Standard", "standard"), ("Turbo", "turbo")], selection: $job.model)
                    Text(job.model == "standard" ? "30 Schritte · genauer, dauert länger" : "5 Schritte · schneller, etwas gröber")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PanelSection("Auflösung") {
                    ChipPicker(options: [("380", 380), ("768", 768), ("1024", 1024)], selection: $job.resolution)
                    Text(job.resolution == 380 ? "Schnell, wenige Details" : job.resolution == 768 ? "Ausgewogen" : "Viele Details, große Datei")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PanelSection("Optionen") {
                    Toggle("Farben aus den Bildern übertragen", isOn: $job.color)
                    if job.color { Toggle("Motiv ist eine Person", isOn: $job.person) }
                    Text(job.color ? "Braucht alle vier Ansichten. Erzeugt Vertex-Farben, keine UV-Textur." : "Ohne Farben genügt eine Ansicht.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .disabled(manager.working)
                Link("Hunyuan3D-Lizenz", destination: URL(string: "https://huggingface.co/tencent/Hunyuan3D-2mv/blob/main/LICENSE")!)
                    .font(.caption)
            } footer: {
                PrimaryActionButton(title: "3D-Modell erstellen", icon: "cube", running: manager.working, enabled: job.ready,
                                    action: { job.start() }, cancel: { manager.cancel() })
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if manager.working || manager.isGeneration && manager.result != nil || manager.isGeneration && !manager.detail.isEmpty {
                        PipelineCard(manager: manager, color: job.color)
                    } else {
                        Card {
                            HStack(spacing: 18) {
                                Image(systemName: "photo.stack").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Image(systemName: "cpu").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Image(systemName: "cube.transparent").font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Aus Fotos wird eine Blender-Datei").font(.headline)
                                    Text(job.ready ? "Bereit. Starte mit ⌘↩." : job.color ? "Lege links vier Ansichten ab oder schalte die Farben aus." : "Lege links mindestens eine Ansicht ab.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    ModelHistory(source: "images", refresh: manager.result, rerun: manager.working ? nil : { job.load($0) })
                }.padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func choose(_ view: String) {
        let panel = NSOpenPanel()
        panel.title = "Bild für die Ansicht auswählen"
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { job.images[view] = url }
    }
}

/// Shows where a 3D job is, derived from the worker's status messages.
private struct PipelineCard: View {
    @ObservedObject var manager: DownloadManager
    var color: Bool
    @State private var started = Date()

    private var steps: [(String, [String])] {
        var list: [(String, [String])] = [("Bilder vorbereiten", ["vorbereitet", "Verbindung"]),
                                          ("3D-Form berechnen", ["3D-Form", "KI-Modell geladen"]),
                                          ("Oberfläche erstellen", ["Oberfläche"])]
        if color { list.append(("Farben übertragen", ["Farben"])) }
        list.append(("Blender-Datei erstellen", ["übertragen", "Blender-Datei wird"]))
        return list
    }
    private var current: Int {
        if manager.result != nil { return steps.count }
        return steps.lastIndex { step in step.1.contains { manager.status.contains($0) } } ?? lastStep
    }
    @State private var lastStep = 0
    private var waiting: Bool { manager.working && (manager.status.contains("belegt") || manager.status.contains("Vorrang")) }
    private var failed: Bool { !manager.working && manager.result == nil }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(manager.result != nil ? "Fertig" : failed ? manager.status : "3D-Modell wird erstellt").font(.headline)
                    Spacer()
                    if manager.working {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsedText(context.date.timeIntervalSince(started))).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(steps.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        ZStack {
                            if index < current { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if index == current && manager.working {
                                if waiting { Image(systemName: "hourglass.circle.fill").foregroundStyle(.orange) }
                                else { ProgressView().controlSize(.small) }
                            } else if index == current && failed { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                            else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                        }.frame(width: 18)
                        Text(steps[index].0).foregroundStyle(index <= current ? .primary : .secondary)
                            .fontWeight(index == current && manager.working ? .semibold : .regular)
                    }
                }
                if manager.working { Text(manager.status).font(.caption).foregroundStyle(waiting ? .orange : .secondary) }
                if !manager.detail.isEmpty { Text(manager.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6) }
                if let result = manager.result { ResultActions(url: result) }
            }
        }
        .onAppear { if manager.working { started = Date() } }
        .onChange(of: manager.working) { _, working in if working { started = Date(); lastStep = 0 } }
        .onChange(of: manager.status) { _, _ in if manager.working { lastStep = current } }
    }
}

struct ResultActions: View {
    var url: URL
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.fill").foregroundStyle(Color.accentColor)
            Text(url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("In Blender öffnen") { openInBlender(url) }.buttonStyle(.borderedProminent).disabled(blenderApplication() == nil)
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

func openInBlender(_ url: URL) {
    guard let app = blenderApplication() else { return }
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
}

// MARK: - Modell importieren

struct ImportToolView: View {
    @ObservedObject var manager: DownloadManager
    @FocusState private var focused: Bool
    private let sources = ["Sketchfab", "Poly Haven", "Printables", "Blendkit (kostenlos)", "Fab (teilweise)"]
    private let formats = "BLEND · GLB · glTF · FBX · OBJ · STL · PLY · 3MF · ZIP"

    var body: some View {
        HStack(spacing: 0) {
            ToolPanel(title: "Modell importieren", subtitle: "Link oder Datei → Blender-Datei", icon: "square.and.arrow.down") {
                PanelSection("Modell-Link") {
                    TextField("https://…", text: $manager.link)
                        .textFieldStyle(.roundedBorder).focused($focused).disabled(manager.working)
                        .onSubmit { manager.start() }
                    FlowChips(items: sources)
                }
                PanelSection("Oder eine Datei") {
                    Button { manager.chooseFile() } label: {
                        Label("Datei auswählen …", systemImage: "doc.badge.plus").frame(maxWidth: .infinity)
                    }.controlSize(.large).disabled(manager.working)
                    Text(formats).font(.caption).foregroundStyle(.secondary)
                    Text("Für CGTrader, TurboSquid und andere Shops die Datei dort herunterladen und hier auswählen.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Die App verwaltet keine Konten und kauft nichts. Die Nutzungsrechte des Modells gelten weiter.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } footer: {
                PrimaryActionButton(title: "Herunterladen", icon: "arrow.down.circle", running: manager.working,
                                    enabled: !manager.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    action: { manager.start() }, cancel: { manager.cancel() })
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if manager.working || (!manager.isGeneration && (manager.result != nil || !manager.detail.isEmpty)) {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    if manager.working { ProgressView().controlSize(.small) }
                                    else if manager.result != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                    else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                                    Text(manager.status).font(.headline).textSelection(.enabled)
                                }
                                if !manager.detail.isEmpty { Text(manager.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6) }
                                if manager.status == "Download fehlgeschlagen.", !manager.link.isEmpty { Button("Webseite öffnen") { manager.openPage() } }
                                if let result = manager.result { ResultActions(url: result) }
                            }
                        }
                    }
                    ModelHistory(source: "import", refresh: manager.result)
                }.padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onAppear { focused = true }
    }
}

private struct FlowChips: View {
    var items: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 5)], alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(item).font(.system(size: 11)).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
    }
}


// MARK: - Figur mit Pose (Hunyuan3D-Omni)

private struct FigureToolView: View {
    @ObservedObject var job: ThreeDJob
    @ObservedObject var figure: FigureJob

    var body: some View {
        HStack(spacing: 0) {
            ToolPanel(title: "Bild zu 3D", subtitle: "Hunyuan3D-Omni · eine MI50 auf bigki", icon: "figure.stand") {
                PanelSection("Art") {
                    ChipPicker(options: [("Objekt", "objekt"), ("Figur mit Pose", "figur")], selection: $job.mode)
                }.disabled(figure.running)
                PanelSection("Foto der Person") {
                    DropTile(label: "Foto", url: figure.image, size: 180, disabled: figure.running,
                             choose: choose, drop: { figure.image = $0 }, remove: { figure.image = nil })
                    Text("Ganze Person, gut ausgeleuchtet, Hintergrund wird freigestellt.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                PanelSection("Pose") {
                    ForEach(FigureJob.poses, id: \.1) { title, id, note in
                        Button { figure.pose = id } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: figure.pose == id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(figure.pose == id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(title).font(.callout.weight(.medium))
                                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.disabled(figure.running)
                Text("Lizenz Hunyuan3D-Omni: nur privat, nicht in der EU/UK/Südkorea veröffentlichen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } footer: {
                PrimaryActionButton(title: "Figur erstellen", icon: "figure.stand", running: figure.running, enabled: figure.image != nil,
                                    action: { figure.start() }, cancel: { figure.cancel() })
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: figure.running ? "hourglass" : figure.result != nil ? "checkmark.circle.fill" : "figure.stand")
                                    .foregroundStyle(figure.result != nil ? Color.green : Color.accentColor)
                                Text(figure.running ? "Figur wird erstellt" : figure.result != nil ? "Fertig" : "Ein Mensch aus einem Foto – in der Pose, die du wählst")
                                    .font(.headline)
                                Spacer()
                                if figure.running {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(elapsedText(context.date.timeIntervalSince(figure.started))).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if figure.running { Text(figure.status).font(.caption).foregroundStyle(.secondary); ProgressView().progressViewStyle(.linear) }
                            else if let error = figure.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            else if figure.result == nil {
                                Text("Dauert etwa 7 Minuten auf einer MI50. Ergebnis: eine .glb-Figur ohne Farben, fertig zum Riggen (figur.auto_rig) und Posieren in der Blender-Sitzung.")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if let result = figure.result { ResultActions(url: result) }
                        }
                    }
                    ModelHistory(source: "figur", refresh: figure.result, rerun: nil)
                }.padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Foto der Person auswählen"
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { figure.image = url }
    }
}
