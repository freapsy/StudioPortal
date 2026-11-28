import AVFoundation
import SwiftUI

struct PhoneDictation: View {
    @Binding var text: String
    @State private var recorder: AVAudioRecorder?
    @State private var starting = false
    @State private var recognizing = false
    @State private var failure: String?

    var body: some View {
        Button {
            if recorder != nil { stop() }
            else { Task { await start() } }
        } label: {
            Image(systemName: recognizing ? "waveform" : recorder != nil ? "stop.circle.fill" : "mic")
                .foregroundStyle(recorder == nil ? Color.secondary : Color.red)
        }
        .accessibilityLabel(recognizing ? "Whisper erkennt" : recorder != nil ? "Diktat beenden" : "Diktat auf dem Mac mini erkennen")
        .disabled(starting || recognizing)
        .alert("Diktat", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
        .onDisappear {
            if let recorder {
                recorder.stop()
                try? FileManager.default.removeItem(at: recorder.url)
                self.recorder = nil
                try? AVAudioSession.sharedInstance().setActive(false)
            }
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            failure = "Erlaube StudioPortal den Mikrofonzugriff in den Einstellungen."
            return
        }
        let url = URL.temporaryDirectory.appending(path: "diktat-\(UUID()).wav")
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true)
            let audio = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
            ])
            guard audio.record(forDuration: 120) else { throw API.Failure(errorDescription: "Aufnahme konnte nicht starten.") }
            recorder = audio
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? AVAudioSession.sharedInstance().setActive(false)
            failure = error.localizedDescription
        }
    }

    private func stop() {
        guard let audio = recorder else { return }
        audio.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        recognizing = true
        Task {
            defer {
                try? FileManager.default.removeItem(at: audio.url)
                recognizing = false
            }
            do {
                let request = API.request("/api/dictation", method: "POST", body: try Data(contentsOf: audio.url), type: "audio/wav")
                let response = try await API.data(request)
                guard let result = try JSONSerialization.jsonObject(with: response) as? [String: String],
                      let spoken = result["text"], !spoken.isEmpty else { return }
                text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + spoken
            } catch { failure = error.localizedDescription }
        }
    }
}
