import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageToolView: View {
    @ObservedObject var studio: ImageStudio
    var useFor3D: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Bild-Generator", subtitle: subtitle, icon: "sparkles") { selectionActions }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ImageCanvas(studio: studio)
                    ImageComposer(studio: studio)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                ImageFeed(studio: studio, useFor3D: useFor3D)
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })) {
            Button("OK", role: .cancel) { studio.errorMessage = nil }
        } message: { Text(studio.errorMessage ?? "") }
    }

    private var subtitle: String {
        if let item = studio.selected { return ImageMeta.line(item) }
        return "MiniMax H3 Image · rechnet auf bigki"
    }

    private var selectionActions: some View {
        HStack(spacing: 12) {
            iconButton("doc.on.doc", "Kopieren") { if let item = studio.selected { studio.copy(item) } }
            iconButton("folder", "Im Finder zeigen") { if let item = studio.selected { studio.reveal(item) } }
            iconButton("photo.badge.plus", "Als Referenz verwenden (Bearbeiten)") {
                if let item = studio.selected { studio.addReferences([item.url]); studio.settings.mode = "Bearbeiten" }
            }
            Button { if let item = studio.selected { useFor3D(item.url) } } label: { Label("Zu 3D", systemImage: "cube.transparent") }
                .help("Als Vorderansicht für „Bild zu 3D“ verwenden")
        }
        .disabled(studio.selected == nil)
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.borderless).help(help)
    }
}

/// Facts about a finished picture, shared by header and feed.
enum ImageMeta {
    static func line(_ item: HistoryItem) -> String {
        var parts = [item.date.formatted(date: .abbreviated, time: .shortened)]
        if let s = item.metadata?.settings { parts.append("\(s.width)×\(s.height)"); parts.append("Seed \(item.metadata?.actualSeed ?? s.seed)") }
        if let d = item.metadata?.durationSeconds { parts.append(elapsedText(d)) }
        return parts.joined(separator: " · ")
    }

    static func chips(_ item: HistoryItem) -> [(String, String)] {
        guard let meta = item.metadata else { return [("photo", item.url.lastPathComponent)] }
        let s = meta.settings
        var chips: [(String, String)] = []
        if s.mode == "Bearbeiten" { chips.append(("wand.and.stars", "Bearbeitet · \(s.references.count) Ref.")) }
        chips.append(("aspectratio", "\(ImageFormat.aspect(of: s.width, s.height)) · \(String(format: "%.0f", ImageFormat.megapixels(s.width, s.height).rounded())) MP"))
        if let preset = ImagePreset.all.first(where: { $0.matches(s) }) { chips.append(("square.grid.2x2", preset.choice.title)) }
        if s.usesSpeedLora { chips.append(("hare", "Speed-LoRA")) } else if s.steps != 6 { chips.append(("stairs", "\(s.steps) Schritte")) }
        chips.append(("dice", "\(meta.actualSeed ?? s.seed)"))
        chips.append(("clock", elapsedText(meta.durationSeconds)))
        if let origin = meta.origin, !origin.isEmpty { let o = originDisplay(origin); chips.append((o.icon, o.text)) }
        return chips
    }
}

// MARK: - Canvas

