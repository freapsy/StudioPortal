import Foundation
import Network
import AppKit

/// HTTP gateway for the iPhone app: `studioportal serve` (LaunchAgent on the Mac mini). Reachable only from Tailscale
/// (100.64.0.0/10) or this Mac, every request needs the bearer token. It reuses the agent operations, so the iPhone can
/// do what the app and agents can, and results land in the normal library (and sync to the MacBook).
enum GatewayConfig {
    static let port: UInt16 = 8790        // what the iPhone uses (tailscale serve, HTTPS, tailnet only)
    static let localPort: UInt16 = 8791   // the gateway itself, loopback; tailscale holds 8790 on the tailnet addresses
    static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StudioPortal", isDirectory: true)
    static let tokenFile = support.appendingPathComponent("iphone-token")
    static let uploads = support.appendingPathComponent("iPhone-Uploads", isDirectory: true)
    static let agentLabel = "local.beispiel.studioportal.gateway"

    static func token() throws -> String {
        if let text = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 32 { return text }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw StudioError.message("Zufallszahlen nicht verfügbar.") }
        let text = "sp-" + Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        try Data(text.utf8).write(to: tokenFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return text
    }

    /// Installs the LaunchAgent that keeps `studioportal serve` running and returns what the iPhone needs.
    static func install() throws -> [String: Any] {
        let binary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/StudioPortal.app/Contents/MacOS/StudioPortal").path
        let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": [binary, "serve"], "RunAtLoad": true, "KeepAlive": true,
                                    "ProcessType": "Interactive",
                                    "StandardErrorPath": support.appendingPathComponent("gateway.log").path]
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: target, options: .atomic)
        let domain = "gui/\(getuid())"
        _ = try? runQuiet("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"])
        try runQuiet("/bin/launchctl", ["bootstrap", domain, target.path])
        let tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        try runQuiet(tailscale, ["serve", "--bg", "--https=\(port)", "http://127.0.0.1:\(localPort)"])
        let name = (try? runQuiet(tailscale, ["status", "--json"])).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .flatMap { ($0["Self"] as? [String: Any])?["DNSName"] as? String }?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["url": "https://\(name ?? "<name>.ts.net"):\(port)", "token": try token(), "launch_agent": target.path]
    }

    @discardableResult
    static func runQuiet(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw StudioError.message("\(tool) \(arguments.joined(separator: " ")): \(text)") }
        return text
    }

    static func tailscaleAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 22 == (100 << 2 | 1) { // 100.64.0.0/10 = Tailscale CGNAT range
                return "\(ip >> 24).\(ip >> 16 & 255).\(ip >> 8 & 255).\(ip & 255)"
            }
        }
        return nil
    }
}

final class GatewayJob {
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    let tool: String
    let started = Date()
    let control = RunControl()
    let node = AgentOps.NodeControl()
    var pi: PhotoCraftSession?
    var state = "läuft"
    var progress = ""
    var partial = ""
    var result: [String: Any]?
    var error: String?
    init(tool: String) { self.tool = tool }
}

final class Gateway {
    private var listener: NWListener?
    private var jobs: [String: GatewayJob] = [:]
    private let lock = NSLock()
    private let dictationSlot = DispatchSemaphore(value: 1)
    private let token: String
    private let queue = DispatchQueue(label: "gateway", attributes: .concurrent)
    static let tools: Set<String> = ["create_image", "create_music", "render_music_full", "create_video", "figure_3d", "image_to_3d", "llm_chat", "llm", "llm_pi", "blender_mobile", "compare_images", "import_model"]

    init() throws { token = try GatewayConfig.token() }

