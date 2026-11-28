import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct H3StudioApp: App {
    @StateObject private var model = StudioModel()
    var body: some Scene {
        WindowGroup("H3 Studio") { StudioView(model: model).frame(minWidth: 1000, minHeight: 680) }
            .windowResizability(.contentMinSize)
    }
}

struct StudioView: View {
    @ObservedObject var model: StudioModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HistoryView(model: model).frame(width: 224)
                Divider()
                CanvasView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView(model: model).frame(width: 310)
            }
            Divider()
            StatusView(machine: model.machine) { model.copyAccessKey() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct HistoryView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Verlauf").font(.title3.weight(.semibold))
                Spacer()
                Text("\(model.history.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 15)
            if model.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.tertiary)
                    Text("Deine Bilder erscheinen hier.").font(.callout).foregroundStyle(.secondary)
                }.padding(18)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.history) { item in
                            Button { model.selected = item } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    thumbnail(item.url, size: 57)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.metadata?.settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? item.metadata!.settings.prompt : "Bild")
                                            .font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(item.date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(7).background(model.selected?.id == item.id ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Einstellungen übernehmen") { model.useSettings(item) }
                                Button("Im Finder zeigen") { model.reveal(item) }
                                Button("Als Referenz verwenden") { model.addReferences([item.url]) }
                                Divider()
                                Button("In den Papierkorb", role: .destructive) { model.trash(item) }
                            }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                        }
                    }.padding(.horizontal, 8)
                }
            }
        }.frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

func thumbnail(_ url: URL, size: CGFloat) -> some View {
    Group {
        if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFill() }
        else { Image(systemName: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }.frame(width: size, height: size).background(Color.secondary.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6))
}

struct CanvasView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color(nsColor: .underPageBackgroundColor).opacity(0.55)
                if let item = model.selected, let image = NSImage(contentsOf: item.url) {
                    Image(nsImage: image).resizable().scaledToFit().padding(30).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                } else {
                    VStack(spacing: 13) {
                        Image(systemName: "sparkles.rectangle.stack").font(.system(size: 39, weight: .light)).foregroundStyle(.tertiary)
                        Text("Beschreibe rechts dein Bild und tippe auf Erzeugen.").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.running { progressCard.padding(22) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 18) {
                action("Kopieren", "doc.on.doc") { if let item = model.selected { model.copy(item) } }
                action("Im Finder zeigen", "folder") { if let item = model.selected { model.reveal(item) } }
                action("Als Referenz verwenden", "photo.badge.plus") { if let item = model.selected { model.addReferences([item.url]) } }
                Spacer(minLength: 0)
                action("Nochmal", "arrow.clockwise") { if let item = model.selected { model.useSettings(item, newSeed: true) } }.disabled(model.running)
            }.font(.callout).padding(.horizontal, 18).padding(.vertical, 13).disabled(model.selected == nil)
        }
    }
    func action(_ title: String, _ icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: icon) }.buttonStyle(.borderless).help(title)
    }
    var progressCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(model.progress.phase).fontWeight(.semibold)
                if let step = model.progress.step, let total = model.progress.total { Text("Schritt \(step) von \(total)").foregroundStyle(.secondary) }
                if let index = model.progress.imageIndex, let total = model.progress.imageTotal, total > 1 { Text("· Bild \(index) von \(total)").foregroundStyle(.secondary) }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in Text(elapsed(context.date.timeIntervalSince(model.started))).monospacedDigit().foregroundStyle(.secondary) }
            }.font(.callout)
            if let step = model.progress.step, let total = model.progress.total, total > 0 { ProgressView(value: Double(step), total: Double(total)).controlSize(.small) }
            else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }
    func elapsed(_ seconds: TimeInterval) -> String { let n = max(0, Int(seconds)); return String(format: "%02d:%02d", n / 60, n % 60) }
}

