import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SpeechToolView: View {
    @ObservedObject var studio: SpeechStudio

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Sprache", subtitle: "Fish Audio Drama 3 · 1× MI50 auf bigki · Built with Fish Audio", icon: "waveform.and.mic") {
                HStack(spacing: 8) {
                    if studio.server.running {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(studio.server.card.map { "Bereit · GPU \($0)" } ?? "Bereit")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        Button("Stoppen") { studio.stopServer() }
                            .controlSize(.small)
                            .help("Gibt die MI50-Grafikkarte sofort wieder frei (sonst automatisch nach 15 min Pause)")
                    } else if studio.server.starting {
                        ProgressView().controlSize(.mini)
                        Text("Lädt …").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Server vorwärmen") { studio.startServer() }
                            .controlSize(.small)
                            .disabled(studio.running)
                            .help("Lädt Drama 3 vorab in den VRAM einer MI50 – danach startet jede Sprachausgabe fast sofort")
                    }
                }
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SpeechStage(studio: studio)
                    SpeechComposer(studio: studio)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                SpeechFeed(studio: studio)
            }
        }
        .onAppear { studio.refresh(); studio.refreshServer() }
        .alert("Hinweis", isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })) {
            Button("OK", role: .cancel) { studio.errorMessage = nil }
        } message: { Text(studio.errorMessage ?? "") }
    }
}

