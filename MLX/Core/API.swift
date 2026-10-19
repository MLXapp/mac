import AppKit
import Foundation

/// mlx.app, as the app sees it. Every POST is signed with this Mac's key and is accepted once.
struct API: Sendable {
    let key: DeviceKey
    let base: URL

    init(key: DeviceKey) {
        self.key = key
        base = API.baseURL
    }

    /// mlx.app, or a test server set with: defaults write app.mlx.mac apiBase http://localhost:3031
    static var baseURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "apiBase") ?? "https://mlx.app") ?? URL(string: "https://mlx.app")!
    }

    /// The wallet: wallet.mlx.app, or /wallet on a test server.
    static var walletBaseURL: URL {
        let b = baseURL
        return b.host == "mlx.app" ? URL(string: "https://wallet.mlx.app/")! : b.appendingPathComponent("wallet")
    }

    var walletBase: URL { API.walletBaseURL }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "MLX-Mac/\(SystemInfo.appVersion) (\(SystemInfo.os))"]
        return URLSession(configuration: c)
    }()

    // MARK: chain id (signed into every message)

    private static let chainCache = ChainCache()
    func chain() async throws -> String {
        if let c = await API.chainCache.value { return c }
        struct Stats: Decodable { let chain: String }
        let (data, _) = try await API.session.data(from: base.appendingPathComponent("api/stats"))
        let c = try JSONDecoder().decode(Stats.self, from: data).chain
        await API.chainCache.set(c)
        return c
    }

    // MARK: requests

    func post<T: Decodable>(_ path: String, _ body: some Encodable, as: T.Type = T.self) async throws -> T {
        let data = try JSONEncoder().encode(body)
        let chain = try await chain()
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let message = Signing.requestMessage(chain: chain, device: key.publicKeyHex, method: "POST", path: "/" + path, body: data, ts: ts)
        let sig = try key.sign(message)
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("\(key.publicKeyHex)|\(ts)|\(sig)", forHTTPHeaderField: "x-mlx-device")
        let (out, resp) = try await API.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) {
            throw Failure(message: (try? JSONDecoder().decode(ErrorReply.self, from: out))?.error ?? "mlx.app answered \(code)")
        }
        return try JSONDecoder().decode(T.self, from: out)
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        let (data, resp) = try await API.session.data(from: base.appendingPathComponent(path))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) { throw Failure(message: "mlx.app answered \(code)") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: link

    /// The wallet page that records this Mac for `account` (or for whichever wallet the owner opens,
    /// with `Signing.anyWallet`), signed by this Mac.
    func linkURL(account: String) async throws -> URL {
        let chain = try await chain()
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let name = SystemInfo.name, chip = SystemInfo.chip, mem = SystemInfo.memoryGB, os = SystemInfo.os
        let msg = Signing.linkMessage(chain: chain, account: account, device: key.publicKeyHex, name: name, chip: chip, memoryGB: mem, os: os, ts: ts)
        let sig = try key.sign(msg)
        let payload: [String: Any] = ["account": account, "device": key.publicKeyHex, "name": name, "chip": chip, "memoryGB": mem, "os": os, "ts": ts, "sig": sig]
        let json = try JSONSerialization.data(withJSONObject: payload)
        var c = URLComponents(url: walletBase, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "link", value: json.base64URL)]
        return c.url!
    }

    struct DeviceOwner: Decodable { let linked: Bool; let account: String?; let at: Double? }
    func owner() async throws -> DeviceOwner { try await get("api/device/\(key.publicKeyHex)") }
}

private actor ChainCache {
    var value: String?
    func set(_ v: String) { value = v }
}

// MARK: wire types

struct HelloBody: Encodable {
    let app: String, os: String, chip: String, memoryGB: Int, cores: Int
    let state: String, reason: String, thermal: String, onAC: Bool
    let limits: Limits
    let calibration: Calibration?
    let stops: Stops
    var pod: Pod = Pod(jaccl: Worker.podReady.jaccl, rdma: Worker.podReady.rdma)
    /// Commands from the owner's iPhone or iPad carried out since the last heartbeat.
    var ack: [String] = []
    /// Today on this Mac and its live speed, for the iPhone app.
    var today: Today?
    var tps: Double?
    /// The hardware model ("Mac16,10"), so MLX World can show which kind of Mac this is (0.8.3).
    var hw: String = SystemInfo.model
    struct Today: Encodable { let jobs: Int; let tokens: Int; let passRate: Double? }
    struct Calibration: Encodable { let tokPerSec: Double; let model: String }
    struct Pod: Encodable { let jaccl: Bool; let rdma: Bool }
    struct Stops: Encodable { let count: Int; let p50: Int; let max: Int }
}

struct HelloReply: Decodable {
    let account: String?
    let invited: Bool
    let jobs: Bool
    let calibration: CalibrationSpec?
    let latest: Latest?
    let next: Int?
    let earning: Earning?
    /// From the owner's iPhone or iPad (MLX.app): pause, resume or new limits.
    let commands: [Command]?
    /// The current public (Developer ID-signed, notarized) build; `size` in bytes of its disk image.
    struct Latest: Decodable, Equatable { let version: String; let notes: String; let size: Int? }
    struct Command: Decodable {
        let id: String
        let action: String
        let limits: RemoteLimits?
    }
    struct RemoteLimits: Decodable {
        let idleMinutes: Double?
        let memoryPct: Double?
        let hoursFrom: Double?
        let hoursTo: Double?
        let onlyOnAC: Bool?
        let maxThermal: String?
        let paused: Bool?
    }
    /// Compute rewards for the wallet this Mac works for (amounts in MLX base units, 6 decimals).
    struct Earning: Decodable, Equatable {
        /// Node units this Mac carries for its wallet (Core 2.5, Pro 10, Ultra 40; Latest 1.5×); 0 means it earns at the free weight.
        let units: Double
        let weight: Double
        let today: String
        let mined: String
        let perDayCap: String
        let perDayCapSmall: String
        let score: Double
        let started: Bool
        /// Network price of one MLX in USD.
        let usdPerMlx: Double?
        /// The wallet's biggest node on a Mac of its class, its name, and this Mac's class name ("Core", "Pro Latest"…).
        let fullUnits: Double?
        let nodeName: String?
        let macName: String?
    }
}

struct CalibrationSpec: Decodable, Sendable { let modelId: String; let prompt: String; let maxTokens: Int }

struct Job: Decodable, Sendable, Identifiable {
    let id: String
    let model: String
    let modelId: String
    let prompt: String
    let maxTokens: Int
}
struct JobReply: Decodable { let job: Job?; let reason: String? }

struct ResultBody: Encodable {
    let job: String, outHash: String, tokens: Int, promptTokens: Int, tokPerSec: Double, ttftMs: Int, ms: Int, stop: String, text: String
}
struct OK: Decodable { let ok: Bool? }
/// The reply to a result. `match` is the server's known-answer verdict when it gives one.
struct ResultReply: Decodable { let ok: Bool?; let match: Bool? }
struct ErrorReply: Decodable { let error: String? }
struct Empty: Encodable {}
