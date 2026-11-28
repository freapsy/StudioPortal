import SwiftUI
import AppKit
import AVFoundation

struct MusicToolView: View {
    @ObservedObject var studio: MusicStudio

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Musik", subtitle: "MiniMax Music 3 · rechnet auf bigki · veröffentlichte Musik als KI-erzeugt kennzeichnen", icon: "music.note") {
                let previews = studio.latestPreviews
                if previews.count > 1 && !studio.running {
                    Button { studio.renderFull(previews) } label: { Label("Alle \(previews.count) voll rendern", systemImage: "sparkles") }
                        .help("Die Vorschauen der letzten Runde gleichzeitig in voller Qualität rendern – je eine Grafikkarte")
                }
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MusicStage(studio: studio)
                    MusicComposer(studio: studio)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                MusicFeed(studio: studio)
            }
        }
        .onAppear { studio.loadExamples(); studio.refresh() }
        .alert("Hinweis", isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })) {
            Button("OK", role: .cancel) { studio.errorMessage = nil }
        } message: { Text(studio.errorMessage ?? "") }
    }
}

func lengthText(_ seconds: Double) -> String {
    let n = Int(seconds.rounded()); return n < 60 ? "\(n) s" : String(format: "%d:%02d min", n / 60, n % 60)
}

private func songChips(_ song: Song) -> some View {
    ChipFlow(spacing: 4) {
        MetaChip(text: song.isPreview ? "Vorschau" : "Voll", icon: song.isPreview ? "eye" : "checkmark.seal", tint: song.isPreview ? .orange : .green)
        if let length = song.length { MetaChip(text: lengthText(length), icon: "clock") }
        if song.isInstrumental { MetaChip(text: "ohne Gesang", icon: "pianokeys") }
        if let seed = song.lmSeed { MetaChip(text: "\(seed)", icon: "dice") }
        MetaChip(text: song.date.formatted(date: .abbreviated, time: .shortened), icon: "calendar")
        if let origin = song.origin, !origin.isEmpty { let o = originDisplay(origin); MetaChip(text: o.text, icon: o.icon) }
    }
}

// MARK: - Stage (selected song)