struct InspectorView: View {
    @ObservedObject var model: StudioModel
    @State private var targeted = false
    @State private var expanded = false
    @FocusState private var sizeFocused: Bool
    private let sizes: [(String, Int, Int)] = [("1:1",1024,1024), ("4:3",1152,864), ("3:4",864,1152), ("16:9",1344,768), ("9:16",768,1344)]
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    Text("Einstellungen").font(.title3.weight(.semibold)).padding(.top, 2)
                    Picker("Modus", selection: $model.settings.mode) { Text("Neu").tag("Neu"); Text("Bearbeiten").tag("Bearbeiten") }.pickerStyle(.segmented).labelsHidden()
                    VStack(alignment: .leading, spacing: 7) {
                        label("Prompt")
                        ZStack(alignment: .topLeading) {
                            if model.settings.prompt.isEmpty { Text(model.settings.mode == "Neu" ? "Was möchtest du sehen?" : "Was soll sich an <Picture 1> ändern?").foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false) }
                            TextEditor(text: $model.settings.prompt).scrollContentBackground(.hidden).frame(minHeight: 100, idealHeight: 125, maxHeight: 170)
                        }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))
                    }
                    if model.settings.mode == "Bearbeiten" { references }
                    VStack(alignment: .leading, spacing: 8) {
                        label("Größe")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            ForEach(sizes, id: \.0) { item in
                                Button(item.0) { model.settings.width = item.1; model.settings.height = item.2 }.buttonStyle(SizeButtonStyle(selected: model.settings.width == item.1 && model.settings.height == item.2))
                            }
                            Text("Eigene").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                        HStack(spacing: 6) {
                            TextField("Breite", value: $model.settings.width, format: .number.grouping(.never)).focused($sizeFocused).textFieldStyle(.roundedBorder)
                            Text("×").foregroundStyle(.secondary)
                            TextField("Höhe", value: $model.settings.height, format: .number.grouping(.never)).focused($sizeFocused).textFieldStyle(.roundedBorder)
                            Text("px").font(.caption).foregroundStyle(.secondary)
                        }.onSubmit { model.settings.normalizeSize() }.onChange(of: sizeFocused) { _, value in if !value { model.settings.normalizeSize() } }
                        Text("Auf Vielfache von 32 aufgerundet.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 6) {
                        VStack(alignment: .leading, spacing: 7) { label("Seed"); TextField("Seed", value: $model.settings.seed, format: .number.grouping(.never)).textFieldStyle(.roundedBorder) }
                        Button { model.settings.seed = Int64.random(in: 0...Int64(Int32.max)) } label: { Image(systemName: "dice") }.help("Zufälliger Seed")
                        Button { model.settings.seedLocked.toggle() } label: { Image(systemName: model.settings.seedLocked ? "lock.fill" : "lock.open") }.help(model.settings.seedLocked ? "Seed festgehalten" : "Bei jedem Lauf neuer Seed")
                    }
                    HStack { label("Anzahl Bilder"); Spacer(); Stepper("\(model.settings.count)", value: $model.settings.count, in: 1...4).fixedSize() }
                    DisclosureGroup("Erweitert", isExpanded: $expanded) { advanced.padding(.top, 10) }.font(.callout.weight(.medium))
                }.padding(18)
            }
            Divider()
            Button { model.running ? model.cancel() : model.start() } label: {
                Text(model.running ? "Abbrechen" : "Erzeugen").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).tint(model.running ? .red : .accentColor).keyboardShortcut(.return, modifiers: .command).padding(16)
        }.frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
    func label(_ text: String) -> some View { Text(text).font(.callout.weight(.semibold)) }
    var references: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { label("Referenzbilder"); Spacer(); Text("\(model.settings.references.count) / 16").font(.caption).foregroundStyle(.secondary) }
            Button { model.chooseReferences() } label: {
                VStack(spacing: 5) {
                    Image(systemName: "plus.rectangle.on.rectangle").font(.title3)
                    Text("Bilder ablegen oder auswählen").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 13).background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
            }.buttonStyle(.plain).onDrop(of: [.fileURL], isTargeted: $targeted, perform: acceptFiles)
            if !model.settings.references.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(model.settings.references.enumerated()), id: \.element.id) { index, reference in
                        VStack(spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                thumbnail(reference.url, size: 75)
                                Button { model.settings.references.removeAll { $0.id == reference.id } } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65)) }.buttonStyle(.plain).padding(3).help("Referenz entfernen")
                            }
                            Text("Picture \(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        }.onDrag { NSItemProvider(object: reference.id.uuidString as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                                guard let text = value as? String, let id = UUID(uuidString: text) else { return }
                                DispatchQueue.main.async { model.moveReference(id: id, before: reference.id) }
                            }; return true
                        }
                    }
                }
            }
            Text("Im Prompt als <Picture 1>, <Picture 2> usw. ansprechen. Ziehen zum Umsortieren.").font(.caption).foregroundStyle(.secondary)
        }
    }
    func acceptFiles(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup(), lock = NSLock(); var results: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { lock.lock(); results.append((index, url)); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.addReferences(results.sorted { $0.0 < $1.0 }.map(\.1)) }
        return !providers.isEmpty
    }
    var advanced: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack { Text("Schritte"); Spacer(); Stepper("\(model.settings.steps)", value: $model.settings.steps, in: 1...100).fixedSize() }
            Text("6 empfohlen").font(.caption).foregroundStyle(.secondary)
            HStack { Text("CFG"); Spacer(); TextField("CFG", value: $model.settings.cfg, format: .number).textFieldStyle(.roundedBorder).frame(width: 75) }
            Picker("Sampler", selection: $model.settings.sampler) { ForEach(Settings.samplers, id: \.self) { Text($0).tag($0) } }
            Picker("Scheduler", selection: $model.settings.scheduler) { Text("H3-Zeitplan").tag(""); ForEach(Settings.schedulers, id: \.self) { Text($0).tag($0) } }
            Picker("RNG", selection: $model.settings.rng) { ForEach(Settings.rngs, id: \.self) { Text($0).tag($0) } }
            Toggle("Flash Attention", isOn: $model.settings.flashAttention)
            Toggle("VAE-Kacheln", isOn: $model.settings.vaeTiling)
            VStack(alignment: .leading, spacing: 6) { Text("Weitere sd-cli-Argumente"); TextField("z. B. -n 'unscharf'", text: $model.settings.extra).textFieldStyle(.roundedBorder) }
            Button("Auf Standard zurücksetzen") {
                let defaults = Settings(); model.settings.steps = defaults.steps; model.settings.cfg = defaults.cfg; model.settings.sampler = defaults.sampler; model.settings.scheduler = defaults.scheduler; model.settings.rng = defaults.rng; model.settings.flashAttention = defaults.flashAttention; model.settings.vaeTiling = defaults.vaeTiling; model.settings.extra = ""
            }
        }.font(.callout)
    }
}

struct SizeButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct StatusView: View {
    var machine: MachineStatus
    var setup: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(machine.reachable ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(machine.reachable ? "bigki erreichbar" : "bigki nicht erreichbar")
            if !machine.reachable { Button("Zugang einrichten", action: setup).buttonStyle(.link).font(.caption) }
            Text("·").foregroundStyle(.tertiary)
            Text("GPUs \(machine.occupation)")
            Spacer()
            Image(systemName: "thermometer.medium").foregroundStyle(.secondary)
            Text(machine.temperatures.count == 3 ? machine.temperatures.map { "\($0) °C" }.joined(separator: "  /  ") : "Temperaturen unbekannt")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15).frame(height: 28).background(.bar)
    }
}
