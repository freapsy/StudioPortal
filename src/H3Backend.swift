import Foundation
import AppKit
import CryptoKit

// All bigki work goes through the restricted StudioPortal worker (one key, forced command, Tailscale address).
let remoteHost = "bigki@GPU-SERVER-IP"
private let sshDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
let portalKey = sshDirectory.appendingPathComponent("3d-modelle-bigki")
let portalKnownHosts = sshDirectory.appendingPathComponent("3d-modelle-bigki-known_hosts")

/// Shown in the bigki queue: which Mac and whether the app or an agent started a job.
let machineName: String = {
    let name = Host.current().localizedName ?? "Mac"
    let lower = name.lowercased()
    if lower.contains("mini") { return "Mac mini" }
    if lower.contains("macbook") { return "MacBook" }
    return String(name.prefix(24))
}()
var requestOrigin = "\(machineName) · App"

var portalAccessConfigured: Bool {
    FileManager.default.fileExists(atPath: portalKey.path) && FileManager.default.fileExists(atPath: portalKnownHosts.path)
}

var portalSSHArguments: [String] {
    ["-T", "-i", portalKey.path, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
     "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(portalKnownHosts.path)",
     "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
     "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
     "-o", "ClearAllForwardings=yes", remoteHost, "studioportal"]
}

/// Cancelling closes the worker's stdin; the worker then stops its job on bigki. ssh is terminated as a fallback.
final class RunControl {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private(set) var cancelled = false

    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ value: Process, input handle: FileHandle) {
        lock.lock(); process = value; input = handle; let stop = cancelled; lock.unlock()
        if stop { closeInput(handle, process: value) }
    }
    func detach() { lock.lock(); process = nil; input = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let p = process; let handle = input; lock.unlock()
        if let p, let handle { closeInput(handle, process: p) }
    }
    private func closeInput(_ handle: FileHandle, process: Process) {
        // an explicit "abbrechen" stops renders that would otherwise keep running after a lost connection
        try? handle.write(contentsOf: Data("abbrechen\n".utf8))
        try? handle.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
    }
}