private struct MusicStage: View {
    @ObservedObject var studio: MusicStudio
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if studio.running { MusicProgressCard(studio: studio) }
                if let song = studio.selected {
                    SongDetail(studio: studio, song: song)
                } else if !studio.running {
                    MusicStart(studio: studio)
                }
            }
            .padding(24).frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SongDetail: View {
    @ObservedObject var studio: MusicStudio
    var song: Song
    private var isPlaying: Bool { studio.playing == song.url && studio.player?.isPlaying == true }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    Button { studio.toggle(song) } label: {
                        ZStack {
                            MusicCover(caption: song.caption, seed: song.lmSeed, instrumental: song.isInstrumental, preview: song.isPreview, compact: true)
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).shadow(radius: 3)
                        }
                        .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).help(isPlaying ? "Pause" : "Abspielen")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(song.title).font(.title3.weight(.semibold)).lineLimit(2)
                        songChips(song)
                    }
                    Spacer(minLength: 0)
                    StageCloseButton { studio.selected = nil }
                }
                HStack(spacing: 8) {
                    Button { studio.useSettings(song) } label: { Label("Übernehmen", systemImage: "arrow.uturn.backward") }
                        .help("Beschreibung, Songtext und Melodie-Seed in die Eingabe übernehmen")
                    Button { studio.vary(song) } label: { Label("Variieren", systemImage: "dice") }
                        .help("Gleiche Beschreibung, neue Melodie – startet sofort").disabled(studio.running)
                    if song.isPreview {
                        Button { studio.renderFull(song) } label: { Label("Voll rendern", systemImage: "sparkles") }
                            .help("Denselben Song mit 30 Schritten sauber neu synthetisieren (~5 min)").disabled(studio.running)
                    }
                    Spacer()
                    Button { studio.reveal(song) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Im Finder zeigen")
                }
                .controlSize(.small)
                if !song.caption.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        PopoverTitle("Beschreibung")
                        Text(song.caption).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !song.lyrics.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        PopoverTitle("Songtext")
                        Text(song.lyrics).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// What to do when nothing is selected: three steps and official examples as starting points.
private struct MusicStart: View {
    @ObservedObject var studio: MusicStudio
    var body: some View {
        StartView(icon: "waveform", title: "Neuer Song", steps: [
            "Unten beschreiben, wie es klingen soll: Stil, Tempo, Instrumente, Stimme, Stimmung – am besten auf Englisch.",
            "„Mit Gesang“: Songtext darunter schreiben. „Ohne Gesang“: kein Text nötig.",
            "⌘↩ macht drei kurze Vorschauen (~5 min). Die beste rechts anklicken und „Voll rendern“.",
        ]) {
            if !studio.examples.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    PopoverTitle("Oder mit einem Beispiel anfangen – füllt Beschreibung und Songtext")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                        ForEach(studio.examples.prefix(9)) { item in
                            Button { studio.apply(item) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.group == "Instrumental" ? "pianokeys" : "music.mic").foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                                        Text(item.group == "Instrumental" ? "ohne Gesang" : "mit Gesang").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                            }.buttonStyle(.plain).help(item.caption)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Composer

private struct MusicComposer: View {
    @ObservedObject var studio: MusicStudio
    @State private var showLyrics = true
    @State private var savedLyrics = ""
    private var instrumental: Bool {
        studio.settings.lyrics.trimmingCharacters(in: .whitespacesAndNewlines) == MusicSettings.instrumental.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func insert(_ skeleton: String) {
        let current = studio.settings.lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        studio.settings.lyrics = current.isEmpty ? skeleton : current + "\n\n" + skeleton
        showLyrics = true
    }
    private var activePreset: MusicPreset? { MusicPreset.all.first { $0.matches(studio.settings) } }
    private var estimate: String {
        let perSong = studio.settings.steps <= 8 ? 3.0 : 5.0 * max(1, studio.settings.duration / 45)
        return "ca. \(Int(perSong.rounded())) min · \(studio.settings.variants == 1 ? "1 Karte" : "\(studio.settings.variants) Karten parallel")"
    }
    private var lyricLines: Int { studio.settings.lyrics.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("[") }.count }
    private var advancedChanged: Bool {
        let d = MusicSettings(); return studio.settings.lmCfg != d.lmCfg || studio.settings.ditCfg != d.ditCfg || studio.settings.topK != d.topK
    }

    var body: some View {
        Composer(text: $studio.settings.caption, placeholder: "Beschreibung: Stil, Tempo, Tonart, Instrumente, Stimme, Stimmung …",
                 actionTitle: studio.settings.variants > 1 ? "\(studio.settings.variants) Varianten" : "Song erzeugen", actionIcon: "music.note",
                 running: studio.running,
                 enabled: !studio.settings.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !studio.settings.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                 action: { studio.start() }, cancel: { studio.cancel() }, minHeight: 36, maxHeight: 110) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Picker("", selection: Binding(get: { instrumental }, set: { on in
                        if on { if !instrumental { savedLyrics = studio.settings.lyrics }; studio.settings.lyrics = MusicSettings.instrumental }
                        else { studio.settings.lyrics = savedLyrics; showLyrics = true }
                    })) {
                        Label("Mit Gesang", systemImage: "music.mic").tag(false)
                        Label("Ohne Gesang", systemImage: "pianokeys").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Ohne Gesang = Instrumental: es wird kein Songtext gebraucht")
                    if instrumental {
                        Text("kein Songtext nötig").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button { withAnimation(.easeOut(duration: 0.15)) { showLyrics.toggle() } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showLyrics ? 90 : 0))
                                Text("Songtext").font(.system(size: 12, weight: .semibold))
                                Text(lyricLines == 0 ? "fehlt noch" : "\(lyricLines) Zeilen").font(.caption)
                                    .foregroundStyle(lyricLines == 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                            }
                        }.buttonStyle(.plain).help("Songtext ein- oder ausklappen")
                        Spacer()
                        Menu("Aufbau einfügen") {
                            Button("Kurz: Strophe, Refrain") { insert("[verse]\n\n\n[chorus]\n\n") }
                            Button("Song: Intro, 2 Strophen, Refrains, Bridge, Outro") {
                                insert("[intro]\n\n[verse]\n\n\n[chorus]\n\n\n[verse]\n\n\n[chorus]\n\n\n[bridge]\n\n[chorus]\n\n\n[outro]\n")
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(.caption)
                        .help("Fügt die Abschnitts-Marken ein ([verse] = Strophe, [chorus] = Refrain) – darunter je Zeile eine gesungene Zeile schreiben")
                    }
                    if instrumental { Spacer() }
                }
                if !instrumental && showLyrics {
                    ZStack(alignment: .topLeading) {
                        if studio.settings.lyrics.isEmpty {
                            Text("Je Zeile eine gesungene Zeile. Abschnitte mit Marken:\n[verse]  Strophe …\n[chorus]  Refrain …")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.tertiary).padding(.horizontal, 5).allowsHitTesting(false)
                        }
                        TextEditor(text: $studio.settings.lyrics)
                            .font(.system(.callout, design: .monospaced)).scrollContentBackground(.hidden)
                            .frame(height: 96)
                    }
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
            }
        } pills: {
            OptionPill(icon: activePreset?.choice.icon ?? "square.grid.2x2", title: activePreset?.choice.title ?? "Eigene Einstellung",
                       help: "Voreinstellung", highlighted: activePreset != nil, width: 360) {
                HStack {
                    PopoverTitle("Voreinstellung"); Spacer()
                    InfoButton(title: "Musik – Regler erklärt", intro: "MiniMax Music 3 schreibt zuerst Melodie und Aufbau (Sprachmodell) und malt dann den Klang (Diffusion). Am meisten bringt eine ausführliche, dreiteilige Beschreibung.",
                               items: MusicPreset.info, tips: MusicPreset.tips)
                }
                PresetGrid(presets: MusicPreset.all.map(\.choice), selected: activePreset?.choice.id) { choice in
                    MusicPreset.all.first { $0.choice.id == choice.id }?.apply(to: &studio.settings)
                }
            }
            OptionPill(icon: "clock", title: lengthText(studio.settings.duration), help: "Länge (Obergrenze)", width: 300) {
                PopoverTitle("Länge")
                ChipPicker(options: [("30 s", 30.0), ("1 min", 60.0), ("2 min", 120.0), ("3 min", 180.0)], selection: $studio.settings.duration)
                Slider(value: $studio.settings.duration, in: 10...360, step: 5).controlSize(.small)
                if let suggested = MusicPreset.suggestedLength(studio.settings.lyrics), abs(suggested - studio.settings.duration) >= 15 {
                    Button("Passend zum Text: \(lengthText(suggested)) (≈ 6 s je Zeile)") { studio.settings.duration = suggested }
                        .buttonStyle(.link).font(.caption)
                } else {
                    Text("Obergrenze – das Modell kann früher enden.").font(.caption).foregroundStyle(.secondary)
                }
            }
            OptionPill(icon: studio.settings.steps <= 8 ? "eye" : "checkmark.seal", title: studio.settings.steps <= 8 ? "Vorschau" : "Voll",
                       help: "Qualität", width: 260) {
                PopoverTitle("Qualität")
                ChipPicker(options: [("Vorschau · 8", 8), ("Voll · 30", 30)], selection: $studio.settings.steps)
                Text(estimate).font(.caption).foregroundStyle(.secondary)
            }
            OptionPill(icon: "square.stack", title: "× \(studio.settings.variants)", help: "Varianten", width: 260) {
                PopoverTitle("Varianten")
                ChipPicker(options: [("1", 1), ("2", 2), ("3", 3)], selection: $studio.settings.variants)
                Text("Jede Variante rechnet auf einer eigenen MI50 – drei dauern so lange wie eine.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OptionPill(icon: "doc", title: studio.settings.format.uppercased(), help: "Dateiformat", width: 200) {
                PopoverTitle("Format")
                ChipPicker(options: [("MP3", "mp3"), ("WAV", "wav")], selection: $studio.settings.format)
            }
            OptionPill(icon: studio.settings.seedLocked ? "lock.fill" : "dice", title: studio.settings.seedLocked ? "Seed \(studio.settings.lmSeed)" : "Seed zufällig",
                       help: "Melodie-Seed", highlighted: studio.settings.seedLocked, width: 280) {
                SeedEditor(seed: $studio.settings.lmSeed, locked: $studio.settings.seedLocked,
                           note: "Bestimmt Melodie, Aufbau und Länge. Varianten nutzen Seed, Seed+1, Seed+2.")
            }
            OptionPill(icon: "slider.horizontal.3", title: "Mehr", help: "Erweiterte Einstellungen", highlighted: advancedChanged, width: 280) {
                PopoverTitle("Erweitert")
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("LM-CFG"); Spacer(); TextField("", value: $studio.settings.lmCfg, format: .number).textFieldStyle(.roundedBorder).frame(width: 70) }
                    HStack { Text("DiT-CFG"); Spacer(); TextField("", value: $studio.settings.ditCfg, format: .number).textFieldStyle(.roundedBorder).frame(width: 70) }
                    HStack { Text("Top-K"); Spacer(); Stepper("\(studio.settings.topK)", value: $studio.settings.topK, in: 1...500).fixedSize() }
                    HStack { Text("Klang-Seed"); Spacer(); TextField("", value: $studio.settings.seed, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 120) }
                    Button("Auf Standard zurücksetzen") { let d = MusicSettings(); studio.settings.lmCfg = d.lmCfg; studio.settings.ditCfg = d.ditCfg; studio.settings.topK = d.topK }
                }.font(.callout)
            }
        }
    }
}

// MARK: - Feed

private struct MusicFeed: View {
    @ObservedObject var studio: MusicStudio
    var body: some View {
        VStack(spacing: 0) {
            FeedHeader(title: "Songs", count: studio.songs.count, folder: musicDirectory)
            if studio.songs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.tertiary)
                    Text("Deine Songs erscheinen hier – mit Beschreibung und Seed zum Wiederverwenden.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(studio.songs) { song in SongCard(studio: studio, song: song) }
                    }.padding(10)
                }
            }
        }
        .frame(width: FeedMetrics.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SongCard: View {
    @ObservedObject var studio: MusicStudio
    var song: Song
    @State private var hover = false
    private var isPlaying: Bool { studio.playing == song.url && studio.player?.isPlaying == true }
    private var selected: Bool { studio.selected?.id == song.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Button { studio.toggle(song) } label: {
                    ZStack {
                        MusicCover(caption: song.caption, seed: song.lmSeed, instrumental: song.isInstrumental, preview: song.isPreview, compact: true)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).shadow(radius: 2)
                    }
                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help(isPlaying ? "Pause" : "Abspielen")
                Text(song.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
            }
            songChips(song)
            HStack(spacing: 6) {
                Button { studio.useSettings(song) } label: { Label("Übernehmen", systemImage: "arrow.uturn.backward") }
                    .help("Beschreibung, Songtext und Melodie-Seed in die Eingabe übernehmen")
                Button { studio.vary(song) } label: { Label("Variieren", systemImage: "dice") }
                    .help("Gleiche Beschreibung, neue Melodie – startet sofort").disabled(studio.running)
                Spacer()
                Menu {
                    if song.isPreview { Button("Voll rendern (~5 min)") { studio.renderFull(song) }.disabled(studio.running) }
                    Button("Im Finder zeigen") { studio.reveal(song) }
                    Divider()
                    Button("In den Papierkorb", role: .destructive) { studio.trash(song) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .controlSize(.small).buttonStyle(.bordered)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(hover ? 0.15 : 0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { studio.selected = selected ? nil : song }
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(object: song.url as NSURL) }
    }
}

private struct MusicProgressCard: View {
    @ObservedObject var studio: MusicStudio
    private func label(_ phase: String) -> String {
        switch phase { case "AR": "Melodie & Aufbau"; case "DiT": "Klangsynthese"; case "VAE": "Audio wird geschrieben"; case "Fertig": "Fertig"; case "Wartet": "wartet auf eine Karte"; default: "Startet" }
    }
    private func fraction(_ p: VariantProgress) -> Double {
        let part = p.total.map { Double(p.current ?? 0) / Double(max($0, 1)) } ?? 0
        switch p.phase { case "AR": return 0.2 * part; case "DiT": return 0.2 + 0.75 * part; case "VAE": return 0.97; case "Fertig": return 1; default: return 0 }
    }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: studio.progress.waiting == nil ? "waveform" : "hourglass").foregroundStyle(Color.accentColor)
                    Text(studio.progress.waiting == nil ? studio.progress.status : "Warte auf freie Grafikkarten").font(.headline)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedText(context.date.timeIntervalSince(studio.started))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let waiting = studio.progress.waiting { Text(waiting).font(.caption).foregroundStyle(.orange) }
                ForEach(studio.progress.variants.keys.sorted(), id: \.self) { key in
                    let p = studio.progress.variants[key]!
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Variante \(key)").font(.callout.weight(.medium))
                            Text(label(p.phase)).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if let c = p.current, let t = p.total { Text("\(c)/\(t)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        ProgressView(value: fraction(p)).controlSize(.small)
                    }
                }
                if studio.progress.variants.isEmpty && studio.progress.waiting == nil { ProgressView().progressViewStyle(.linear).controlSize(.small) }
            }
        }
    }
}

/// Stays at the bottom of the window in every tool while a song is loaded.
struct PlayerBar: View {
    @ObservedObject var studio: MusicStudio
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 12) {
                Image(systemName: "music.note").foregroundStyle(.white).frame(width: 26, height: 26)
                    .background(LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 6))
                Button { if let url = studio.playing { studio.toggle(url: url) } } label: {
                    Image(systemName: studio.player?.isPlaying == true ? "pause.fill" : "play.fill")
                }.buttonStyle(.borderless)
                Text(studio.playing.map { url in studio.songs.first { $0.url == url }?.title ?? Song.load(url, measureLength: false).title } ?? "")
                    .lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                Text(lengthText(studio.player?.currentTime ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(get: { studio.player?.currentTime ?? 0 }, set: { studio.player?.currentTime = $0 }),
                       in: 0...max(1, studio.player?.duration ?? 1)).controlSize(.small)
                Text(lengthText(studio.player?.duration ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { studio.stop() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Player schließen")
            }
            .padding(.horizontal, 18).frame(height: 48)
            .background(.bar)
        }
    }
}