private struct ImageCanvas: View {
    @ObservedObject var studio: ImageStudio
    var body: some View {
        ZStack(alignment: .top) {
            if let item = studio.selected, let image = NSImage(contentsOf: item.url) {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
                    .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrag { NSItemProvider(object: item.url as NSURL) }
                    .overlay(alignment: .topTrailing) { StageCloseButton { studio.selected = nil }.padding(.top, 14).padding(.trailing, 18) }
                    .contextMenu {
                        Button("Einstellungen übernehmen") { studio.useSettings(item) }
                        Button("Variieren (neuer Seed)") { studio.useSettings(item, newSeed: true) }.disabled(studio.running)
                        Button("Als Referenz verwenden") { studio.addReferences([item.url]); studio.settings.mode = "Bearbeiten" }
                    }
            } else if !studio.running {
                ScrollView {
                    StartView(icon: "sparkles.rectangle.stack", title: "Neues Bild", steps: [
                        "Unten auf Englisch beschreiben (80–150 Wörter): Motiv, Haltung, Kleidung, Ort, Licht, Kamera.",
                        "Erst „Entwurf“ oder 2–4 Bilder auf einmal – der Seed macht viel aus.",
                        "Das beste rechts anklicken: „Übernehmen“ und mit 16 MP fertig rechnen, oder „Als Referenz“ zum Ändern.",
                    ]) {
                        VStack(alignment: .leading, spacing: 6) {
                            PopoverTitle("Aufbau eines guten Prompts")
                            Text("[Motiv: Alter, Haare, Ausdruck] [Haltung, Blick] [Kleidung] [Ort, Hintergrund] [Licht, Tageszeit] [Kamera: z. B. 35mm, f/1.8] [Echtheit: natural skin texture, not retouched]")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if studio.running { ProgressCard(studio: studio).padding(20) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Composer

private struct ImageComposer: View {
    @ObservedObject var studio: ImageStudio
    private var activePreset: ImagePreset? { ImagePreset.all.first { $0.matches(studio.settings) } }
    private var editing: Bool { studio.settings.mode == "Bearbeiten" }
    private var advancedChanged: Bool {
        let d = Settings(), s = studio.settings
        return s.usesSpeedLora || s.steps != d.steps || s.cfg != d.cfg || s.sampler != d.sampler || s.scheduler != d.scheduler
            || s.rng != d.rng || !s.flashAttention || !s.vaeTiling || !s.extra.isEmpty
    }

    var body: some View {
        Composer(text: $studio.settings.prompt,
                 placeholder: editing ? "Was soll sich an <Picture 1> ändern? (englisch, konkret)" : "Beschreibe dein Bild – auf Englisch, 80–150 Wörter: Motiv, Licht, Kamera, Haut, Hintergrund …",
                 actionTitle: studio.settings.count > 1 ? "\(studio.settings.count) Bilder" : "Erzeugen", actionIcon: "sparkles",
                 running: studio.running,
                 enabled: !studio.settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!editing || !studio.settings.references.isEmpty),
                 action: { studio.start() }, cancel: { studio.cancel() }) {
            if editing { references }
        } pills: {
            OptionPill(icon: editing ? "wand.and.stars" : "sparkles", title: editing ? "Bearbeiten" : "Neues Bild",
                       help: "Neues Bild oder vorhandene Bilder bearbeiten", highlighted: editing, width: 260) {
                PopoverTitle("Modus")
                Picker("Modus", selection: $studio.settings.mode) {
                    Text("Neues Bild").tag("Neu"); Text("Bild bearbeiten").tag("Bearbeiten")
                }.pickerStyle(.segmented).labelsHidden()
                Text(editing ? "Bis zu 16 Referenzbilder; im Prompt als <Picture 1>, <Picture 2> … ansprechen." : "Bild nur aus dem Text.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            OptionPill(icon: activePreset?.choice.icon ?? "square.grid.2x2", title: activePreset?.choice.title ?? "Eigene Einstellung",
                       help: "Voreinstellung", highlighted: activePreset != nil, width: 360) {
                HStack {
                    PopoverTitle("Voreinstellung"); Spacer()
                    InfoButton(title: "Bild-Generator – Regler erklärt",
                               intro: "MiniMax H3 Image ist ein destilliertes Modell: es ist auf 6 Schritte mit CFG 1 trainiert. Die meisten Regler sind deshalb schon richtig – entscheidend sind Auflösung und ein ausführlicher Prompt.",
                               items: ImagePreset.info, tips: ImagePreset.tips)
                }
                PresetGrid(presets: ImagePreset.all.map(\.choice), selected: activePreset?.choice.id) { choice in
                    ImagePreset.all.first { $0.choice.id == choice.id }?.apply(to: &studio.settings)
                }
            }
            OptionPill(icon: "aspectratio", title: formatTitle, help: "Seitenverhältnis und Auflösung", width: 320) {
                FormatOptions(studio: studio)
            }
            OptionPill(icon: "square.on.square", title: "× \(studio.settings.count)", help: "Wie viele Bilder (verschiedene Seeds)", width: 240) {
                PopoverTitle("Anzahl")
                ChipPicker(options: [("1", 1), ("2", 2), ("3", 3), ("4", 4)], selection: $studio.settings.count)
                Text("Der Seed macht viel aus – 2–4 Bilder erzeugen und das beste nehmen.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OptionPill(icon: studio.settings.seedLocked ? "lock.fill" : "dice", title: studio.settings.seedLocked ? "Seed \(studio.settings.seed)" : "Seed zufällig",
                       help: "Seed", highlighted: studio.settings.seedLocked, width: 280) {
                SeedEditor(seed: $studio.settings.seed, locked: $studio.settings.seedLocked,
                           note: "Gleicher Seed + gleiche Größe + gleiche Einstellungen = gleiches Bild. Offen: bei jedem Lauf ein neuer.")
            }
            OptionPill(icon: "slider.horizontal.3", title: studio.settings.usesSpeedLora ? "Speed-LoRA" : "Mehr",
                       help: "Erweiterte Einstellungen (Schritte, Sampler, CFG …)", highlighted: advancedChanged, width: 330) {
                PopoverTitle("Erweitert")
                AdvancedImageOptions(studio: studio)
            }
        }
    }

    private var formatTitle: String {
        let s = studio.settings
        if let (aspect, mp) = ImageFormat.match(s.width, s.height) { return "\(aspect) · \(Int(mp)) MP" }
        return "\(s.width)×\(s.height)"
    }

    private var references: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(studio.settings.references.enumerated()), id: \.element.id) { index, reference in
                        DropTile(label: "Picture \(index + 1)", url: reference.url, size: 56,
                                 choose: { studio.chooseReferences() },
                                 drop: { studio.addReferences([$0]) },
                                 remove: { studio.settings.references.removeAll { $0.id == reference.id } })
                            .onDrag { NSItemProvider(object: reference.id.uuidString as NSString) }
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                guard let provider = providers.first else { return false }
                                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                                    guard let text = value as? String, let id = UUID(uuidString: text) else { return }
                                    DispatchQueue.main.async { studio.moveReference(id: id, before: reference.id) }
                                }
                                return true
                            }
                    }
                    if studio.settings.references.count < 16 {
                        DropTile(label: "Hinzufügen", url: nil, size: 56, choose: { studio.chooseReferences() }, drop: { studio.addReferences([$0]) }, remove: nil)
                    }
                }
            }
            Text("Referenzen \(studio.settings.references.count)/16 · im Prompt als <Picture 1>, <Picture 2> … · ziehen zum Umsortieren")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FormatOptions: View {
    @ObservedObject var studio: ImageStudio
    @FocusState private var sizeFocused: Bool
    private var aspectSelection: Binding<String> {
        Binding(get: { ImageFormat.match(studio.settings.width, studio.settings.height)?.0 ?? "Eigene" },
                set: { key in
                    guard key != "Eigene" else { return }
                    let current = ImageFormat.megapixels(studio.settings.width, studio.settings.height)
                    let mp = ImageFormat.match(studio.settings.width, studio.settings.height)?.1 ?? (current > 8 ? 16 : current > 2 ? 4 : 1)
                    (studio.settings.width, studio.settings.height) = ImageFormat.size(aspect: key, mp: mp)
                })
    }
    private var levelSelection: Binding<Double> {
        Binding(get: { ImageFormat.match(studio.settings.width, studio.settings.height)?.1 ?? 0 },
                set: { mp in (studio.settings.width, studio.settings.height) = ImageFormat.size(aspect: ImageFormat.aspect(of: studio.settings.width, studio.settings.height), mp: mp) })
    }

    var body: some View {
        PopoverTitle("Seitenverhältnis")
        ChipPicker(options: ImageFormat.aspects.map { ($0.0, $0.0) } + [("Eigene", "Eigene")], selection: aspectSelection, columns: 4)
        PopoverTitle("Auflösung")
        ChipPicker(options: ImageFormat.levels.map { ($0.title, $0.mp) }, selection: levelSelection, columns: 3)
        if let level = ImageFormat.levels.first(where: { $0.mp == levelSelection.wrappedValue }) {
            Text("Dauer je Bild etwa \(level.time) (wenn die Karten frei sind)").font(.caption).foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
            TextField("Breite", value: $studio.settings.width, format: .number.grouping(.never)).focused($sizeFocused).textFieldStyle(.roundedBorder)
            Text("×").foregroundStyle(.secondary)
            TextField("Höhe", value: $studio.settings.height, format: .number.grouping(.never)).focused($sizeFocused).textFieldStyle(.roundedBorder)
            Text(String(format: "%.1f MP", ImageFormat.megapixels(studio.settings.width, studio.settings.height))).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        .onSubmit { studio.settings.normalizeSize() }
        .onChange(of: sizeFocused) { _, focused in if !focused { studio.settings.normalizeSize() } }
    }
}

private struct AdvancedImageOptions: View {
    @ObservedObject var studio: ImageStudio
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Schritte"); Spacer(); Stepper("\(studio.settings.steps)", value: $studio.settings.steps, in: 1...100).fixedSize() }
            Text("6 empfohlen (destilliert) · CFG 1 · euler · H3-Zeitplan").font(.caption).foregroundStyle(.secondary)
            Toggle("Speed-LoRA (2 Schritte, Shift 12, bis ~4 MP)", isOn: Binding(get: { studio.settings.usesSpeedLora }, set: { studio.settings.setSpeedLora($0) }))
            HStack { Text("CFG"); Spacer(); TextField("CFG", value: $studio.settings.cfg, format: .number).textFieldStyle(.roundedBorder).frame(width: 75) }
            Picker("Sampler", selection: $studio.settings.sampler) { ForEach(Settings.samplers, id: \.self) { Text($0).tag($0) } }
            Picker("Scheduler", selection: $studio.settings.scheduler) { Text("H3-Zeitplan").tag(""); ForEach(Settings.schedulers, id: \.self) { Text($0).tag($0) } }
            Picker("RNG", selection: $studio.settings.rng) { ForEach(Settings.rngs, id: \.self) { Text($0).tag($0) } }
            Toggle("Flash Attention", isOn: $studio.settings.flashAttention)
            Toggle("VAE-Kacheln", isOn: $studio.settings.vaeTiling)
            VStack(alignment: .leading, spacing: 5) {
                Text("Weitere sd-cli-Argumente")
                TextField("z. B. -n 'unscharf'", text: $studio.settings.extra).textFieldStyle(.roundedBorder)
            }
            Button("Auf Standard zurücksetzen") {
                let d = Settings()
                studio.settings.steps = d.steps; studio.settings.cfg = d.cfg; studio.settings.sampler = d.sampler
                studio.settings.scheduler = d.scheduler; studio.settings.rng = d.rng; studio.settings.flashAttention = d.flashAttention
                studio.settings.vaeTiling = d.vaeTiling; studio.settings.extra = ""; studio.settings.speedLora = nil
            }
        }.font(.callout)
    }
}

// MARK: - Feed

private struct ImageFeed: View {
    @ObservedObject var studio: ImageStudio
    var useFor3D: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FeedHeader(title: "Verlauf", count: studio.history.count, folder: picturesDirectory)
            if !studio.compareSet.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.3x1").foregroundStyle(Color.accentColor)
                    Text(studio.compareSet.count < 2 ? "Vergleich: noch ein Bild wählen" : "Vergleich: \(studio.compareSet.count) Bilder")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if studio.comparing { ProgressView().controlSize(.small) }
                    Button("Erstellen") { studio.makeComparison() }.controlSize(.small).buttonStyle(.borderedProminent)
                        .disabled(studio.compareSet.count < 2 || studio.comparing)
                        .help("Beschriftete Leiste nebeneinander mit Seed, Größe, Dauer – landet in Bilder/Vergleiche")
                    Button { studio.compareSet = [] } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Auswahl verwerfen")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
            }
            if studio.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.tertiary)
                    Text("Deine Bilder erscheinen hier – mit Prompt und Einstellungen zum Wiederverwenden.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(studio.history) { item in
                            ImageFeedCard(item: item, selected: studio.selected?.id == item.id, running: studio.running,
                                          select: { studio.selected = studio.selected?.id == item.id ? nil : item },
                                          reuse: { studio.useSettings(item) },
                                          vary: { studio.useSettings(item, newSeed: true) },
                                          asReference: { studio.addReferences([item.url]); studio.settings.mode = "Bearbeiten" },
                                          to3D: { useFor3D(item.url) },
                                          reveal: { studio.reveal(item) },
                                          copy: { studio.copy(item) },
                                          trash: { studio.trash(item) },
                                          inCompare: studio.compareSet.contains(item.url),
                                          compare: { studio.toggleCompare(item.url) })
                        }
                    }.padding(10)
                }
            }
        }
        .frame(width: FeedMetrics.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ImageFeedCard: View {
    var item: HistoryItem
    var selected: Bool
    var running: Bool
    var select: () -> Void, reuse: () -> Void, vary: () -> Void, asReference: () -> Void
    var to3D: () -> Void, reveal: () -> Void, copy: () -> Void, trash: () -> Void
    var inCompare: Bool
    var compare: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FeedImage(url: item.url)
                .onDrag { NSItemProvider(object: item.url as NSURL) }
                .overlay(alignment: .topLeading) {
                    if inCompare {
                        Label("Vergleich", systemImage: "checkmark.circle.fill").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(.regularMaterial, in: Capsule()).padding(6)
                    }
                }
            if let prompt = item.metadata?.settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                Text(prompt).font(.system(size: 12)).lineLimit(3).foregroundStyle(.primary).help(prompt)
            }
            ChipFlow(spacing: 4) {
                ForEach(Array(ImageMeta.chips(item).enumerated()), id: \.offset) { _, chip in MetaChip(text: chip.1, icon: chip.0) }
            }
            HStack(spacing: 6) {
                Button(action: reuse) { Label("Übernehmen", systemImage: "arrow.uturn.backward") }
                    .help("Prompt und alle Einstellungen in die Eingabe übernehmen").disabled(item.metadata == nil)
                Button(action: vary) { Label("Variieren", systemImage: "dice") }
                    .help("Gleiche Einstellungen, neuer Seed – startet sofort").disabled(item.metadata == nil || running)
                Spacer()
                Menu {
                    Button(inCompare ? "Aus dem Vergleich nehmen" : "Zum Vergleich hinzufügen", action: compare)
                    Divider()
                    Button("Als Referenz verwenden", action: asReference)
                    Button("Für Bild zu 3D verwenden", action: to3D)
                    Button("Kopieren", action: copy)
                    Button("Im Finder zeigen", action: reveal)
                    Divider()
                    Button("In den Papierkorb", role: .destructive, action: trash)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .controlSize(.small).buttonStyle(.bordered)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(hover ? 0.15 : 0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Einstellungen übernehmen", action: reuse)
            Button("Variieren (neuer Seed)", action: vary).disabled(running)
            Button(inCompare ? "Aus dem Vergleich nehmen" : "Zum Vergleich hinzufügen", action: compare)
            Button("Als Referenz verwenden", action: asReference)
            Button("Für Bild zu 3D verwenden", action: to3D)
            Button("Im Finder zeigen", action: reveal)
            Divider()
            Button("In den Papierkorb", role: .destructive, action: trash)
        }
    }
}

private struct ProgressCard: View {
    @ObservedObject var studio: ImageStudio
    private var phaseText: String {
        switch studio.progress.phase {
        case "Verbinden": return "Verbinde mit bigki"
        case "Hochladen": return "Referenzen werden hochgeladen"
        case "Textencoder": return "Prompt wird verstanden"
        case "Rechnen": return "Bild wird berechnet"
        case "VAE": return "Bild wird fertiggestellt"
        case "Herunterladen": return "Bilder werden übertragen"
        case "Warten": return "Warte auf freie Grafikkarten"
        default: return studio.progress.phase
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: studio.progress.phase == "Warten" ? "hourglass" : "sparkles").foregroundStyle(Color.accentColor)
                Text(phaseText).fontWeight(.semibold)
                if let step = studio.progress.step, let total = studio.progress.total { Text("Schritt \(step)/\(total)").foregroundStyle(.secondary) }
                if let index = studio.progress.imageIndex, let total = studio.progress.imageTotal, total > 1 { Text("· Bild \(index)/\(total)").foregroundStyle(.secondary) }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedText(context.date.timeIntervalSince(studio.started))).monospacedDigit().foregroundStyle(.secondary)
                }
            }.font(.callout)
            if let step = studio.progress.step, let total = studio.progress.total, total > 0 {
                ProgressView(value: Double(step), total: Double(total)).controlSize(.small)
            } else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
            if let waiting = studio.progress.waiting { Text(waiting).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14).frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
