import SwiftUI
import PhotosUI

// Layout like the Mac app (Composer.swift): results as a feed in the middle, a composer at the bottom
// (text + small option pills + round send button). Mobbin references: TikTok Tako / ChatGPT / Suno composers.

struct Preset: Identifiable, Hashable { let id, title, icon, note: String }

enum Kind: String, CaseIterable, Identifiable {
    case image = "Bild", music = "Musik", video = "Video", model = "3D"
    var id: String { rawValue }
    var icon: String { switch self { case .image: "photo"; case .music: "music.note"; case .video: "film"; case .model: "cube" } }
    var key: String { switch self { case .image: "image"; case .music: "music"; case .video: "video"; case .model: "model" } }
}

/// Everything the composer can be set to; a feed card keeps a copy so "Übernehmen" can restore it.
struct Settings {
    var prompt = ""
    var preset: String?
    var aspect = "3:4"
    var vocals = false
    var lyrics = ""
    var length = 60.0
    var videoAspect = "9:16"
    var videoSeconds = 5.0
    var person = true
    var pose = "a"
    var photoData: Data?
    var extraPhotos: [Data] = []
    var seed = ""
    var steps = ""
    var guidance = ""
    var soundSeed = ""
    var ditGuidance = ""
    var topK = ""
    var variants = 0
    var resolution = 768
    var turbo = false
    var megapixels = 0.0
    var musicFormat = "mp3"
    var videoCards = 2
}

/// One creation in the feed.
@MainActor
final class Run: ObservableObject, Identifiable {
    let id = UUID()
    let kind: Kind
    let settings: Settings
    let summary: String
    let job = Job()
    let full = Job()
    init(kind: Kind, settings: Settings, summary: String) { self.kind = kind; self.settings = settings; self.summary = summary }
}

