import Foundation
import AppKit
import CryptoKit

// bigki over Tailscale, so it works at home and away. Each Mac has its own key, created on first start.
let remoteHost = "bigki@GPU-SERVER-IP"
private let sshDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
let sshKey = sshDirectory.appendingPathComponent("h3studio_bigki")
private let knownHosts = sshDirectory.appendingPathComponent("h3studio_known_hosts")
private let bigkiHostKey = "GPU-SERVER-IP GPU-SERVER-HOSTKEY\n"
private let sshOptions = ["-i", sshKey.path, "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=20", "-o", "BatchMode=yes"]

/// Creates this Mac's key and the pinned bigki host key if missing; returns the public key to authorize on bigki.
@discardableResult
func ensureKey() throws -> String {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data(bigkiHostKey.utf8).write(to: knownHosts, options: .atomic)
    if !fileManager.fileExists(atPath: sshKey.path) {
        try execute("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "h3studio \(Host.current().localizedName ?? "Mac")", "-f", sshKey.path], timeout: 20)
    }
    return try String(contentsOf: sshKey.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ProcessFailure: Error { var code: Int32; var output: String }

final class RunControl {
    private let lock = NSLock()
    private var process: Process?
    private var generation = false
    private var pid: Int32?
    private var name = ""
    private(set) var cancelled = false

    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func setName(_ value: String) { lock.lock(); name = value; lock.unlock() }
    func attach(_ value: Process, generation: Bool) {
        lock.lock(); process = value; self.generation = generation; let stop = cancelled; lock.unlock()
        if stop && value.isRunning { value.terminate() }
    }
    func detach(_ value: Process) { lock.lock(); if process === value { process = nil }; lock.unlock() }
    func setPID(_ value: Int32) {
        lock.lock(); pid = value; let stop = cancelled; let runName = name; lock.unlock()
        if stop { terminateRemote(pid: value, name: runName) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let p = process; let gen = generation; let id = pid; let runName = name; lock.unlock()
        if gen, let id { terminateRemote(pid: id, name: runName) }
        else if let p, p.isRunning { p.terminate() }
    }
    private func terminateRemote(pid: Int32, name: String) {
        guard pid > 1, !name.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let command = "p=\(pid); test -r /proc/$p/cmdline && tr '\\0' '\\n' </proc/$p/cmdline | grep -Fxq \"$HOME/h3-image/h3-image.sh\" && tr '\\0' '\\n' </proc/$p/cmdline | grep -Fxq \(shellQuote(name)) && kill -TERM $p"
            _ = try? execute("/usr/bin/ssh", sshOptions + [remoteHost, command], timeout: 12)
        }
    }
}

@discardableResult
func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil, control: RunControl? = nil, generation: Bool = false, onChunk: ((String) -> Void)? = nil) throws -> String {
    if control?.isCancelled() == true { throw StudioError.message("Abgebrochen.") }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    try process.run()
    pipe.fileHandleForWriting.closeFile()
    control?.attach(process, generation: generation)
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline) }
    var output = ""
    while let data = try pipe.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
        let chunk = String(decoding: data, as: UTF8.self)
        output += chunk
        onChunk?(chunk)
    }
    process.waitUntilExit()
    deadline.cancel()
    control?.detach(process)
    if control?.isCancelled() == true { throw StudioError.message("Abgebrochen.") }
    guard process.terminationStatus == 0 else { throw ProcessFailure(code: process.terminationStatus, output: output) }
    return output
}

