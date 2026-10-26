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
        /// MLX a day this Mac can earn now (its seat, or the free seat).
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

        // Seats (0.9.2). Every field is optional and decoded leniently, so an older mlx.app (or a field it sends in
        // another shape) never breaks the heartbeat: the panel then falls back to what it showed before.
        /// "free" or "dedicated".
        let seat: String?
        /// Free seats get sporadic AI jobs; dedicated seats get them back to back.
        let throttled: Bool?
        /// The seat tier this Mac's chip carries at full rate ("M", "LX"…) and the chip mlx.app has on record.
        let macTier: String?
        let chip: String?
        /// MLX a day on a free seat (base units).
        let freePerDay: String?
        /// The dedicated seat this Mac runs: its tier ("M", "SX"…), name ("Pro") and number (#12).
        let seatTier: String?
        let seatName: String?
        let seatNumber: Int?
        /// The biggest seat this Mac runs at full rate (a tier id) and how many times a free seat it earns here.
        let best: String?
        let maxTimes: Double?
        /// The seats on sale, smallest first (Nano, Lite, Core, Pro, Ultra; Latest editions on the newest chips), with
        /// what each earns on this Mac.
        let offers: [Offer]?

        struct Offer: Decodable, Equatable, Identifiable {
            let tier: String
            let name: String
            /// USD.
            let price: Double
            let units: Double
            /// MLX a day this seat earns on this Mac (base units), and on a Mac of its own class.
            let perDay: String
            let fullPerDay: String
            /// × a free seat, on this Mac.
            let times: Double
            /// Days each reward stays locked.
            let lockDays: Int?
            /// "full", or "reduced" when this Mac's chip runs it as a smaller seat (`earnsAs`).
            let fits: String
            let earnsAs: String?

            var id: String { tier }
            var reduced: Bool { fits == "reduced" }

            enum CodingKeys: String, CodingKey { case tier, name, price, units, perDay, fullPerDay, times, lockDays, fits, earnsAs }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let t = try c.decode(String.self, forKey: .tier)
                tier = t
                name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? t
                price = c.lenientDouble(.price) ?? 0
                units = c.lenientDouble(.units) ?? 0
                let pd = c.lenientUnits(.perDay) ?? "0"
                perDay = pd
                fullPerDay = c.lenientUnits(.fullPerDay) ?? pd
                times = c.lenientDouble(.times) ?? 0
                lockDays = c.lenientDouble(.lockDays).map { Int($0.rounded()) }
                fits = (try? c.decodeIfPresent(String.self, forKey: .fits)) ?? "full"
                earnsAs = try? c.decodeIfPresent(String.self, forKey: .earnsAs)
            }
        }

        enum CodingKeys: String, CodingKey {
            case units, weight, today, mined, perDayCap, perDayCapSmall, score, started, usdPerMlx, fullUnits, nodeName, macName
            case seat, throttled, macTier, chip, freePerDay, seatTier, seatName, seatNumber, best, maxTimes, offers
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            units = try c.decode(Double.self, forKey: .units)
            today = try c.decode(String.self, forKey: .today)
            mined = try c.decode(String.self, forKey: .mined)
            perDayCap = try c.decode(String.self, forKey: .perDayCap)
            weight = c.lenientDouble(.weight) ?? 0
            perDayCapSmall = c.lenientUnits(.perDayCapSmall) ?? "0"
            score = c.lenientDouble(.score) ?? 0
            started = (try? c.decodeIfPresent(Bool.self, forKey: .started)) ?? true
            usdPerMlx = c.lenientDouble(.usdPerMlx)
            fullUnits = c.lenientDouble(.fullUnits)
            nodeName = try? c.decodeIfPresent(String.self, forKey: .nodeName)
            macName = try? c.decodeIfPresent(String.self, forKey: .macName)
            seat = try? c.decodeIfPresent(String.self, forKey: .seat)
            throttled = try? c.decodeIfPresent(Bool.self, forKey: .throttled)
            macTier = try? c.decodeIfPresent(String.self, forKey: .macTier)
            chip = try? c.decodeIfPresent(String.self, forKey: .chip)
            freePerDay = c.lenientUnits(.freePerDay)
            seatTier = try? c.decodeIfPresent(String.self, forKey: .seatTier)
            seatName = try? c.decodeIfPresent(String.self, forKey: .seatName)
            seatNumber = c.lenientDouble(.seatNumber).map { Int($0.rounded()) }
            best = try? c.decodeIfPresent(String.self, forKey: .best)
            maxTimes = c.lenientDouble(.maxTimes)
            offers = try? c.decodeIfPresent([Offer].self, forKey: .offers)
        }
    }
}

extension HelloReply.Earning {
    /// A dedicated seat runs on this Mac. An older mlx.app doesn't say: node units mean a seat.
    var dedicated: Bool { seat.map { $0 == "dedicated" } ?? (units > 0) }

    /// Sporadic AI jobs (a free seat), not back to back. An older mlx.app doesn't say: a free seat is throttled.
    var isThrottled: Bool { throttled ?? !dedicated }