struct CreateView: View {
    @State private var kind: Kind = .image
    @State private var presets: [String: [Preset]] = [:]
    @State private var s = Settings()
    @State private var photo: PhotosPickerItem?
    @State private var runs: [Run] = []
    @State private var lyricsShown = false
    @State private var advancedShown = false
    @State private var extraPhotos: [PhotosPickerItem] = []
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if runs.isEmpty { empty }
                    ForEach(runs.reversed()) { run in
                        RunCard(run: run, reuse: { reuse(run) }, vary: { vary(run) })
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Erstellen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { kindPicker } }
            .task { await loadPresets() }
            .onChange(of: photo) { _, item in Task { s.photoData = try? await item?.loadTransferable(type: Data.self) } }
            .sheet(isPresented: $lyricsShown) { lyricsSheet }
            .sheet(isPresented: $advancedShown) { advanced }
            .onChange(of: extraPhotos) { _, photos in
                Task {
                    var results: [Data] = []
                    for photo in photos { if let data = try? await photo.loadTransferable(type: Data.self) { results.append(data) } }
                    s.extraPhotos = results
                }
            }
        }
    }

    private var kindPicker: some View {
        Picker("Art", selection: $kind) { ForEach(Kind.allCases) { Image(systemName: $0.icon).tag($0) } }
            .pickerStyle(.segmented).frame(width: 220)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: kind.icon).font(.system(size: 34, weight: .light)).foregroundStyle(.tint)
            Text(kind.rawValue + " erstellen").font(.headline)
            Text(hint).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 120)
    }

    private var hint: String {
        switch kind {
        case .image: "Beschreibe unten, was zu sehen sein soll. Ergebnisse erscheinen hier."
        case .music: "Beschreibe den Klang. Es entstehen drei Fassungen zum Anhören."
        case .video: "Beschreibe, was passiert. Videos haben Ton und sind nur privat."
        case .model: "Wähle unten ein Foto – daraus entsteht ein 3D-Modell oder eine Figur."
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kind != .model {
                TextField(placeholder, text: $s.prompt, axis: .vertical)
                    .lineLimit(1...6).focused($typing).font(.body)
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) {
                    pills
                    Button { advancedShown = true } label: { Pill(icon: "slider.horizontal.3", title: "Mehr") }
                } }
                sendButton
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.quaternary))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var placeholder: String {
        switch kind {
        case .image: "Was soll zu sehen sein?"
        case .music: "Wie soll es klingen?"
        case .video: "Was passiert im Video?"
        case .model: ""
        }
    }

    private var sendButton: some View {
        Button { typing = false; start(kind: kind, settings: s) } label: {
            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                .frame(width: 36, height: 36)
                .background(ready ? Color.accentColor : Color.secondary.opacity(0.25), in: Circle())
                .foregroundStyle(.white)
        }
        .disabled(!ready).accessibilityLabel("Erstellen")
    }

    @ViewBuilder private var pills: some View {
        if kind != .model, let list = presets[kind.key], !list.isEmpty {
            Menu {
                Picker("Stil", selection: $s.preset) {
                    Label("Frei", systemImage: "sparkles").tag(String?.none)
                    ForEach(list) { Label($0.title, systemImage: $0.icon).tag(Optional($0.id)) }
                }
            } label: { Pill(icon: "paintpalette", title: list.first { $0.id == s.preset }?.title ?? "Stil", on: s.preset != nil) }
        }
        switch kind {
        case .image:
            Menu { Picker("Format", selection: $s.aspect) { ForEach(["3:4", "1:1", "4:3", "2:3", "3:2"], id: \.self) { Text($0) } } }
                label: { Pill(icon: "aspectratio", title: s.aspect) }
            photoPill("Vorlage")
        case .music:
            Button { s.vocals = true; lyricsShown = true } label: {
                Pill(icon: s.vocals ? "music.mic" : "pianokeys", title: s.vocals ? "Gesang" : "Instrumental", on: s.vocals)
            }
            Menu { Picker("Länge", selection: $s.length) { ForEach([30.0, 60, 120, 180], id: \.self) { Text("\(Int($0)) s") } } }
                label: { Pill(icon: "timer", title: "\(Int(s.length)) s") }
        case .video:
            Menu { Picker("Format", selection: $s.videoAspect) { Text("Hochkant").tag("9:16"); Text("Quer").tag("16:9"); Text("Quadrat").tag("1:1") } }
                label: { Pill(icon: "aspectratio", title: s.videoAspect) }
            Menu { Picker("Länge", selection: $s.videoSeconds) { ForEach([3.0, 5, 8, 10], id: \.self) { Text("\(Int($0)) s") } } }
                label: { Pill(icon: "timer", title: "\(Int(s.videoSeconds)) s") }
        case .model:
            photoPill("Foto")
            Menu { Picker("Was ist drauf?", selection: $s.person) { Text("Person").tag(true); Text("Gegenstand").tag(false) } }
                label: { Pill(icon: s.person ? "figure.stand" : "shippingbox", title: s.person ? "Person" : "Gegenstand") }
            if s.person {
                Menu { Picker("Haltung", selection: $s.pose) { Text("A-Pose").tag("a"); Text("Hand hoch").tag("hand-hoch"); Text("Arme hoch").tag("arme-hoch") } }
                    label: { Pill(icon: "figure.arms.open", title: ["a": "A-Pose", "hand-hoch": "Hand hoch", "arme-hoch": "Arme hoch"][s.pose] ?? "Haltung") }
            }
        }
    }

    private func photoPill(_ title: String) -> some View {
        PhotosPicker(selection: $photo, matching: .images) {
            if let data = s.photoData, let ui = UIImage(data: data) {
                HStack(spacing: 5) {
                    Image(uiImage: ui).resizable().scaledToFill().frame(width: 20, height: 20).clipShape(Circle())
                    Text(title)
                }
                .font(.system(size: 13, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.14), in: Capsule()).foregroundStyle(Color.accentColor)
            } else {
                Pill(icon: "photo.badge.plus", title: title)
            }
        }
    }

    private var lyricsSheet: some View {
        NavigationStack {
            Form {
                Toggle("Mit Gesang", isOn: $s.vocals)
                if s.vocals {
                    Section { TextField("Liedtext, z. B. [Verse] … [Chorus] …", text: $s.lyrics, axis: .vertical).lineLimit(8...20) }
                        footer: { Text("Ohne Liedtext wird instrumental gerechnet.") }
                }
            }
            .navigationTitle("Gesang").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { lyricsShown = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var advanced: some View {
        NavigationStack {
            Form {
                if kind != .model {
                    TextField("Seed (leer für zufällig)", text: $s.seed).keyboardType(.numberPad)
                    TextField("Schritte (leer für Voreinstellung)", text: $s.steps).keyboardType(.numberPad)
                }
                if kind == .image || kind == .music {
                    Stepper(s.variants == 0 ? "Anzahl: Standard" : "Anzahl: \(s.variants)", value: $s.variants, in: 0...4)
                    TextField(kind == .image ? "CFG" : "Melodie-CFG", text: $s.guidance).keyboardType(.decimalPad)
                }
                switch kind {
                case .image:
                    Picker("Megapixel", selection: $s.megapixels) {
                        Text("Voreinstellung").tag(0.0)
                        ForEach([1.0, 2, 4, 8, 12, 16], id: \.self) { Text("\(Int($0)) MP").tag($0) }
                    }
                    PhotosPicker(selection: $extraPhotos, maxSelectionCount: 3, matching: .images) {
                        LabeledContent("Weitere Referenzen", value: String(s.extraPhotos.count))
                    }
                case .music:
                    Picker("Dateiformat", selection: $s.musicFormat) { Text("MP3").tag("mp3"); Text("WAV").tag("wav") }
                    TextField("Klang-Seed", text: $s.soundSeed).keyboardType(.numberPad)
                    TextField("Audio-CFG", text: $s.ditGuidance).keyboardType(.decimalPad)
                    TextField("Top-K", text: $s.topK).keyboardType(.numberPad)
                case .video:
                    Picker("Grafikkarten", selection: $s.videoCards) { Text("2").tag(2); Text("3").tag(3) }
                case .model:
                    if !s.person {
                        Picker("Auflösung", selection: $s.resolution) {
                            ForEach([380, 768, 1024], id: \.self) { Text(String($0)).tag($0) }
                        }
                        Toggle("Turbo", isOn: $s.turbo)
                        PhotosPicker(selection: $extraPhotos, maxSelectionCount: 3, matching: .images) {
                            LabeledContent("Links, hinten, rechts", value: String(s.extraPhotos.count))
                        }
                    }
                }
            }
            .navigationTitle("Erweiterte Optionen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { advancedShown = false } } }
        }
    }

    // MARK: Logic

    private var ready: Bool {
        switch kind {
        case .model: s.photoData != nil
        case .music: !s.prompt.trimmingCharacters(in: .whitespaces).isEmpty || s.preset != nil
        default: !s.prompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func reuse(_ run: Run) {
        kind = run.kind; s = run.settings
    }

    private func vary(_ run: Run) {
        var settings = run.settings
        settings.seed = ""
        settings.soundSeed = ""
        start(kind: run.kind, settings: settings)
    }

    private func loadPresets() async {
        guard presets.isEmpty, let value = try? await API.json("/api/presets") else { return }
        for (k, list) in value { presets[k] = (list as? [[String: String]] ?? []).map { Preset(id: $0["id"] ?? "", title: $0["title"] ?? "", icon: $0["icon"] ?? "circle", note: $0["note"] ?? "") } }
    }

    private func summary(_ kind: Kind, _ s: Settings) -> String {
        let style = kind == .model ? nil : presets[kind.key]?.first { $0.id == s.preset }?.title
        let parts: [String?]
        switch kind {
        case .image: parts = [style, s.aspect, s.photoData != nil ? "mit Vorlage" : nil]
        case .music: parts = [style, s.vocals && !s.lyrics.isEmpty ? "Gesang" : "instrumental", "\(Int(s.length)) s"]
        case .video: parts = [style, s.videoAspect, "\(Int(s.videoSeconds)) s"]
        case .model: parts = [s.person ? "Figur" : "Gegenstand"]
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func start(kind: Kind, settings s: Settings) {
        let run = Run(kind: kind, settings: s, summary: summary(kind, s))
        runs.append(run)
        let job = run.job
        let text = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String: Any] = [:]
        if let p = s.preset, kind != .model { args["preset"] = p }
        if let seed = Int(s.seed), (0...2_147_483_646).contains(seed) { args["seed"] = seed }
        if let steps = Int(s.steps), (1...100).contains(steps) { args["steps"] = steps }
        job.running = true; job.progress = "wird gesendet …"
        Task {
            var photoPath: String?
            if let data = s.photoData, kind == .model || kind == .image {
                do { photoPath = try await API.upload(data) } catch { job.error = error.localizedDescription; job.running = false; return }
            }
            var extras: [String] = []
            if kind == .image || (kind == .model && !s.person) {
                do { for photo in s.extraPhotos { extras.append(try await API.upload(photo)) } }
                catch { job.error = error.localizedDescription; job.running = false; return }
            }
            switch kind {
            case .image:
                args["prompt"] = text; args["aspect"] = s.aspect
                let references = [photoPath].compactMap { $0 } + extras
                if !references.isEmpty { args["references"] = references }
                if s.megapixels > 0 { args["megapixels"] = s.megapixels }
                if s.variants > 0 { args["count"] = s.variants }
                args["cfg"] = Double(s.guidance.replacingOccurrences(of: ",", with: "."))
                job.start("create_image", args)
            case .music:
                if !text.isEmpty { args["caption"] = text }
                if s.vocals, !s.lyrics.isEmpty { args["lyrics"] = s.lyrics } else { args["instrumental"] = true }
                args["duration"] = s.length
                args["format"] = s.musicFormat
                if s.variants > 0 { args["variants"] = s.variants }
                args["sound_seed"] = Int(s.soundSeed)
                args["lm_cfg"] = Double(s.guidance.replacingOccurrences(of: ",", with: "."))
                args["dit_cfg"] = Double(s.ditGuidance.replacingOccurrences(of: ",", with: "."))
                args["top_k"] = Int(s.topK)
                job.start("create_music", args)
            case .video:
                args["prompt"] = text; args["aspect"] = s.videoAspect; args["seconds"] = s.videoSeconds; args["cards"] = s.videoCards
                job.start("create_video", args, interval: 3)
            case .model:
                guard let photoPath else { job.running = false; return }
                if s.person { job.start("figure_3d", ["image": photoPath, "pose": s.pose], interval: 3) }
                else {
                    var request: [String: Any] = ["front": photoPath, "resolution": s.resolution, "model": s.turbo ? "turbo" : "standard"]
                    for (direction, image) in zip(["left", "back", "right"], extras) { request[direction] = image }
                    job.start("image_to_3d", request, interval: 3)
                }
            }
        }
    }
}

/// Small capsule in the composer ("3:4").
struct Pill: View {
    var icon: String
    var title: String
    var on = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title).lineLimit(1)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .foregroundStyle(on ? Color.accentColor : Color.primary)
        .background(on ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule())
    }
}

/// One feed card: settings line, prompt, progress or results, and "Übernehmen" / "Variieren".
struct RunCard: View {
    let run: Run
    @ObservedObject private var job: Job
    @ObservedObject private var full: Job
    var reuse: () -> Void
    var vary: () -> Void

    init(run: Run, reuse: @escaping () -> Void, vary: @escaping () -> Void) {
        self.run = run; self.job = run.job; self.full = run.full; self.reuse = reuse; self.vary = vary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: run.kind.icon).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                Text(run.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if job.running { Text("\(job.seconds) s").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if !run.settings.prompt.isEmpty { Text(run.settings.prompt).font(.subheadline).lineLimit(3) }

            if job.running {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(job.progress.isEmpty ? "läuft …" : job.progress).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Abbrechen", role: .destructive) { job.cancel() }.font(.footnote).buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
            if let error = job.error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            if let r = job.result { results(r) }

            if !job.running {
                HStack(spacing: 8) {
                    Button { reuse() } label: { Label("Übernehmen", systemImage: "arrow.uturn.down") }
                    Button { vary() } label: { Label("Variieren", systemImage: "arrow.triangle.2.circlepath") }
                }
                .font(.footnote.weight(.medium)).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func results(_ r: [String: Any]) -> some View {
        let paths = Self.paths(r)
        let preview = r["preview"] as? String
        switch run.kind {
        case .image, .video:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: paths.count > 1 ? 140 : 300), spacing: 8)], spacing: 8) {
                ForEach(paths, id: \.self) { path in
                    NavigationLink { FileDetail(path: path, title: run.settings.prompt) } label: {
                        RemoteImage(path: path, size: 700).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                if run.kind == .video { Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.9)) }
                            }
                    }
                }
            }
        case .music:
            ForEach(Array(paths.enumerated()), id: \.offset) { i, path in
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink { FileDetail(path: path, title: run.settings.prompt) } label: {
                        Label("Fassung \(i + 1) anhören", systemImage: "play.circle")
                    }.buttonStyle(.bordered)
                    if !full.running, full.result == nil {
                        Button("In voller Qualität rechnen") { full.start("render_music_full", ["files": [path]]) }.font(.footnote)
                    }
                }
            }
            if full.running { HStack { ProgressView(); Text(full.progress.isEmpty ? "voll rechnen …" : full.progress).font(.footnote).foregroundStyle(.secondary) } }
            if let error = full.error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            if let fr = full.result {
                ForEach(Self.paths(fr), id: \.self) { path in
                    NavigationLink { FileDetail(path: path) } label: { Label("Volle Fassung öffnen", systemImage: "music.note") }.font(.footnote)
                }
            }
        case .model:
            ForEach(paths, id: \.self) { path in
                NavigationLink { FileDetail(path: path, preview: preview) } label: {
                    Group { if let preview { RemoteImage(path: preview, size: 700) } else { Image(systemName: "cube").font(.largeTitle) } }
                        .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    static func paths(_ r: [String: Any]) -> [String] {
        if let files = r["files"] as? [String] { return files }
        if let songs = r["songs"] as? [[String: Any]] { return songs.compactMap { $0["audio"] as? String } }
        if let file = r["file"] as? String { return [file] }
        return []
    }
}