private struct SpeechStage: View {
    @ObservedObject var studio: SpeechStudio

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if studio.running {
                    Card {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(studio.statusText.isEmpty ? "Sprache wird erzeugt …" : studio.statusText)
                                    .font(.callout.weight(.medium))
                                if let ttfa = studio.liveTTFAMs {
                                    Text(String(format: "Erstes Audio nach %.0f ms", ttfa))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Abbrechen") { studio.cancel() }.controlSize(.small)
                        }
                    }
                }
                if let clip = studio.selected {
                    SpeechClipDetail(studio: studio, clip: clip)
                } else if !studio.running {
                    StartView(icon: "waveform.and.mic", title: "Fish Audio Drama 3", steps: [
                        "Unten deutschen oder mehrsprachigen Text eingeben – optional mit Regie-Tags wie [laughs], [sighs], [whisper] oder <|speaker:0|>.",
                        "Optional eine 5–25 s Referenz-Audiodatei (WAV/M4A/MP3) zum Voice Cloning anhängen.",
                        "Mit ⌘↩ sprechen: Live-Wiedergabe startet direkt ab dem ersten Audio-Chunk von bigki.",
                    ]) {
                        VStack(alignment: .leading, spacing: 8) {
                            PopoverTitle("Beispiele zum Ausprobieren")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                                ForEach(SpeechStudio.starters, id: \.title) { item in
                                    Button { studio.settings.text = item.text } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title).font(.callout.weight(.medium))
                                            Text(item.note).font(.caption).foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SpeechClipDetail: View {
    @ObservedObject var studio: SpeechStudio
    var clip: SpeechClip
    private var playing: Bool { studio.playingURL == clip.url && studio.isPlayingClip }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    Button { studio.togglePlay(clip) } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [.accentColor, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        }
                        .frame(width: 60, height: 60)
                    }.buttonStyle(.plain).help(playing ? "Pause" : "Abspielen")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(clip.title).font(.title3.weight(.semibold)).lineLimit(2)
                        ChipFlow(spacing: 4) {
                            MetaChip(text: clip.engine == "qwen3-tts" ? "Qwen3-TTS" : "Drama 3", icon: "waveform", tint: .accentColor)
                            if let d = clip.duration { MetaChip(text: String(format: "%.1f s", d), icon: "clock") }
                            if let ttfa = clip.ttfaMs { MetaChip(text: String(format: "TTFA %.0f ms", ttfa), icon: "bolt", tint: ttfa < 400 ? .green : .orange) }
                            if let rtf = clip.rtf, rtf > 0 { MetaChip(text: String(format: "RTF %.2f×", rtf), icon: "speedometer", tint: rtf < 1.0 ? .green : .orange) }
                            if let ref = clip.referenceName { MetaChip(text: "Klon: \(ref)", icon: "person.wave.2") }
                            if let seed = clip.seed { MetaChip(text: "\(seed)", icon: "dice") }
                            MetaChip(text: clip.date.formatted(date: .abbreviated, time: .shortened), icon: "calendar")
                        }
                    }
                    Spacer(minLength: 0)
                    StageCloseButton { studio.selected = nil }
                }
                HStack(spacing: 8) {
                    Button { studio.useSettings(clip) } label: { Label("Übernehmen", systemImage: "arrow.uturn.backward") }
                    Button { studio.togglePlay(clip) } label: { Label(playing ? "Pause" : "Abspielen", systemImage: playing ? "pause" : "play") }
                    Spacer()
                    Button { studio.reveal(clip) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Im Finder zeigen")
                }.controlSize(.small)
                if !clip.text.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        PopoverTitle("Gesprochener Text")
                        Text(clip.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct SpeechComposer: View {
    @ObservedObject var studio: SpeechStudio
    @State private var showClone = false

    private func insertTag(_ tag: String) {
        let sep = studio.settings.text.isEmpty || studio.settings.text.hasSuffix(" ") || studio.settings.text.hasSuffix("\n") ? "" : " "
        studio.settings.text += sep + tag + " "
    }

    private func pickReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Referenzstimme (5–25 s, WAV/M4A/MP3) für Voice Cloning wählen"
        if panel.runModal() == .OK, let url = panel.url {
            studio.settings.voiceRefPath = url.path
            showClone = true
        }
    }

    var body: some View {
        Composer(text: $studio.settings.text,
                 placeholder: "Text eingeben … z. B. Grüß Sie Frau Weber, [calm] mir ist ein Fehler auf Ihrer Website aufgefallen.",
                 actionTitle: "Sprechen", actionIcon: "waveform.and.mic",
                 running: studio.running,
                 enabled: !studio.settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                 action: { studio.speak() }, cancel: { studio.cancel() }, minHeight: 54, maxHeight: 160) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Menu("Regie-Tag einfügen") {
                        Button("[calm] ruhig") { insertTag("[calm]") }
                        Button("[laughs] lachen") { insertTag("[laughs]") }
                        Button("[sighs] seufzen") { insertTag("[sighs]") }
                        Button("[whisper] flüstern") { insertTag("[whisper]") }
                        Button("[excited] begeistert") { insertTag("[excited]") }
                        Divider()
                        Button("<|speaker:0|> Sprecher 1") { insertTag("<|speaker:0|>") }
                        Button("<|speaker:1|> Sprecher 2") { insertTag("<|speaker:1|>") }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
                    Spacer()
                    Button {
                        if studio.settings.voiceRefPath == nil { pickReference() }
                        else { withAnimation { showClone.toggle() } }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.wave.2")
                            Text(studio.settings.voiceRefPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Stimme klonen …")
                                .lineLimit(1)
                        }.font(.caption)
                    }.buttonStyle(.borderless)
                    if studio.settings.voiceRefPath != nil {
                        Button { studio.settings.voiceRefPath = nil; studio.settings.referenceText = ""; showClone = false } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                        }.buttonStyle(.borderless).help("Referenzstimme entfernen")
                    }
                }
                if showClone, let path = studio.settings.voiceRefPath {
                    HStack(spacing: 8) {
                        Button("Andere Datei …") { pickReference() }.controlSize(.small)
                        TextField("Transkript der Referenzaufnahme (optional, verbessert Ähnlichkeit)", text: $studio.settings.referenceText)
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                    }
                    .help("Referenzdatei: \(path) – nur mit Einwilligung der sprechenden Person verwenden (Fish Audio Lizenz)")
                }
                Divider()
            }
        } pills: {
            OptionPill(icon: "cpu", title: studio.settings.engine == "qwen3-tts" ? "Qwen3-TTS" : "Drama 3",
                       help: "Sprachmodell", width: 260) {
                PopoverTitle("Sprachmodell")
                ChipPicker(options: [("Drama 3 (35B)", "drama-3"), ("Qwen3-TTS (1.7B)", "qwen3-tts")], selection: $studio.settings.engine)
                if studio.settings.engine == "qwen3-tts" {
                    TextField("Sprecher (z. B. Ryan, Vivian)", text: $studio.settings.speaker).textFieldStyle(.roundedBorder)
                    TextField("Stil-Anweisung (optional)", text: $studio.settings.instruct).textFieldStyle(.roundedBorder)
                } else {
                    Text("Fish Audio Drama 3 V2 (Q4_K Experten, FP32 Router, Q8 Backbone) auf 1× MI50.").font(.caption).foregroundStyle(.secondary)
                }
            }
            OptionPill(icon: studio.settings.livePlay ? "speaker.wave.2.fill" : "speaker.slash",
                       title: studio.settings.livePlay ? "Live-Stream" : "Nur WAV",
                       help: "Audio schon während der Erzeugung live abspielen",
                       highlighted: studio.settings.livePlay, width: 240) {
                PopoverTitle("Wiedergabe")
                Toggle("Live während Erzeugung abspielen", isOn: $studio.settings.livePlay)
                Text("Spielt Audio-Chunks direkt per SSE ab, sobald bigki die ersten Frames fertig hat.").font(.caption).foregroundStyle(.secondary)
            }
            OptionPill(icon: "thermometer.medium", title: String(format: "Temp %.1f", studio.settings.temperature),
                       help: "Ausdruck / Varianz", width: 260) {
                PopoverTitle("Ausdruck & Sampling")
                HStack { Text("Temperatur"); Spacer(); Text(String(format: "%.2f", studio.settings.temperature)).monospacedDigit() }
                Slider(value: $studio.settings.temperature, in: 0.2...1.4, step: 0.05).controlSize(.small)
                HStack { Text("Top-P"); Spacer(); Text(String(format: "%.2f", studio.settings.topP)).monospacedDigit() }
                Slider(value: $studio.settings.topP, in: 0.5...1.0, step: 0.05).controlSize(.small)
                Text("Für ruhige Telefon-Stimmen: 0,7–0,85. Standard Drama 3: 1,0.").font(.caption).foregroundStyle(.secondary)
            }
            OptionPill(icon: studio.settings.seedLocked ? "lock.fill" : "dice",
                       title: studio.settings.seedLocked ? "Seed \(studio.settings.seed)" : "Seed zufällig",
                       help: "Stimm-Seed", highlighted: studio.settings.seedLocked, width: 260) {
                SeedEditor(seed: $studio.settings.seed, locked: $studio.settings.seedLocked,
                           note: "Ohne Referenzstimme wählt der Seed eine konstante Stimme pro Durchlauf.")
            }
            OptionPill(icon: "slider.horizontal.3", title: "Mehr", help: "Erweiterte Optionen", width: 250) {
                PopoverTitle("Erweitert")
                HStack { Text("Max Tokens"); Spacer(); TextField("", value: $studio.settings.maxTokens, format: .number).textFieldStyle(.roundedBorder).frame(width: 80) }
                HStack { Text("Chunk-Größe"); Spacer(); TextField("", value: $studio.settings.textChunkSize, format: .number).textFieldStyle(.roundedBorder).frame(width: 80) }
                HStack { Text("Top-K"); Spacer(); TextField("", value: $studio.settings.topK, format: .number).textFieldStyle(.roundedBorder).frame(width: 80) }
            }
        }
    }
}