    /// "Free seat", "Pro seat #12", "Ultra Latest seat".
    var seatTitle: String {
        guard dedicated else { return "Free seat" }
        let name = seatName ?? nodeName ?? "Dedicated"
        return seatNumber.map { "\(name) seat #\($0)" } ?? "\(name) seat"
    }

    /// MLX from base units (6 decimals).
    static func value(_ units: String?) -> Double { (Double(units ?? "0") ?? 0) / 1_000_000 }

    /// MLX a free seat mines a day on this Mac (1 MLX): mlx.app's `freePerDay`; an older mlx.app sends none, and then a
    /// free seat's own cap is it; on a dedicated seat, worked back from any offer (perDay ÷ times).
    var freeDay: Double? {
        if let f = freePerDay, Self.value(f) > 0 { return Self.value(f) }
        if !dedicated, Self.value(perDayCap) > 0 { return Self.value(perDayCap) }
        if let o = offers?.first(where: { $0.times > 0 && Self.value($0.perDay) > 0 }) { return Self.value(o.perDay) / o.times }
        return nil
    }

    /// The offer that is the wallet's dedicated seat on this Mac, when it is one of them (a plain Pro seat on a newest
    /// chip is not "Pro Latest", so it is none of them then).
    var currentOffer: Offer? {
        guard dedicated, let offers else { return nil }
        if let t = seatTier { return offers.first { $0.tier == t } }
        guard let n = seatName else { return nil }
        return offers.first { $0.name == n }
    }

    /// "0.0417", "0.83", "1.25", "13.33", "20": MLX an hour from MLX a day; four decimals under 0.1, else up to two.
    static func perHour(_ perDay: Double) -> String {
        let v = perDay / 24
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        if v < 0.1 {
            f.minimumFractionDigits = v == 0 ? 0 : 4
            f.maximumFractionDigits = 4
        } else {
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 2
        }
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.4f", v)
    }

    /// "~0.83 MLX/h", "~0.0417 MLX/h": the one rate the app shows anywhere (MLX Node 0.9.4: per hour only, from MLX a day).
    static func rate(_ perDay: Double) -> String { "~\(perHour(perDay)) MLX/h" }

    /// The biggest seat this Mac runs at full rate, as mlx.app offers it (`best`); else the biggest that fits fully.
    var bestOffer: Offer? {
        guard let offers, !offers.isEmpty else { return nil }
        if let best, let o = offers.first(where: { $0.tier == best }) { return o }
        return offers.last(where: { !$0.reduced }) ?? offers.last
    }

    /// How many times what this Mac earns now the best seat for it earns here, when that is more. On a free seat it
    /// is mlx.app's `maxTimes`, worked out for THIS Mac's chip: 480× is the network-wide most (an Ultra Latest seat
    /// on an M5 Ultra), and promising it on a MacBook Air, which runs an Ultra seat as a Core one, would overpromise.
    /// On a dedicated seat: the best seat's MLX a day over this seat's.
    var upgradeTimes: Double? {
        let now = Self.value(perDayCap)
        if !dedicated {
            if let t = maxTimes, t > 1 { return t }
            if let o = bestOffer, o.times > 1 { return o.times }
            // an older mlx.app sends no offers: a Core seat runs at full rate on every Mac
            let core = Self.value(perDayCapSmall)
            return now > 0 && core > now ? core / now : nil
        }
        guard let o = bestOffer, now > 0 else { return nil }
        let t = Self.value(o.perDay) / now
        return t > 1.01 ? t : nil
    }

    /// Show the upgrade: always on a free seat; on a dedicated seat while a bigger one would earn more on this Mac.
    var canUpgrade: Bool { !dedicated || upgradeTimes != nil }

    /// "80×", "1.5×": rounded down, so it never says more than mlx.app worked out.
    static func times(_ t: Double) -> String {
        if t >= 10 { return "\(Int((t + 0.001).rounded(.down)))×" }
        let d = ((t * 10) + 0.001).rounded(.down) / 10
        return d == d.rounded() ? "\(Int(d))×" : String(format: "%.1f×", d)
    }
}

extension KeyedDecodingContainer {
    /// A number sent as a number or as a string; nil when missing or neither.
    fileprivate func lenientDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    /// MLX base units, normally a string ("1000000"); a whole number is accepted too.
    fileprivate func lenientUnits(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite { return String(Int64(d.rounded())) }
        return nil
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
/// No job comes with `reason`; free seats get AI jobs now and then, so mlx.app may say when to ask again (`retryIn`,
/// seconds) and that this Mac is `throttled` (0.9.2).
struct JobReply: Decodable { let job: Job?; let reason: String?; let retryIn: Double?; let throttled: Bool? }

struct ResultBody: Encodable {
    let job: String, outHash: String, tokens: Int, promptTokens: Int, tokPerSec: Double, ttftMs: Int, ms: Int, stop: String, text: String
}
struct OK: Decodable { let ok: Bool? }
/// The reply to a result. `match` is the server's known-answer verdict when it gives one.
struct ResultReply: Decodable { let ok: Bool?; let match: Bool? }
struct ErrorReply: Decodable { let error: String? }
struct Empty: Encodable {}