/// Sends one JSON request to the worker and hands every JSON event line to `onEvent`.
func runWorker(_ request: [String: Any], control: RunControl? = nil, timeout: TimeInterval? = nil, patient: Bool = false,
               onEvent: (([String: Any]) throws -> Void)) throws {
    var request = request
    if request["origin"] == nil { request["origin"] = requestOrigin }
    guard portalAccessConfigured else { throw StudioError.message("Die Verbindung zu bigki ist auf diesem Mac noch nicht eingerichtet.") }
    if control?.isCancelled() == true { throw StudioError.message("Abgebrochen.") }
    let process = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    // patient: long renders survive a Tailscale hang of up to ~6 min instead of 90 s
    process.arguments = patient ? portalSSHArguments.map { $0 == "ServerAliveCountMax=3" ? "ServerAliveCountMax=12" : $0 } : portalSSHArguments
    process.standardOutput = output; process.standardError = errors; process.standardInput = input
    try process.run()
    control?.attach(process, input: input.fileHandleForWriting)
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline) }
    var stderrText = ""
    let stderrDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        stderrText = String(decoding: data.suffix(1500), as: UTF8.self)
        stderrDone.signal()
    }
    var line = try JSONSerialization.data(withJSONObject: request); line.append(10)
    DispatchQueue.global().async { try? input.fileHandleForWriting.write(contentsOf: line) }

    var pending = Data(), failure: Error?
    while let chunk = try? output.fileHandleForReading.read(upToCount: 262_144), !chunk.isEmpty {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 10) {
            let raw = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard failure == nil, let event = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
            do { try onEvent(event) } catch { failure = error; control?.cancel(); if control == nil { process.terminate() } }
        }
    }
    process.waitUntilExit()
    deadline.cancel()
    try? input.fileHandleForWriting.close()
    control?.detach()
    stderrDone.wait()
    if let failure { throw failure }
    if control?.isCancelled() == true { throw StudioError.message("Abgebrochen.") }
    if process.terminationStatus == 255 {
        throw StudioError.message("bigki ist nicht erreichbar. Ist Tailscale verbunden? \(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

final class Backend {
    func generate(_ settings: Settings, control: RunControl, update: @escaping (LogParser) -> Void) throws -> [URL] {
        try requireStori()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: picturesDirectory, withIntermediateDirectories: true)
        let references = settings.mode == "Bearbeiten" ? settings.references : []
        let options = try settings.options(referenceCount: references.count)
        let start = Date()
        var parser = LogParser()
        parser.phase = references.isEmpty ? "Verbinden" : "Hochladen"; update(parser)

        var encoded: [String] = []
        for reference in references {
            guard let image = NSImage(contentsOf: reference.url), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
                throw StudioError.message("Das Referenzbild ‘\(reference.url.lastPathComponent)’ konnte nicht als PNG gelesen werden.")
            }
            guard png.count <= 25 * 1024 * 1024 else { throw StudioError.message("Das Referenzbild ‘\(reference.url.lastPathComponent)’ ist größer als 25 MB.") }
            encoded.append(png.base64EncodedString())
        }
        let request: [String: Any] = ["operation": "h3", "prompt": settings.workerPrompt, "args": options,
                                      "count": settings.count, "vaeTiling": settings.vaeTiling, "references": encoded]
        encoded.removeAll()

        let stage = studioRoot.appendingPathComponent(".studioportal-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }

        var received: [URL] = [], remoteError: String?, finished = false
        var handle: FileHandle?, current: URL?, expected = 0, bytes = 0, hasher = SHA256()
        try runWorker(request, control: control) { event in
            switch event["type"] as? String {
            case "run":
                let seeds = parser.seeds; parser = LogParser(); parser.seeds = seeds; parser.phase = "Verbinden"; update(parser)
            case "log":
                if let line = event["line"] as? String { parser.consume(line); update(parser) }
            case "waiting":
                parser.phase = "Warten"; parser.step = nil; parser.total = nil
                parser.waiting = event["message"] as? String; update(parser)
            case "status":
                parser.phase = "Herunterladen"; parser.step = nil; parser.total = nil; update(parser)
            case "begin":
                guard handle == nil, let name = event["name"] as? String, let size = event["size"] as? Int,
                      match(name, #"^studioportal-[A-Za-z0-9._-]+\.png$"#, 0) != nil, size > 8, size < 512 * 1024 * 1024 else {
                    throw StudioError.message("bigki hat ungültige Bilddaten gesendet.")
                }
                let url = stage.appendingPathComponent(name)
                guard fileManager.createFile(atPath: url.path, contents: nil) else { throw StudioError.message("Das Bild konnte nicht gespeichert werden.") }
                handle = try FileHandle(forWritingTo: url); current = url; expected = size; bytes = 0; hasher = SHA256()
            case "data":
                guard let handle, let text = event["data"] as? String, let data = Data(base64Encoded: text) else { throw StudioError.message("bigki hat ungültige Bilddaten gesendet.") }
                bytes += data.count
                guard bytes <= expected else { throw StudioError.message("Ein Bild ist größer als angekündigt.") }
                try handle.write(contentsOf: data); hasher.update(data: data)
            case "filedone":
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard let file = handle, let url = current, bytes == expected, digest == event["sha256"] as? String else {
                    throw StudioError.message("Das heruntergeladene Bild ist beschädigt oder seine Prüfsumme stimmt nicht.")
                }
                try file.close(); handle = nil; current = nil
                received.append(url)
            case "end":
                finished = true
            case "error":
                remoteError = event["message"] as? String ?? "bigki meldet einen Fehler."
            default: break
            }
        }
        try? handle?.close()
        if let remoteError { throw StudioError.message(parser.message ?? remoteError) }
        guard finished, received.count == settings.count else {
            throw StudioError.message("Die Verbindung zu bigki wurde unterbrochen, bevor alle Bilder übertragen waren.")
        }
        var prepared: [(URL, URL, URL, URL)] = []
        for (index, image) in received.enumerated() {
            guard let data = try? Data(contentsOf: image), NSImage(data: data) != nil else { throw StudioError.message("Ein übertragenes Bild ist beschädigt.") }
            let target = picturesDirectory.appendingPathComponent(image.lastPathComponent)
            let sidecar = image.deletingPathExtension().appendingPathExtension("json")
            let metadata = RunMetadata(settings: settings, date: start, durationSeconds: Date().timeIntervalSince(start),
                                       outputName: image.lastPathComponent, actualSeed: index < parser.seeds.count ? parser.seeds[index] : nil,
                                       origin: requestOrigin)
            try jsonEncoder().encode(metadata).write(to: sidecar, options: .withoutOverwriting)
            prepared.append((image, target, sidecar, target.deletingPathExtension().appendingPathExtension("json")))
        }
        var installed: [URL] = []
        for (image, target, sidecar, targetSidecar) in prepared {
            try requireStori()
            try fileManager.linkItem(at: image, to: target)
            do { try fileManager.linkItem(at: sidecar, to: targetSidecar) } catch { try? fileManager.removeItem(at: target); throw error }
            installed.append(target)
        }
        return installed
    }
}
