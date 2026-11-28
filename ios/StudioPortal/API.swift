import Foundation
import Security

/// Talks to `studioportal serve` on the Mac mini (reachable only inside the tailnet, bearer token).
enum API {
    static let defaultURL = "https://DEIN-MAC.DEIN-TAILNET.ts.net:8790"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "baseURL") ?? defaultURL }
        set { UserDefaults.standard.set(newValue, forKey: "baseURL") }
    }

    static var token: String {
        get { Keychain.read() ?? "" }
        set { Keychain.write(newValue) }
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    static func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    static func request(_ path: String, _ query: [String: String] = [:], method: String = "GET", body: Data? = nil, type: String = "application/json") -> URLRequest {
        var r = URLRequest(url: url(path, query), timeoutInterval: 60)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = body; r.setValue(type, forHTTPHeaderField: "Content-Type") }
        return r
    }

    static var headers: [String: String] { ["Authorization": "Bearer \(token)"] }

    static func data(_ r: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: r) } catch let e as URLError {
            throw Failure(errorDescription: e.code == .timedOut ? "Der Mac mini antwortet nicht rechtzeitig."
                          : "Mac mini nicht erreichbar – ist Tailscale auf dem iPhone an?")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(errorDescription: message ?? "Mac mini antwortet mit \(status).")
        }
        return data
    }

    static func json(_ path: String, _ query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await data(request(path, query, method: method, body: payload))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(errorDescription: "Unlesbare Antwort.") }
        return value
    }

    /// Uploads a photo to the Mac mini; returns its path there (for references / 3D).
    static func upload(_ image: Data) async throws -> String {
        let data = try await data(request("/api/upload", method: "POST", body: image, type: "application/octet-stream"))
        guard let path = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["path"] as? String else { throw Failure(errorDescription: "Upload fehlgeschlagen.") }
        return path
    }

    private static let wifiSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        return URLSession(configuration: configuration)
    }()

    /// Transfers into a unique temporary file so equal file names never collide.
    static func download(_ path: String, wifiOnly: Bool) async throws -> URL {
        let session = wifiOnly ? wifiSession : URLSession.shared
        let (temp, response) = try await session.download(for: request("/api/file", ["path": path]))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(errorDescription: "Download fehlgeschlagen.") }
        return temp
    }
}

enum Keychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "studioportal-token"]

    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        var q = query; q[kSecValueData as String] = Data(value.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// One job on the Mac mini: start, poll until done, cancel.
@MainActor
final class Job: ObservableObject {
    @Published var running = false
    @Published var progress = ""
    @Published var partial = ""
    @Published var seconds = 0
    @Published var result: [String: Any]?
    @Published var error: String?
    private var id: String?
    private var task: Task<Void, Never>?

    func start(_ tool: String, _ args: [String: Any], interval: Double = 1.5) {
        task?.cancel()
        running = true; progress = "wird gesendet …"; partial = ""; seconds = 0; result = nil; error = nil
        task = Task {
            do {
                let started = try await API.json("/api/run", method: "POST", body: ["tool": tool, "args": args])
                guard let id = started["job_id"] as? String else { throw API.Failure(errorDescription: "Kein Auftrag erhalten.") }
                self.id = id
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    let s = try await API.json("/api/job/\(id)")
                    progress = s["progress"] as? String ?? ""
                    partial = s["partial"] as? String ?? ""
                    seconds = s["seconds"] as? Int ?? seconds
                    switch s["state"] as? String {
                    case "fertig": result = s["result"] as? [String: Any] ?? [:]; running = false; return
                    case "fehlgeschlagen": error = s["error"] as? String ?? "Fehlgeschlagen."; running = false; return
                    default: break
                    }
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }

    func cancel() {
        if let id { Task { _ = try? await API.json("/api/job/\(id)/cancel", method: "POST") } }
        progress = "wird abgebrochen …"
    }
}