private struct SpeechFeed: View {
    @ObservedObject var studio: SpeechStudio

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Aufnahmen").font(.callout.weight(.semibold))
                Spacer()
                Text("\(studio.clips.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if studio.clips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.tertiary)
                    Text("Noch keine Sprachaufnahmen").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(studio.clips) { clip in
                            let isSel = studio.selected?.url == clip.url
                            let isPlay = studio.playingURL == clip.url && studio.isPlayingClip
                            HStack(spacing: 8) {
                                Button { studio.togglePlay(clip) } label: {
                                    Image(systemName: isPlay ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 22)).foregroundStyle(Color.accentColor)
                                }.buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(clip.title).font(.caption.weight(.medium)).lineLimit(2)
                                    HStack(spacing: 6) {
                                        if let d = clip.duration { Text(String(format: "%.1f s", d)) }
                                        if let ttfa = clip.ttfaMs { Text(String(format: "· %.0f ms", ttfa)) }
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(isSel ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture { studio.selected = clip }
                            .contextMenu {
                                Button("Übernehmen") { studio.useSettings(clip) }
                                Button("Im Finder zeigen") { studio.reveal(clip) }
                                Divider()
                                Button("In den Papierkorb", role: .destructive) { studio.trash(clip) }
                            }
                        }
                    }.padding(10)
                }
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
