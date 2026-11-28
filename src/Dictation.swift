import AVFoundation
import CryptoKit
import SwiftUI

/// Lokales Diktat: Mikrofon → temporäre WAV (16 kHz mono) → whisper-cli mit Whisper Turbo DE → Text.
/// Audio und Erkennung bleiben auf diesem Mac; die WAV wird nach der Erkennung gelöscht.
@MainActor
final class Dictation: ObservableObject {
    enum State { case idle, recording, transcribing }
    @Published private(set) var state: State = .idle
    @Published private(set) var phase: String?
    @Published var error: String?
    private var recorder: AVAudioRecorder?
    private var file: URL?

    nonisolated static let model = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/StudioPortal/Modelle/whisper-turbo-de-q5_0.bin")
    // Apache-2.0, primeline/whisper-large-v3-turbo-german als ggml q5_0 (cstr)
    nonisolated static let modelURL = URL(string: "https://huggingface.co/cstr/whisper-large-v3-turbo-german-ggml/resolve/main/ggml-model-q5_0.bin")!
    nonisolated static let modelSHA256 = "15e92e3db0993c52fffa781513eec9253475331c1be808f8fb409285c9d9d030"
    nonisolated static var whisper: String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func toggle(insert: @escaping (String) -> Void) {
        switch state {
        case .idle: start()
        case .recording: finish(insert: insert)
        case .transcribing: break
        }
    }

    private func start() {
        error = nil
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Kein Mikrofonzugriff. Erlauben unter Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon."
                    return
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("diktat-\(UUID().uuidString).wav")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                do {
                    let recorder = try AVAudioRecorder(url: url, settings: settings)
                    guard recorder.record() else { throw StudioError.message("Aufnahme ließ sich nicht starten.") }
                    self.recorder = recorder; self.file = url; self.state = .recording
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func finish(insert: @escaping (String) -> Void) {
        recorder?.stop(); recorder = nil
        guard let file else { state = .idle; return }
        self.file = nil
        state = .transcribing; phase = "erkennt …"
        Task {
            do {
                if !FileManager.default.fileExists(atPath: Self.model.path) {
                    phase = "lädt Sprachmodell (574 MB, einmalig) …"
                    try await Self.downloadModel()
                    phase = "erkennt …"
                }
                let text = try await Task.detached(priority: .userInitiated) { try Self.transcribe(file) }.value
                if !text.isEmpty { insert(text) }
            } catch {
                self.error = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: file)
            state = .idle; phase = nil
        }
    }

    nonisolated static func transcribe(_ wav: URL) throws -> String {
        guard let whisper else { throw StudioError.message("whisper-cli fehlt. Einmalig installieren: brew install whisper-cpp") }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: whisper)
        process.arguments = ["-m", model.path, "-l", "de", "-nt", "-np", "-f", wav.path]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = String(decoding: failure, as: UTF8.self).split(separator: "\n").suffix(2).joined(separator: " ")
            throw StudioError.message("Spracherkennung fehlgeschlagen: \(tail)")
        }
        return cleaned(String(decoding: data, as: UTF8.self))
    }

    /// Whisper schreibt bei Stille Markierungen wie „[Musik]“ oder „(Stille)“ – die gehören nicht ins Eingabefeld.
    nonisolated static func cleaned(_ raw: String) -> String {
        raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) && !($0.hasPrefix("(") && $0.hasSuffix(")")) }
            .joined(separator: " ")
    }

    nonisolated static func downloadModel() async throws {
        let (temp, _) = try await URLSession.shared.download(from: modelURL)
        defer { try? FileManager.default.removeItem(at: temp) }
        let digest = try SHA256.hash(data: Data(contentsOf: temp, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == modelSHA256 else { throw StudioError.message("Sprachmodell unvollständig oder verändert (Prüfsumme passt nicht).") }
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? FileManager.default.removeItem(at: model)
        try FileManager.default.moveItem(at: temp, to: model)
    }
}

/// Mikrofonknopf neben einem Eingabefeld: einmal klicken = Aufnahme, nochmal = Text einfügen.
struct DictationButton: View {
    @Binding var text: String
    @StateObject private var dictation = Dictation()

    var body: some View {
        Button {
            dictation.toggle { spoken in
                text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + spoken
            }
        } label: {
            switch dictation.state {
            case .idle: Label("Diktat", systemImage: "mic")
            case .recording: Label("Aufnahme beenden", systemImage: "stop.circle.fill").foregroundStyle(.red)
            case .transcribing: Label(dictation.phase ?? "erkennt …", systemImage: "waveform")
            }
        }
        .labelStyle(.iconOnly)
        .disabled(dictation.state == .transcribing)
        .help(dictation.state == .recording ? "Aufnahme läuft – klicken zum Beenden"
              : "Diktat (lokal mit Whisper Turbo DE, nichts verlässt den Mac)")
        .alert("Diktat", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            Button("OK") { dictation.error = nil }
        } message: { Text(dictation.error ?? "") }
    }
}
