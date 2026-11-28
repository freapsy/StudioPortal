import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class DownloadManager: ObservableObject {
    @Published var link = ""
    @Published var working = false
    @Published var status = "Bereit."
    @Published var detail = ""
    @Published var result: URL?
    @Published var isGeneration = false
    var onFinish: (() -> Void)?
    private var process: Process?
    private var receivedResult = false

    private func blenderExecutable() -> URL? { blenderApplication()?.appendingPathComponent("Contents/MacOS/Blender") }

    func start() {
        guard !working else { return }
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "Bitte einen Modell-Link einfügen."
            return
        }
        begin(text)
    }

    func chooseFile() {
        guard !working else { return }
        let panel = NSOpenPanel()
        panel.title = "3D-Datei oder Modellordner auswählen"
        panel.message = "Unterstützt werden unter anderem BLEND, GLB, OBJ, FBX, STL, 3MF und ZIP."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { begin(url.absoluteString) }
    }

    func startImages(_ images: [String: URL], model: String, resolution: Int, color: Bool, person: Bool) {
        guard !working else { return }
        guard !images.isEmpty, !color || images.count == 4 else {
            status = color ? "Für die Farben bitte alle vier Bilder auswählen." : "Bitte mindestens ein Bild auswählen."
            return
        }
        let options: [String: Any] = ["images": images.mapValues { $0.path }, "model": model,
                                      "resolution": resolution, "color": color, "person": person]
        guard let input = try? JSONSerialization.data(withJSONObject: options),
              let paths = paths() else { return }
        launch(resources: paths.resources,
               arguments: [paths.resources.appendingPathComponent("from_images.mjs").path,
                           paths.destination.path, paths.blender.path],
               input: input, generation: true)
    }

    private func paths() -> (resources: URL, destination: URL, blender: URL)? {
        guard let resources = Bundle.main.resourceURL,
              let blender = blenderExecutable() else {
            status = "Blender wurde nicht gefunden."
            detail = "Bitte Blender in den Programme-Ordner legen."
            return nil
        }
        return (resources, modelsDirectory, blender)
    }

    private func begin(_ text: String) {
        guard let paths = paths() else { return }
        launch(resources: paths.resources,
               arguments: [paths.resources.appendingPathComponent("download.mjs").path, text,
                           paths.destination.path, paths.blender.path],
               input: nil, generation: false)
    }

    private func launch(resources: URL, arguments: [String], input: Data?, generation: Bool) {
        let p = Process()
        p.executableURL = resources.appendingPathComponent("node")
        p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                         "HOME": generation ? FileManager.default.homeDirectoryForCurrentUser.path : NSTemporaryDirectory(),
                         "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "STUDIOPORTAL_ORIGIN": requestOrigin]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let inputPipe = Pipe()
        if input != nil { p.standardInput = inputPipe }
        receivedResult = false
        result = nil
        detail = ""
        isGeneration = generation
        status = generation ? "Erstellung wird vorbereitet …" : "Download wird vorbereitet …"
        do {
            try p.run()
            if let input {
                inputPipe.fileHandleForWriting.write(input)
                try? inputPipe.fileHandleForWriting.close()
            }
        } catch {
            status = "Das Programm konnte nicht gestartet werden."
            detail = error.localizedDescription
            return
        }
        process = p
        working = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pending = Data()
            var diagnostics = ""
            let reader = pipe.fileHandleForReading
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let range = pending.range(of: Data([10])) {
                    let line = Data(pending[..<range.lowerBound])
                    pending.removeSubrange(...range.lowerBound)
                    if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       let type = value["type"] as? String {
                        let message = value["message"] as? String ?? ""
                        let path = value["path"] as? String ?? ""
                        DispatchQueue.main.async { [weak self] in self?.receive(type: type, message: message, path: path) }
                    } else if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                        diagnostics = String((diagnostics + "\n" + text).suffix(1000))
                    }
                }
            }
            p.waitUntilExit()
            let code = p.terminationStatus
            let lastDiagnostics = diagnostics
            DispatchQueue.main.async { [weak self] in self?.finished(code: code, diagnostics: lastDiagnostics) }
        }
    }

    private func receive(type: String, message: String, path: String) {
        switch type {
        case "status":
            if !message.isEmpty { status = message }
        case "done":
            receivedResult = true
            result = URL(fileURLWithPath: path)
            status = "Fertig! Deine Blender-Datei wurde gespeichert."
            Notifier.finished(isGeneration ? "3D-Modell fertig" : "Import fertig", URL(fileURLWithPath: path).lastPathComponent)
            onFinish?()
        case "cancelled":
            receivedResult = true
            status = isGeneration ? "Erstellung abgebrochen." : "Download abgebrochen."
        case "error":
            receivedResult = true
            status = isGeneration ? "Erstellung fehlgeschlagen." : "Download fehlgeschlagen."
            detail = message
        case "notice":
            detail = message
        default: break
        }
    }

    private func finished(code: Int32, diagnostics: String) {
        working = false
        process = nil
        if !receivedResult && code != 0 {
            status = isGeneration ? "Erstellung fehlgeschlagen." : "Download fehlgeschlagen."
            detail = diagnostics.isEmpty ? "Bitte Verbindung und Eingaben prüfen." : diagnostics
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        status = "Wird abgebrochen …"
        process.terminate()
    }

    func reveal() {
        if let result { NSWorkspace.shared.activateFileViewerSelecting([result]) }
    }

    func openPage() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.contains("://") ? text : "https://" + text
        if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }
}


func blenderApplication() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [home.appendingPathComponent("Applications/Blender.app"), URL(fileURLWithPath: "/Applications/Blender.app")]
        .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/Blender").path) }
}

/// Big files go where the studio root is: on Stori (Mac mini) next to the pictures, otherwise in the home folders.
let studioOnStori = studioRoot.path.hasPrefix("/Volumes/stori/")
let legacyModelsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/3D-Modelle", isDirectory: true)
let legacyVideosDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/StudioPortal", isDirectory: true)
let modelsDirectory: URL = studioOnStori ? studioRoot.appendingPathComponent("3D-Modelle", isDirectory: true) : legacyModelsDirectory

/// One-time move of models/videos from the internal SSD to Stori (only when Stori is the studio root and mounted).
/// Moves item by item and never overwrites; anything already present at the target stays in the old folder.
func moveLegacyFoldersToStori() {
    guard studioOnStori, (try? requireStori()) != nil else { return }
    let fm = FileManager.default
    for (old, new) in [(legacyModelsDirectory, modelsDirectory), (legacyVideosDirectory, videosDirectory)] where old.path != new.path {
        guard let items = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil), !items.isEmpty else { continue }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for item in items where !fm.fileExists(atPath: new.appendingPathComponent(item.lastPathComponent).path) {
            try? fm.moveItem(at: item, to: new.appendingPathComponent(item.lastPathComponent))
        }
        if (try? fm.contentsOfDirectory(atPath: old.path).filter { $0 != ".DS_Store" }.isEmpty) == true { try? fm.removeItem(at: old) }
    }
}
