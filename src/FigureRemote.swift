import Foundation

// Figures: one image of a person → untextured 3D figure in A-pose (Hunyuan3D-Omni pose control on one MI50).
// The A-pose mesh is the start of the figure recipe (clean → rig/weights → pose) in the Blender session.

extension AgentOps {
    static let figurePoses: Set<String> = ["a", "hand-hoch", "arme-hoch"]

    static func figure(_ p: [String: Any], control: RunControl, progress: @escaping Progress) throws -> [String: Any] {
        let path = (try string(p, "image", required: true) as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw StudioError.message("Bild \(path) nicht gefunden.")
        }
        guard data.count <= 25 * 1024 * 1024 else { throw StudioError.message("Das Bild ist größer als 25 MB.") }
        var request: [String: Any] = ["operation": "figur", "image": data.base64EncodedString(), "origin": requestOrigin]
        if let bones = p["pose"] as? [[Double]] {
            request["pose"] = bones
        } else {
            let pose = (p["pose"] as? String ?? "a").lowercased()
            guard figurePoses.contains(pose) else { throw StudioError.message("pose: a, hand-hoch, arme-hoch oder eine Knochenliste [[x1,y1,z1,x2,y2,z2], …].") }
            request["pose"] = pose
        }
        for key in ["steps", "octree", "seed"] { if let value = int(p, key) { request[key] = value } }
        if let guidance = double(p, "guidance") { request["guidance"] = guidance }

        let start = Date()
        var computeStart = start
        let receiver = try WorkerReceiver(pattern: #"^figur\.glb$"#)
        var last = ""
        try runWorker(request, control: control) { event in
            if try receiver.consume(event) { return }
            switch event["type"] as? String {
            case "waiting":
                if let text = event["message"] as? String, text != last { last = text; progress(text) }
            case "status":
                if event["cards"] != nil { computeStart = Date() }
                if let text = event["message"] as? String, text != last { last = text; progress(text) }
            default: break
            }
        }
        if let error = receiver.error { throw StudioError.message(error) }
        guard let file = receiver.files.first, let result = receiver.result else {
            throw StudioError.message("Die Verbindung zu bigki wurde unterbrochen, bevor die Figur übertragen war.")
        }
        let name = (p["filename"] as? String).map { ($0 as NSString).lastPathComponent } ?? "figur-\(filenameStamp()).glb"
        let target = try receiver.install(file, in: modelsDirectory, name: name.hasSuffix(".glb") ? name : name + ".glb")
        let meta = ModelRecord.metaFolder(for: target)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        let info: [String: Any] = ["kind": "model", "source": "hunyuan3d-omni", "file": target.lastPathComponent,
                                   "date": ISO8601DateFormatter().string(from: Date()), "origin": requestOrigin,
                                   "pose": request["pose"] is String ? request["pose"]! : "eigene", "image": path]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]).write(to: meta.appendingPathComponent("info.json"))
        var answer: [String: Any] = ["ok": true, "file": target.path, "seconds": Int(Date().timeIntervalSince(start)),
                                     "compute_seconds": Int(Date().timeIntervalSince(computeStart))]
        answer["hint"] = (result["hinweis"] as? String ?? "") +
            " In Blender: blender_open file=\(target.path) append=true. Lizenz Hunyuan3D-Omni: nur privat, nicht in der EU/UK/Südkorea veröffentlichen."
        return answer
    }
}

/// "Figur mit Pose" in the Bild-zu-3D tab: the same Hunyuan3D-Omni call the agents use (figure_3d), from one photo.
@MainActor
final class FigureJob: ObservableObject {
    @Published var image: URL?
    @Published var pose = "a"
    @Published var running = false
    @Published var status = ""
    @Published var result: URL?
    @Published var error: String?
    @Published var started = Date()
    var onFinish: (() -> Void)?
    private var control: RunControl?

    static let poses: [(String, String, String)] = [
        ("A-Pose", "a", "Arme leicht abgespreizt – am besten zum Riggen und Posieren in Blender"),
        ("Hand hoch", "hand-hoch", "rechte Hand vor dem Gesicht (z. B. Handy)"),
        ("Arme hoch", "arme-hoch", "beide Arme nach oben"),
    ]

    func start() {
        guard let image, !running else { return }
        running = true; status = "Startet …"; result = nil; error = nil; started = Date()
        let control = RunControl(); self.control = control
        let params: [String: Any] = ["image": image.path, "pose": pose]
        Task.detached(priority: .userInitiated) {
            do {
                let answer = try AgentOps.figure(params, control: control) { text in
                    Task { @MainActor in self.status = text }
                }
                await MainActor.run {
                    self.running = false
                    self.result = (answer["file"] as? String).map { URL(fileURLWithPath: $0) }
                    self.status = "Fertig"
                    Notifier.finished("Figur fertig", "Die 3D-Figur ist bereit.")
                    self.onFinish?()
                }
            } catch {
                await MainActor.run { self.running = false; self.status = ""; self.error = error.localizedDescription }
            }
        }
    }

    func cancel() { status = "Wird abgebrochen …"; control?.cancel() }
}