    func run() -> Never {
        requestOrigin = "iPhone · App"
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // only this Mac; the tailnet reaches it through `tailscale serve` (HTTPS, tailnet only), the firewall stays closed
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: GatewayConfig.localPort)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { FileHandle.standardError.write(Data("Gateway: \(error)\n".utf8)); exit(1) }
            }
            listener.start(queue: queue)
            self.listener = listener
            FileHandle.standardError.write(Data("StudioPortal-Gateway auf Port \(GatewayConfig.localPort) → Tailnet \(GatewayConfig.port) (\(GatewayConfig.tailscaleAddress() ?? "ohne Tailscale"))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Gateway: \(error.localizedDescription)\n".utf8)); exit(1)
        }
        dispatchMain()
    }

    // MARK: HTTP plumbing (one request per connection, Connection: close)

    private struct Request { var method: String; var path: String; var query: [String: String]; var headers: [String: String]; var body: Data }

    private func allowed(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let b = [UInt8](address.rawValue)
            return b == [127, 0, 0, 1] || (b[0] == 100 && b[1] & 0xC0 == 64)
        case .ipv6(let address):
            return address == .loopback || [UInt8](address.rawValue).starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) // Tailscale ULA
        default: return false
        }
    }

    private func accept(_ connection: NWConnection) {
        guard allowed(connection.endpoint) else { connection.cancel(); return }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 60 * 1024 * 1024 { connection.cancel(); return }
            if let request = self.parse(buffer) {
                self.queue.async { self.respond(connection, request) }
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let components = URLComponents(string: String(first[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(first[0]), path: components?.path ?? "/", query: query, headers: headers, body: Data(body.prefix(length)))
    }

    private func send(_ connection: NWConnection, status: Int, type: String = "application/json", body: Data, extra: [String: String] = [:]) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 416: "Range Not Satisfiable", 500: "Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (key, value) in extra { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func json(_ connection: NWConnection, _ value: Any, status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        send(connection, status: status, body: data)
    }

    // MARK: routes

    private func respond(_ connection: NWConnection, _ r: Request) {
        let given = r.headers["authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "") } ?? r.query["token"] ?? ""
        guard given.utf8.count == token.utf8.count, zip(given.utf8, token.utf8).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            json(connection, ["error": "Falscher oder fehlender Schlüssel."], status: 401); return
        }
        do {
            let parts = r.path.split(separator: "/").map(String.init)
            switch (r.method, parts) {
            case ("GET", ["api", "ping"]):
                json(connection, ["ok": true, "mac": machineName, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"])
            case ("GET", ["api", "status"]):
                json(connection, AgentOps.status())
            case ("GET", ["api", "presets"]):
                let map: (PresetChoice) -> [String: String] = { ["id": $0.id, "title": $0.title, "icon": $0.icon, "note": $0.note] }
                json(connection, ["image": ImagePreset.all.map { map($0.choice) }, "music": MusicPreset.all.map { map($0.choice) },
                                  "video": VideoPreset.all.map { map($0.choice) }])
            case ("GET", ["api", "library"]):
                var options: [String: Any] = ["search": r.query["search"] ?? "", "limit": Int(r.query["limit"] ?? "") ?? 60]
                if let kind = r.query["kind"], !kind.isEmpty { options["kind"] = kind }
                json(connection, AgentOps.library(options))
            case ("GET", ["api", "chats"]):
                let chats = SavedLLMChat.all().prefix(100).map { chat in
                    ["id": chat.id.uuidString, "title": chat.title, "photoCraft": chat.photoCraftEnabled] as [String: Any]
                }
                json(connection, ["chats": chats])
            case ("GET", _) where parts.count == 3 && parts[0] == "api" && parts[1] == "chats":
                guard let id = UUID(uuidString: parts[2]), let chat = SavedLLMChat.all().first(where: { $0.id == id }) else {
                    json(connection, ["error": "Chat nicht gefunden."], status: 404); return
                }
                json(connection, ["messages": chat.messages.map {
                    var row = ["role": $0.role, "text": $0.text]
                    row["reasoning"] = $0.reasoning
                    row["info"] = $0.info
                    return row
                }])
            case ("POST", ["api", "chats"]):
                let body = try JSONSerialization.jsonObject(with: r.body) as? [String: Any]
                guard let rows = body?["messages"] as? [[String: String]], (1...500).contains(rows.count),
                      rows.allSatisfy({ ["user", "assistant"].contains($0["role"] ?? "") && ($0["text"]?.utf8.count ?? 0) <= 120_000 }),
                      r.body.count <= 1_000_000 else { throw StudioError.message("Ungültiger oder zu großer Chat.") }
                let messages = rows.map { ChatMessage(role: $0["role"] ?? "user", text: $0["text"] ?? "", reasoning: $0["reasoning"], info: $0["info"]) }
                let chat = SavedLLMChat(id: UUID(), savedAt: .now, messages: messages, photoCraftEnabled: false,
                                       photoCraftEffort: .medium, documentName: nil, sourceFolder: nil, snapshot: UUID())
                try chat.save(source: nil, editable: nil, replacing: nil)
                json(connection, ["id": chat.id.uuidString])
            case ("POST", ["api", "dictation"]):
                guard (45...4_000_000).contains(r.body.count), r.body.prefix(4) == Data("RIFF".utf8),
                      r.body.dropFirst(8).prefix(4) == Data("WAVE".utf8) else { throw StudioError.message("Ungültige WAV-Aufnahme.") }
                guard FileManager.default.fileExists(atPath: Dictation.model.path) else {
                    throw StudioError.message("Auf dem Mac mini fehlt das Whisper-Modell. Starte dort einmal das Diktat.")
                }
                guard dictationSlot.wait(timeout: .now()) == .success else {
                    throw StudioError.message("Der Mac mini erkennt gerade ein anderes Diktat.")
                }
                defer { dictationSlot.signal() }
                let wav = URL.temporaryDirectory.appending(path: "studioportal-iphone-\(UUID()).wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                try r.body.write(to: wav, options: .atomic)
                json(connection, ["text": try Dictation.transcribe(wav)])
            case ("POST", ["api", "upload"]):
                try FileManager.default.createDirectory(at: GatewayConfig.uploads, withIntermediateDirectories: true)
                guard !r.body.isEmpty, r.body.count <= 25 * 1024 * 1024, NSImage(data: r.body) != nil else { throw StudioError.message("Kein Bild oder größer als 25 MB.") }
                let url = GatewayConfig.uploads.appendingPathComponent("iphone-\(UUID().uuidString.prefix(8).lowercased()).png")
                guard let rep = NSImage(data: r.body)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
                      let png = rep.representation(using: .png, properties: [:]) else { throw StudioError.message("Bild nicht lesbar.") }
                try png.write(to: url)
                json(connection, ["path": url.path])
            case ("POST", ["api", "run"]):
                guard let body = try JSONSerialization.jsonObject(with: r.body) as? [String: Any], let tool = body["tool"] as? String,
                      Self.tools.contains(tool) else { throw StudioError.message("tool fehlt oder unbekannt.") }
                json(connection, ["job_id": start(tool, body["args"] as? [String: Any] ?? [:]).id])
            case ("GET", _) where parts.count == 3 && parts[0] == "api" && parts[1] == "job":
                let id = parts[2]
                lock.lock(); let job = jobs[id]; lock.unlock()
                guard let job else { json(connection, ["error": "Unbekannter Auftrag."], status: 404); return }
                lock.lock()
                let value: [String: Any] = ["id": job.id, "tool": job.tool, "state": job.state, "progress": job.progress, "partial": job.partial,
                                            "seconds": Int(Date().timeIntervalSince(job.started)), "result": job.result ?? NSNull(), "error": job.error ?? NSNull()]
                lock.unlock()
                json(connection, value)
            case ("POST", _) where parts.count == 4 && parts[0] == "api" && parts[1] == "job" && parts[3] == "cancel":
                let id = parts[2]
                lock.lock(); let job = jobs[id]; let pi = job?.pi; lock.unlock()
                job?.control.cancel(); job?.node.cancel(); pi?.abort()
                json(connection, ["ok": job != nil])
            case ("GET", ["api", "file"]):
                try file(connection, r)
            case ("GET", ["api", "thumb"]):
                let url = try libraryURL(r.query["path"])
                let size = CGFloat(Double(r.query["size"] ?? "") ?? 400)
                guard let image = ThumbnailCache.image(url, size: min(max(size, 64), 1600)),
                      let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
                      let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                    json(connection, ["error": "Keine Vorschau."], status: 404); return
                }
                send(connection, status: 200, type: "image/jpeg", body: jpeg, extra: ["Cache-Control": "max-age=86400"])
            default:
                json(connection, ["error": "Unbekannter Pfad."], status: 404)
            }
        } catch {
            json(connection, ["error": error.localizedDescription], status: 400)
        }
    }

    private func start(_ tool: String, _ args: [String: Any]) -> GatewayJob {
        let job = GatewayJob(tool: tool)
        lock.lock()
        jobs = jobs.filter { Date().timeIntervalSince($0.value.started) < 6 * 3600 } // forget old jobs
        jobs[job.id] = job
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let progress: AgentOps.Progress = { text in self.lock.lock(); job.progress = text; self.lock.unlock() }
            do {
                let value: [String: Any]
                switch tool {
                case "create_image": value = try AgentOps.image(args, control: job.control, progress: progress)
                case "create_music": value = try AgentOps.music(args, control: job.control, progress: progress)
                case "render_music_full": value = try AgentOps.renderFull(args, control: job.control, progress: progress)
                case "create_video": value = try AgentOps.video(args, control: job.control, progress: progress)
                case "figure_3d": value = try AgentOps.figure(args, control: job.control, progress: progress)
                case "image_to_3d": value = try AgentOps.model3D(args, control: job.node, progress: progress)
                case "import_model":
                    let link = (args["source"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: link), url.scheme == "https", url.user == nil, url.password == nil,
                          let host = url.host?.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression),
                          ["sketchfab.com", "polyhaven.com", "printables.com", "blenderkit.com", "blendkit.com", "fab.com"].contains(host) else {
                        throw StudioError.message("Gib einen HTTPS-Link von Sketchfab, Poly Haven, Printables, BlenderKit oder Fab ein.")
                    }
                    value = try AgentOps.importModel(["source": link], control: job.node, progress: progress)
                case "compare_images":
                    let paths = (args["images"] as? [String]) ?? []
                    guard (2...8).contains(paths.count) else { throw StudioError.message("Wähle zwei bis acht Bilder.") }
                    value = try Comparison.make(["images": try paths.map { try libraryURL($0).path }])
                case "blender_mobile":
                    value = try mobileBlender(args, job: job, progress: progress)
                case "llm_pi":
                    value = try mobilePi(args, job: job, progress: progress)
                case "llm_chat":
                    let level = try ThinkingEffort.parse(args["reasoning_effort"] ?? args["thinking"])
                    var extra: [String: Any] = ["messages": args["messages"] ?? [], "thinking": level != .none, "reasoning_effort": level.rawValue]
                    if let n = args["max_tokens"] as? Int { extra["max_tokens"] = n }
                    value = try LLMRemote.call("chat", extra, control: job.control,
                                               onToken: { piece in self.lock.lock(); job.partial += piece; self.lock.unlock() }, progress: progress)
                default: value = try AgentOps.llm(args, control: job.control, progress: progress)
                }
                lock.lock(); job.result = value; job.state = "fertig"; lock.unlock()
            } catch {
                lock.lock(); job.error = error.localizedDescription; job.state = "fehlgeschlagen"; lock.unlock()
            }
        }
        return job
    }

    private func mobileBlender(_ args: [String: Any], job: GatewayJob, progress: @escaping AgentOps.Progress) throws -> [String: Any] {
        let action = args["action"] as? String ?? "scene"
        var options: [String: Any] = ["session": "iphone"]
        switch action {
        case "scene", "check", "save": break
        case "look": options["mode"] = "solid"; options["size"] = 768
        case "render": options["frames"] = 1
        case "open":
            let file = try libraryURL(args["file"] as? String)
            guard ["blend", "glb", "gltf", "obj", "stl"].contains(file.pathExtension.lowercased()) else {
                throw StudioError.message("Wähle ein 3D-Modell aus der Bibliothek.")
            }
            options["file"] = file.path
        default: throw StudioError.message("Unbekannte Blender-Aktion.")
        }
        return try AgentOps.blender(action, options, control: job.control, progress: progress)
    }

    private func mobilePi(_ args: [String: Any], job: GatewayJob, progress: @escaping AgentOps.Progress) throws -> [String: Any] {
        let rows = (args["messages"] as? [[String: String]] ?? []).suffix(32)
        guard let request = rows.last?["content"], !request.isEmpty, request.utf8.count <= 32_000 else {
            throw StudioError.message("Der Auftrag fehlt oder ist zu lang.")
        }
        let source = try (args["document"] as? String).map { try libraryURL($0) }
        if let source, !["png", "jpg", "jpeg", "webp", "tif", "tiff", "psd", "psb", "pcraft", "pdf", "heic"].contains(source.pathExtension.lowercased()) {
            throw StudioError.message("Wähle ein Bild oder ein PhotoCraft-Dokument.")
        }
        let search = args["webSearch"] as? Bool == true
        let session = try PhotoCraftSession(document: source, webSearch: search)
        defer { session.close() }
        lock.lock(); job.pi = session; lock.unlock()
        defer { lock.lock(); job.pi = nil; lock.unlock() }
        _ = try LLMRemote.call("start", control: job.control, progress: progress)
        if job.control.isCancelled() { throw StudioError.message("Auftrag abgebrochen.") }
        let history = rows.dropLast().map { "\($0["role"] == "assistant" ? "assistant" : "user"): \(($0["content"] ?? "").prefix(1600))" }.joined(separator: "\n")
        let prompt = history.isEmpty ? request : "Frühere Nachrichten als Kontext:\n\(history)\n\nAktueller Auftrag:\n\(request)"
        let level = try ThinkingEffort.parse(args["reasoning_effort"])
        let reply = try session.prompt(prompt, effort: level, progress: progress) { piece in
            self.lock.lock(); job.partial += piece; self.lock.unlock()
        }
        return ["text": reply.text, "reasoning_effort": level.rawValue, "seconds": reply.seconds, "used_web": reply.webUsed,
                "files": reply.files.map(\.path)]
    }

    /// Only files inside the library folders (or the iPhone uploads) can be read.
    private func libraryURL(_ raw: String?) throws -> URL {
        guard let raw, !raw.isEmpty else { throw StudioError.message("path fehlt.") }
        let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        let roots = [picturesDirectory, musicDirectory, videosDirectory, modelsDirectory, GatewayConfig.uploads, blenderLooksDirectory, GatewayConfig.support.appendingPathComponent("PhotoCraft-Ergebnisse")].map { $0.resolvingSymlinksInPath().path + "/" }
        guard roots.contains(where: { url.path.hasPrefix($0) }), FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw StudioError.message("Datei liegt nicht in der Bibliothek.")
        }
        return url
    }

    private func file(_ connection: NWConnection, _ r: Request) throws {
        let url = try libraryURL(r.query["path"])
        let handle = try FileHandle(forReadingFrom: url)
        let size: Int
        do { size = Int(try handle.seekToEnd()) }
        catch { try? handle.close(); throw error }
        let type = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "mp3": "audio/mpeg", "wav": "audio/wav",
                    "mp4": "video/mp4", "glb": "model/gltf-binary", "json": "application/json"][url.pathExtension.lowercased()] ?? "application/octet-stream"
        var offset = 0
        var count = size
        var status = "200 OK"
        var rangeHeader = ""
        if let range = r.headers["range"], range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let lower = Int(bounds.first ?? "") ?? 0
            let upper = min(bounds.count > 1 ? Int(bounds[1]) ?? (size - 1) : size - 1, size - 1)
            guard lower >= 0, lower < size, upper >= lower else {
                try? handle.close()
                send(connection, status: 416, body: Data(), extra: ["Content-Range": "bytes */\(size)"]); return
            }
            offset = lower
            count = upper - lower + 1
            status = "206 Partial Content"
            rangeHeader = "Content-Range: bytes \(lower)-\(upper)/\(size)\r\n"
        }
        do { try handle.seek(toOffset: UInt64(offset)) }
        catch { try? handle.close(); throw error }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(count)\r\nAccept-Ranges: bytes\r\n\(rangeHeader)Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error == nil { self.sendFile(connection, handle, remaining: count) }
            else { try? handle.close(); connection.cancel() }
        })
    }

    private func sendFile(_ connection: NWConnection, _ handle: FileHandle, remaining: Int) {
        guard remaining > 0, let data = try? handle.read(upToCount: min(remaining, 512 * 1024)), !data.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            if error == nil { self.sendFile(connection, handle, remaining: remaining - data.count) }
            else { try? handle.close(); connection.cancel() }
        })
    }
}
