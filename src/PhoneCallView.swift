import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum PhoneEngineMode: String, CaseIterable {
    case livekit = "livekit"
    case classic = "classic"
}

struct PhoneCallView: View {
    @ObservedObject var studio: PhoneCallStudio
    @ObservedObject var livekit: LiveKitPhoneStudio
    @AppStorage("phoneEngineMode") private var modeRaw = PhoneEngineMode.livekit.rawValue
    private var mode: PhoneEngineMode { PhoneEngineMode(rawValue: modeRaw) ?? .livekit }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(
                title: "Telefon-Test",
                subtitle: mode == .livekit
                    ? "LiveKit Agents · WebRTC AEC, Silero VAD & Barge-In · umschaltbar Lokal (bigki) ↔ Hybrid ↔ Cloud"
                    : "Klassisch (Backup) · 2+1 Split auf bigki · Qwen 3.8 Flash · Drama 3 / Qwen3-TTS · Nemotron STT",
                icon: "phone.connection"
            ) {
                HStack(spacing: 10) {
                    Picker("", selection: $modeRaw) {
                        Text("LiveKit Agent").tag(PhoneEngineMode.livekit.rawValue)
                        Text("Klassisch (Backup)").tag(PhoneEngineMode.classic.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)

                    if mode == .livekit {
                        livekitControls
                    }
                    if mode == .classic || livekit.profile.needsBigki {
                        stackBadge
                        if studio.server.ready || studio.server.llmRunning || studio.server.ttsRunning {
                            Button("bigki stoppen") { studio.stopStack() }
                                .controlSize(.small)
                                .help("Gibt alle 3 MI50-Karten auf bigki sofort frei (sonst automatisch nach 15 min Pause)")
                        } else if studio.phase == .startingStack {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button("bigki 2+1 starten") { studio.startStack() }
                                .controlSize(.small)
                                .help("Startet Qwen (2× MI50), Drama 3 / Qwen3-TTS (1× MI50) und Nemotron STT + Smart Turn (CPU)")
                        }
                    }
                }
            }
            HStack(spacing: 0) {
                if mode == .livekit {
                    LiveKitCallStage(livekit: livekit, studio: studio)
                        .background(Color(nsColor: .underPageBackgroundColor))
                } else {
                    CallStage(studio: studio)
                        .background(Color(nsColor: .underPageBackgroundColor))
                }
                Divider()
                ScenarioSidebar(studio: studio, livekit: livekit, isLiveKit: mode == .livekit)
            }
        }
        .onAppear {
            studio.refreshServer()
            studio.refreshSavedCalls()
            livekit.syncConfig(from: studio)
            if mode == .livekit {
                livekit.ensureStarted(phone: studio)
            }
        }
        .onChange(of: modeRaw) {
            if mode == .livekit {
                livekit.ensureStarted(phone: studio)
            }
        }
        .onChange(of: studio.scenario) { livekit.syncConfig(from: studio) }
        .onChange(of: studio.voicePreset) { livekit.syncConfig(from: studio) }
        .onChange(of: studio.ttsEngine) { livekit.syncConfig(from: studio) }
        .onChange(of: studio.ttsTemperature) { livekit.syncConfig(from: studio) }
        .onChange(of: livekit.profile) { livekit.syncConfig(from: studio) }
        .onChange(of: livekit.elevenlabsVoiceId) { livekit.syncConfig(from: studio) }
        .onChange(of: livekit.elevenlabsModel) { livekit.syncConfig(from: studio) }
        .onChange(of: livekit.openaiModel) { livekit.syncConfig(from: studio) }
        .onChange(of: livekit.openaiVoice) { livekit.syncConfig(from: studio) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            livekit.stop()
        }
        .alert("Telefon-Test", isPresented: Binding(get: { studio.errorMessage != nil || livekit.errorMessage != nil }, set: {
            if !$0 { studio.errorMessage = nil; livekit.errorMessage = nil }
        })) {
            Button("OK", role: .cancel) { studio.errorMessage = nil; livekit.errorMessage = nil }
        } message: { Text(livekit.errorMessage ?? studio.errorMessage ?? "") }
    }

    private var livekitControls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(livekit.running ? Color.green : livekit.starting ? Color.orange : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(livekit.running ? "LiveKit aktiv" : livekit.starting ? "Startet …" : "Aus")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((livekit.running ? Color.green : Color.secondary).opacity(0.12), in: Capsule())

            if livekit.running {
                Button { livekit.openInBrowser() } label: {
                    Image(systemName: "safari")
                }.controlSize(.small).help("Telefon-UI im Browser öffnen (http://127.0.0.1:7891)")
                Button { livekit.restartAgent(phone: studio) } label: {
                    Image(systemName: "arrow.clockwise")
                }.controlSize(.small).help("LiveKit-Agent neu starten")
            } else if !livekit.starting {
                Button("LiveKit starten") { livekit.ensureStarted(phone: studio) }
                    .controlSize(.small)
            }
        }
    }

    private var stackBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(studio.server.ready ? Color.green : studio.phase == .startingStack ? Color.orange : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(studio.server.ready ? "2+1 Bereit" : studio.phase == .startingStack ? "Startet …" : "bigki Aus")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background((studio.server.ready ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
    }
}

private struct LiveKitCallStage: View {
    @ObservedObject var livekit: LiveKitPhoneStudio
    @ObservedObject var studio: PhoneCallStudio

    var body: some View {
        VStack(spacing: 0) {
            let bigkiReadyForProfile = (livekit.profile == .hybrid)
                ? (studio.server.llmRunning && studio.server.cpuAudioRunning)
                : studio.server.ready
            if livekit.profile.needsBigki && !bigkiReadyForProfile {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Profil „\(livekit.profile.title)“ nutzt bigki – starte oben zuerst den 2+1 Stack (~55 s).")
                        .font(.caption)
                    Spacer()
                    Button("bigki 2+1 starten") { studio.startStack() }
                        .controlSize(.small)
                        .disabled(studio.phase == .startingStack)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
            if livekit.running {
                LiveKitWebView(url: livekit.bridgeURL, reloadNonce: livekit.reloadNonce)
            } else {
                VStack(spacing: 14) {
                    if livekit.starting {
                        ProgressView().controlSize(.large)
                        Text(livekit.statusText).font(.headline)
                    } else {
                        Image(systemName: "waveform.badge.mic").font(.system(size: 38)).foregroundStyle(.secondary)
                        Text(livekit.statusText).font(.headline)
                        Button("LiveKit Agent starten") { livekit.ensureStarted(phone: studio) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct CallStage: View {
    @ObservedObject var studio: PhoneCallStudio

    private var phaseColor: Color {
        switch studio.phase {
        case .idle: return .secondary
        case .startingStack, .checkingTurn, .thinking: return .orange
        case .listening: return .green
        case .speaking: return .blue
        case .ducked: return .purple
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Live Call Control Hero
            Card {
                HStack(spacing: 16) {
                    Button {
                        if studio.callActive { studio.endCall(save: true) }
                        else { studio.beginCall() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: studio.callActive ? "phone.down.fill" : "phone.fill")
                            Text(studio.callActive ? "Auflegen" : "Anruf simulieren")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(studio.callActive ? Color.red : Color.green, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(studio.phase == .startingStack)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(phaseColor).frame(width: 8, height: 8)
                            Text(studio.phase.rawValue).font(.headline)
                            if studio.callActive && studio.aecEnabled {
                                MetaChip(text: "AEC aktiv", icon: "ear.and.waveform", tint: .green)
                            }
                            MetaChip(text: studio.ttsEngine == "drama-3" ? "Drama 3" : "Qwen3-TTS", icon: "waveform", tint: .accentColor)
                        }
                        Text(studio.statusMessage.isEmpty ? "Ziel: \(studio.scenario.targetCompany) · du spielst die Rezeption / den Chef, die KI ruft als \(studio.scenario.callerName) an." : studio.statusMessage)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)

                    if studio.callActive {
                        // Live mic level meter
                        VStack(spacing: 4) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    Capsule().fill(studio.muted ? Color.secondary : Color.green)
                                        .frame(width: max(4, geo.size.width * CGFloat(studio.micLevel)))
                                }
                            }
                            .frame(width: 72, height: 6)
                            HStack(spacing: 6) {
                                Button { studio.muted.toggle() } label: {
                                    Image(systemName: studio.muted ? "mic.slash.fill" : "mic.fill")
                                        .foregroundStyle(studio.muted ? Color.red : Color.primary)
                                }.controlSize(.small).help(studio.muted ? "Mikrofon einschalten" : "Mikrofon stumm")
                                Button("KI beginnt") { studio.aiSpeakFirst() }
                                    .controlSize(.small)
                                    .disabled(studio.phase == .thinking || studio.phase == .speaking)
                                    .help("Lässt die KI sofort mit der Begrüßung starten")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            // Live Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if studio.messages.isEmpty {
                            StartView(icon: "phone.badge.waveform", title: "Akquise-Anruf simulieren", steps: [
                                "Rechts Betrieb & gefundenen Website-Fehler eintragen (oder eine Vorlage wählen).",
                                "Auf „Anruf simulieren“ klicken – bigki fährt den 2+1-GPU-Split hoch (Qwen auf 2× MI50, Stimme auf 1× MI50, STT + Smart Turn auf CPU).",
                                "Du spielst den angerufenen Betrieb (z. B. „Hotel Alpenblick, Weber am Apparat!“) – du kannst der KI jederzeit ganz natürlich ins Wort fallen.",
                            ]) {}
                            .padding(.top, 16)
                        } else {
                            ForEach(studio.messages) { msg in
                                CallBubble(message: msg, callerName: studio.scenario.callerName, targetName: studio.scenario.targetCompany)
                                    .id(msg.id)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                .onChange(of: studio.messages.count) {
                    if let last = studio.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            // Quick text input for testing objections without talking aloud
            HStack(spacing: 8) {
                TextField("Oder Einwand tippen (z. B. „Keine Zeit, schicken Sie eine Mail!“) …", text: $studio.draftText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { studio.sendTypedUtterance() }
                Button("Senden") { studio.sendTypedUtterance() }
                    .disabled(studio.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct CallBubble: View {
    var message: CallMessage
    var callerName: String
    var targetName: String
    private var isAI: Bool { message.role == "assistant" }

    var body: some View {
        HStack {
            if !isAI { Spacer(minLength: 60) }
            VStack(alignment: isAI ? .leading : .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isAI ? "\(callerName) (KI)" : "\(targetName) (Du)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isAI ? Color.accentColor : Color.secondary)
                    if message.interrupted {
                        Text("unterbrochen").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
                    }
                }
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(isAI ? Color(nsColor: .controlBackgroundColor) : Color.accentColor.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                HStack(spacing: 8) {
                    if let t = message.turnMs { Text(String(format: "Turn %.0f ms", t)) }
                    if let s = message.sttMs, s > 0 { Text(String(format: "STT %.0f ms", s)) }
                    if let l = message.llmMs { Text(String(format: "LLM %.0f ms", l)) }
                    if let tts = message.ttsMs { Text(String(format: "TTS %.0f ms", tts)) }
                    if let fa = message.firstAudioMs { Text(String(format: "1. Audio %.0f ms", fa)).fontWeight(.medium) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if isAI { Spacer(minLength: 60) }
        }
    }
}

private struct ScenarioSidebar: View {
    @ObservedObject var studio: PhoneCallStudio
    @ObservedObject var livekit: LiveKitPhoneStudio
    var isLiveKit: Bool
    @State private var showKeys = false

    private func pickVoiceRef() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Referenzstimme (5–25 s) für Drama-3 Voice Cloning wählen"
        if panel.runModal() == .OK, let url = panel.url {
            studio.voiceRefPath = url.path
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLiveKit {
                    VStack(alignment: .leading, spacing: 6) {
                        PopoverTitle("LiveKit-Profil (Lokal ↔ Cloud)")
                        ForEach(LiveKitProfile.allCases) { prof in
                            Button { livekit.profile = prof } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(prof.title).font(.caption.weight(.semibold)).lineLimit(1)
                                        Spacer()
                                        if livekit.profile == prof {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    Text(prof.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(livekit.profile == prof ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                    }

                    DisclosureGroup(isExpanded: $showKeys) {
                        VStack(alignment: .leading, spacing: 8) {
                            keyField("ElevenLabs API-Key", text: $livekit.elevenlabsApiKey)
                            Divider()
                            keyField("OpenAI API-Key", text: $livekit.openaiApiKey)
                            field("OpenAI Pipeline-Modell", text: $livekit.openaiModel)
                            Divider()
                            keyField("Deepgram API-Key (optional)", text: $livekit.deepgramApiKey)
                            Button("Schlüssel lokal sichern") {
                                livekit.saveKeys()
                                livekit.syncConfig(from: studio)
                                livekit.fetchElevenLabsVoices()
                            }
                            .controlSize(.small)
                            Text("Wird nur lokal (chmod 600) gespeichert, nie hochgeladen.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill").font(.caption)
                            Text("Cloud-API-Schlüssel").font(.caption.weight(.semibold))
                            Spacer()
                            if !livekit.elevenlabsApiKey.isEmpty {
                                Text("11L").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                            }
                            if !livekit.openaiApiKey.isEmpty {
                                Text("OAI").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                            }
                        }
                    }

                    Divider()
                }

                VStack(alignment: .leading, spacing: 6) {
                    PopoverTitle("Akquise-Vorlage")
                    ForEach(CallScenario.presets) { preset in
                        Button {
                            var next = preset
                            if !isLiveKit || livekit.profile == .local {
                                next.callerName = studio.voicePreset.defaultName
                            } else if !studio.scenario.callerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                next.callerName = studio.scenario.callerName
                            }
                            studio.scenario = next
                        } label: {
                            HStack {
                                Text(preset.title).font(.caption.weight(.medium)).lineLimit(1)
                                Spacer()
                                if studio.scenario.id == preset.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(studio.scenario.id == preset.id ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    PopoverTitle("Gesprächs-Briefing")
                    field("Zielbetrieb", text: $studio.scenario.targetCompany)
                    field("Dein Name", text: $studio.scenario.callerName)
                    field("Deine Agentur", text: $studio.scenario.agencyName)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gefundener Website-Fehler").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $studio.scenario.websiteIssue)
                            .font(.caption).frame(height: 68)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ziel des Anrufs").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $studio.scenario.goal)
                            .font(.caption).frame(height: 48)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    }
                    Toggle("Höfliche Anrede („Sie“)", isOn: $studio.scenario.formalSie).font(.caption)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if isLiveKit && livekit.profile.needsElevenLabs {
                        HStack {
                            PopoverTitle("Stimme (ElevenLabs)")
                            Spacer()
                            if livekit.loadingVoices {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button { livekit.fetchElevenLabsVoices() } label: {
                                    Image(systemName: "arrow.clockwise").font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Stimmen aus deinem ElevenLabs-Konto neu laden")
                                .disabled(livekit.elevenlabsApiKey.isEmpty)
                            }
                        }
                        if livekit.elevenlabsApiKey.isEmpty {
                            Text("Bitte oben unter „Cloud-API-Schlüssel“ deinen ElevenLabs API-Key eintragen.")
                                .font(.caption2).foregroundStyle(.orange)
                        } else {
                            let curVoice = livekit.elevenlabsVoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
                            let hasMatch = livekit.elevenlabsVoices.contains { $0.id == curVoice }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("ElevenLabs-Stimme (\(livekit.elevenlabsVoices.count) im Konto)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Picker("", selection: $livekit.elevenlabsVoiceId) {
                                    if !hasMatch && !curVoice.isEmpty {
                                        Text("Benutzerdefiniert (\(curVoice))").tag(curVoice)
                                    }
                                    ForEach(livekit.elevenlabsVoices) { v in
                                        Text(v.label).tag(v.id)
                                    }
                                }.labelsHidden().controlSize(.small)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("ElevenLabs-Modell").font(.caption).foregroundStyle(.secondary)
                                Picker("", selection: $livekit.elevenlabsModel) {
                                    Text("Eleven v4 Turbo (Beste + Echtzeit)").tag("eleven_v4_turbo")
                                    Text("Eleven v4 (Höchste Qualität)").tag("eleven_v4")
                                    Text("Eleven v3 Conversational").tag("eleven_v3_conversational")
                                    Text("Eleven v3").tag("eleven_v3")
                                    Text("Flash v2.5 (~75 ms)").tag("eleven_flash_v2_5")
                                    Text("Turbo v2.5").tag("eleven_turbo_v2_5")
                                    Text("Multilingual v2").tag("eleven_multilingual_v2")
                                }.labelsHidden().controlSize(.small)
                            }
                            field("Voice-ID oder Name (optional direkt)", text: $livekit.elevenlabsVoiceId)
                            if let err = livekit.voicesError {
                                Text(err).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    } else if isLiveKit && livekit.profile == .cloudRealtime {
                        PopoverTitle("Stimme (OpenAI Realtime)")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Realtime-Stimme").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $livekit.openaiVoice) {
                                Text("Marin").tag("marin")
                                Text("Cedar").tag("cedar")
                                Text("Ash").tag("ash")
                                Text("Shimmer").tag("shimmer")
                            }.labelsHidden().controlSize(.small)
                        }
                        Text("Native Speech-to-Speech Stimme direkt über OpenAI Realtime.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        PopoverTitle("Stimme & Geschwindigkeit (Lokal · bigki)")
                        Picker("", selection: $studio.ttsEngine) {
                            Text("Drama 3").tag("drama-3")
                            Text("Qwen3-TTS").tag("qwen3-tts")
                        }.pickerStyle(.segmented).labelsHidden()
                        if studio.ttsEngine == "drama-3" {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Vertriebsstimme").font(.caption).foregroundStyle(.secondary)
                                Picker("", selection: $studio.voicePreset) {
                                    ForEach(DramaVoicePreset.allCases) { p in
                                        Text(p.label).tag(p)
                                    }
                                }.labelsHidden().controlSize(.small)
                            }
                            HStack {
                                Text("Temp").font(.caption).foregroundStyle(.secondary)
                                Slider(value: $studio.ttsTemperature, in: 0.5...1.1, step: 0.05).controlSize(.small)
                                Text(String(format: "%.2f", studio.ttsTemperature)).font(.caption).monospacedDigit()
                            }
                            HStack {
                                Button(studio.voiceRefPath == nil ? "Eigene Stimme klonen …" : URL(fileURLWithPath: studio.voiceRefPath!).lastPathComponent) {
                                    pickVoiceRef()
                                }.controlSize(.small)
                                if studio.voiceRefPath != nil {
                                    Button { studio.voiceRefPath = nil; studio.referenceText = "" } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }.buttonStyle(.borderless)
                                }
                            }
                            if studio.voiceRefPath != nil {
                                TextField("Referenz-Text (optional)", text: $studio.referenceText).textFieldStyle(.roundedBorder).controlSize(.small)
                            }
                        } else {
                            field("Sprecher", text: $studio.qwenSpeaker)
                            field("Stil-Hinweis", text: $studio.qwenInstruct)
                        }
                    }
                }

                if !studio.savedCalls.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        PopoverTitle("Aufgezeichnete Testanrufe")
                        ForEach(studio.savedCalls.prefix(8)) { call in
                            HStack(spacing: 6) {
                                if call.audioURL != nil {
                                    Button { studio.playSavedCall(call) } label: {
                                        Image(systemName: "play.circle.fill").foregroundStyle(Color.accentColor)
                                    }.buttonStyle(.plain)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(call.title).font(.caption.weight(.medium)).lineLimit(1)
                                    Text("\(call.messageCount) Züge · \(call.date.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { studio.revealSavedCall(call) } label: {
                                    Image(systemName: "folder").font(.caption)
                                }.buttonStyle(.borderless)
                            }
                            .padding(6)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 295)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder).controlSize(.small)
        }
    }

    private func keyField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SecureField("sk-…", text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { livekit.saveKeys() }
        }
    }
}