func remoteCommand(name: String, arguments: [String], vaeTiling: Bool) -> String {
    let script = #"""
    name=$1; tiling=$2; shift 2
    args=()
    while [ "$#" -gt 0 ]; do
      value="$(printf '%s' "$1" | base64 -d; printf x)" || exit 2
      args+=("${value%x}"); shift
    done
    log="$HOME/h3-image/out/$name.log"
    env -u ROCR_VISIBLE_DEVICES H3_VAE_TILING="$tiling" "$HOME/h3-image/h3-image.sh" "$name" "${args[@]}" &
    job=$!
    printf 'H3STUDIO_PID=%s\n' "$job"
    follower=
    cleanup() { trap - HUP INT TERM EXIT; kill -TERM "$job" 2>/dev/null || :; wait "$job" 2>/dev/null || :; [ -z "$follower" ] || kill "$follower" 2>/dev/null || :; }
    trap 'cleanup; exit 143' HUP INT TERM
    while [ ! -f "$log" ] && kill -0 "$job" 2>/dev/null; do sleep 0.2; done
    if [ -f "$log" ]; then tail -n +1 -f --pid="$job" "$log" & follower=$!; fi
    wait "$job"; result=$?
    [ -z "$follower" ] || wait "$follower" 2>/dev/null || :
    trap - HUP INT TERM
    exit "$result"
    """#
    return (["bash", "-c", script, "_", name, vaeTiling ? "1" : "0"] + encodedArguments(arguments)).map(shellQuote).joined(separator: " ")
}

struct MachineStatus {
    var reachable = false
    var occupation = "unbekannt"
    var temperatures: [Int] = []
}

final class Backend {
    func status() -> MachineStatus {
        let script = #"""
        if pgrep -x blender >/dev/null 2>&1; then echo BLENDER=yes; else echo BLENDER=no; fi
        if flock -n /home/bigki/mi50-phase0/mi50-experiment.lock -c 'true'; then echo LOCK=free; else echo LOCK=busy; fi
        pids=$(timeout 3 rocm-smi --showpids 2>/dev/null) || pids=unknown
        if [[ $pids == *'No KFD PIDs currently running'* ]]; then echo PIDS=free; else echo PIDS=busy; fi
        for card in /sys/class/drm/card[0-9]*; do
          [[ -r $card/device/gpu_busy_percent && $(<"$card/device/device") == 0x66a1 ]] || continue
          temp=unknown
          for label in "$card"/device/hwmon/hwmon*/temp*_label; do
            [[ -r $label && $(<"$label") == junction ]] && temp=$(<"${label%_label}_input")
          done
          printf 'GPU=%s,%s,%s\n' "$(<"$card/device/gpu_busy_percent")" "$(<"$card/device/mem_info_vram_used")" "$temp"
        done
        """#
        guard (try? ensureKey()) != nil, let output = try? execute("/usr/bin/ssh", sshOptions + [remoteHost, "bash -c \(shellQuote(script))"], timeout: 8) else { return MachineStatus() }
        let lines = output.components(separatedBy: .newlines)
        let gpuLines = lines.filter { $0.hasPrefix("GPU=") }.map { $0.dropFirst(4).split(separator: ",").compactMap { Int($0) } }
        let temps = gpuLines.compactMap { $0.count == 3 ? $0[2] / 1000 : nil }
        var occupation = "unbekannt"
        if lines.contains("BLENDER=yes") { occupation = "Blender läuft" }
        else if lines.contains("LOCK=busy") || lines.contains("PIDS=busy") || gpuLines.contains(where: { $0.count == 3 && ($0[0] != 0 || $0[1] > 536_870_912) }) { occupation = "belegt" }
        else if lines.contains("LOCK=free") && lines.contains("PIDS=free") && gpuLines.count == 3 && gpuLines.allSatisfy({ $0.count == 3 }) { occupation = "frei" }
        return MachineStatus(reachable: true, occupation: occupation, temperatures: temps)
    }

    func generate(_ settings: Settings, control: RunControl, update: @escaping (LogParser) -> Void) throws -> [URL] {
        try requireStori()
        try FileManager.default.createDirectory(at: picturesDirectory, withIntermediateDirectories: true)
        let runName = uniqueName(), start = Date(), fileManager = FileManager.default
        control.setName(runName)
        let localStage = studioRoot.appendingPathComponent(".\(runName)", isDirectory: true)
        try fileManager.createDirectory(at: localStage, withIntermediateDirectories: false)
        let remoteStage = "/home/bigki/h3-image/inputs/.\(runName)"
        var remoteInputs: [String] = []
        var stageCreated = false
        defer {
            try? fileManager.removeItem(at: localStage)
            if stageCreated || !remoteInputs.isEmpty {
                let files = (1...16).map { "\(remoteStage)/\($0).png" } + remoteInputs
                let cleanup = "rm -f -- " + files.map(shellQuote).joined(separator: " ") + "; rmdir -- " + shellQuote(remoteStage) + " 2>/dev/null || :"
                _ = try? execute("/usr/bin/ssh", sshOptions + [remoteHost, cleanup], timeout: 10)
            }
        }
        let refs = settings.mode == "Bearbeiten" ? settings.references : []
        _ = try settings.arguments(remoteReferences: refs.map { $0.path })
        if !refs.isEmpty {
            var state = LogParser(); state.phase = "Hochladen"; update(state)
            let setup = "mkdir -p -- \"$HOME/h3-image/inputs\" && mkdir -- \(shellQuote(remoteStage))"
            try execute("/usr/bin/ssh", sshOptions + [remoteHost, setup], timeout: 45, control: control)
            stageCreated = true
            for (index, reference) in refs.enumerated() {
                let local = localStage.appendingPathComponent("\(index + 1).png")
                guard let image = NSImage(contentsOf: reference.url), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw StudioError.message("Das Referenzbild ‘\(reference.url.lastPathComponent)’ konnte nicht als PNG gelesen werden.") }
                try png.write(to: local, options: .withoutOverwriting)
                let temp = "\(remoteStage)/\(index + 1).png"
                let final = "/home/bigki/h3-image/inputs/\(runName)-picture-\(index + 1).png"
                try execute("/usr/bin/scp", sshOptions + [local.path, "\(remoteHost):\(temp)"], timeout: 180, control: control)
                try execute("/usr/bin/ssh", sshOptions + [remoteHost, "ln -- \(shellQuote(temp)) \(shellQuote(final)) && rm -- \(shellQuote(temp))"], timeout: 45, control: control)
                remoteInputs.append(final)
            }
        }
        let args = try settings.arguments(remoteReferences: remoteInputs)
        var parser = LogParser(), pending = ""
        parser.phase = "Verbinden"; update(parser)
        do {
            try execute("/usr/bin/ssh", sshOptions + ["-tt", remoteHost, remoteCommand(name: runName, arguments: args, vaeTiling: settings.vaeTiling)], control: control, generation: true) { chunk in
                pending += chunk
                while let index = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(pending[..<index]); pending.removeSubrange(...index)
                    parser.consume(line)
                    if let pid = parser.pid { control.setPID(pid); parser.pid = nil }
                    update(parser)
                }
            }
            if !pending.isEmpty { parser.consume(pending); update(parser) }
        } catch let failure as ProcessFailure {
            if !pending.isEmpty { parser.consume(pending) }
            if let message = parser.message { throw StudioError.message(message) }
            if failure.code == 75 { throw StudioError.message("Die GPUs sind belegt. Bitte später erneut versuchen.") }
            if failure.code == 124 { throw StudioError.message("Die Berechnung wurde wegen einer zu hohen GPU-Temperatur oder eines Sensorfehlers abgebrochen.") }
            throw StudioError.message("bigki konnte den Auftrag nicht ausführen (Status \(failure.code)). Bitte Verbindung und Einstellungen prüfen.")
        }
        let prefix = "/home/bigki/h3-image/out/\(runName)"
        guard parser.names.count == settings.count, parser.names.allSatisfy({ path in
            path == prefix + ".png" || (path.hasPrefix(prefix + "_") && match(String(path.dropFirst(prefix.count)), #"^_\d+\.png$"#, 0) != nil)
        }) else { throw StudioError.message("bigki meldete nicht für alle angeforderten Bilder einen gültigen PNG-Dateinamen. Die Ausgaben bleiben auf bigki erhalten.") }
        parser.phase = "Herunterladen"; parser.step = nil; parser.total = nil; update(parser)
        var prepared: [(URL, URL, URL, URL)] = []
        for (index, remote) in parser.names.enumerated() {
            try requireStori()
            let filename = URL(fileURLWithPath: remote).lastPathComponent
            let tempImage = localStage.appendingPathComponent(filename)
            let finalImage = picturesDirectory.appendingPathComponent(filename)
            let tempJSON = tempImage.deletingPathExtension().appendingPathExtension("json")
            let finalJSON = finalImage.deletingPathExtension().appendingPathExtension("json")
            try execute("/usr/bin/scp", sshOptions + ["\(remoteHost):\(remote)", tempImage.path], timeout: 180, control: control)
            let remoteHash = try execute("/usr/bin/ssh", sshOptions + [remoteHost, "sha256sum -- \(shellQuote(remote))"], timeout: 45, control: control).split(separator: " ").first.map(String.init)
            let imageData = try Data(contentsOf: tempImage)
            let localHash = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
            guard remoteHash == localHash, NSImage(data: imageData) != nil else { throw StudioError.message("Das heruntergeladene Bild ist beschädigt oder seine Prüfsumme stimmt nicht. Das Original bleibt auf bigki.") }
            let metadata = RunMetadata(settings: settings, date: start, durationSeconds: Date().timeIntervalSince(start), outputName: filename, actualSeed: index < parser.seeds.count ? parser.seeds[index] : nil)
            try jsonEncoder().encode(metadata).write(to: tempJSON, options: .withoutOverwriting)
            prepared.append((tempImage, finalImage, tempJSON, finalJSON))
        }
        var installed: [URL] = []
        for (image, target, sidecar, targetSidecar) in prepared {
            try requireStori()
            try fileManager.linkItem(at: image, to: target)
            do { try fileManager.linkItem(at: sidecar, to: targetSidecar) }
            catch { try? fileManager.removeItem(at: target); throw error }
            installed.append(target)
        }
        // The verified copies now live on Stori; only this run's generated PNGs are removed.
        _ = try? execute("/usr/bin/ssh", sshOptions + [remoteHost, "rm -- " + parser.names.map(shellQuote).joined(separator: " ")], timeout: 20)
        return installed
    }
}
