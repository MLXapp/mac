import AppKit
import CryptoKit
import Foundation

/// This Mac as a witness of the MLX ledger (MLX Node 0.9.7, 25 Oct 2026; docs/INTEGRITY.md on mlx.app). It keeps only
/// the newest checkpoint it cosigned. Every ten minutes it fetches the current one with a consistency proof from its
/// own, checks the sequencer's signature and the proof, and cosigns with this Mac's Secure Enclave key. Once an hour it
/// reads the newest anchor straight from Solana (not through mlx.app) and checks that it agrees. Anything inconsistent
/// is kept as evidence (two signed checkpoints that can't both be true) and shown in Settings.
@MainActor
final class Witness: ObservableObject {
    static let shared = Witness()

    struct State: Codable, Equatable {
        var size: Int
        var root: String // hex
        var note: String
        var at: Date
    }

    @Published private(set) var state: State?
    @Published private(set) var problem: String?
    @Published private(set) var anchorCheck: (size: Int, at: Date, ok: Bool)?
    @Published private(set) var lastCheck: Date?

    private let defaults = UserDefaults.standard
    private var running = false
    private var lastAnchorCheck = Date.distantPast

    private init() {
        if let d = defaults.data(forKey: "witness.v1"), let s = try? JSONDecoder().decode(State.self, from: d) { state = s }
        problem = defaults.string(forKey: "witness.problem")
    }

    /// Called from the heartbeat loop; does its work at most every ten minutes (and the anchor check hourly).
    func tick(api: API) async {
        guard !running else { return }
        if let l = lastCheck, Date().timeIntervalSince(l) < 600 { return }
        running = true
        defer { running = false }
        lastCheck = Date()
        do {
            try await check(api: api)
            if Date().timeIntervalSince(lastAnchorCheck) > 3600 {
                lastAnchorCheck = Date()
                try? await checkAnchor(api: api)
            }
        } catch {
            // offline or mlx.app busy: try again next time
        }
    }

    private struct LogInfo: Decodable {
        let sequencer: String
        let anchorStatus: AnchorStatus?
        struct AnchorStatus: Decodable { let address: String? }
    }
    private struct ProofReply: Decodable { let proof: [String] }
    private struct CosignBody: Encodable { let size: Int; let time: Int; let sig: String }
    private struct CosignReply: Decodable { let ok: Bool?; let size: Int? }

    /// The sequencer key and the Solana anchor account, pinned the first time they're seen.
    private func pinned(_ info: LogInfo) -> (seq: String, anchor: String?)? {
        let seq = defaults.string(forKey: "witness.sequencer") ?? info.sequencer
        if defaults.string(forKey: "witness.sequencer") == nil { defaults.set(seq, forKey: "witness.sequencer") }
        guard seq == info.sequencer else {
            flag("mlx.app now signs with a different sequencer key than the one this Mac pinned.")
            return nil
        }
        var anchor = defaults.string(forKey: "witness.anchor")
        if anchor == nil, let a = info.anchorStatus?.address { anchor = a; defaults.set(a, forKey: "witness.anchor") }
        return (seq, anchor)
    }

    private func check(api: API) async throws {
        let info: LogInfo = try await api.get("api/log")
        guard let keys = pinned(info) else { return }
        let (noteData, resp) = try await URLSession.shared.data(from: api.base.appendingPathComponent("api/log/checkpoint"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let note = String(data: noteData, encoding: .utf8) else { return }
        guard let cp = TLog.parseCheckpoint(note, sequencer: keys.seq) else {
            flag("The checkpoint mlx.app served isn't signed by the sequencer key.")
            return
        }
        if let s = state {
            if cp.size < s.size {
                evidence(s.note, note, why: "mlx.app showed a smaller log than this Mac already cosigned")
                return
            }
            if cp.size == s.size {
                if cp.root.hex != s.root { evidence(s.note, note, why: "two different roots for the same log size") }
                else { try await cosign(api: api, cp) }
                return
            }
            let p: ProofReply = try await getJSON(api, "api/log/consistency?from=\(s.size)&to=\(cp.size)")
            let proof = p.proof.compactMap { Data(hexString: $0) }
            guard let old = Data(hexString: s.root),
                  TLog.verifyConsistency(m: s.size, n: cp.size, root1: old, root2: cp.root, proof: proof) else {
                evidence(s.note, note, why: "the new checkpoint doesn't extend the one this Mac cosigned")
                return
            }
        }
        try await cosign(api: api, cp)
    }

    private func cosign(api: API, _ cp: TLog.Checkpoint) async throws {
        let time = Int(Date().timeIntervalSince1970)
        let sig = try api.key.sign(TLog.cosignMessage(time: time, body: cp.body))
        _ = try? await api.post("api/log/cosign", CosignBody(size: cp.size, time: time, sig: sig), as: CosignReply.self)
        let s = State(size: cp.size, root: cp.root.hex, note: cp.note, at: Date())
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: "witness.v1") }
        withAnimationIfAvailable { self.state = s }
    }

    /// The newest anchor, read from Solana's public RPC (so mlx.app can't filter it), checked against what this Mac
    /// cosigned: the two logs must be consistent with each other.
    private func checkAnchor(api: API) async throws {
        guard let mine = state, let anchor = defaults.string(forKey: "witness.anchor") else { return }
        let rpc = URL(string: "https://api.mainnet-beta.solana.com")!
        func call(_ method: String, _ params: [Any]) async throws -> Any? {
            var req = URLRequest(url: rpc)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let (d, _) = try await URLSession.shared.data(for: req)
            return (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["result"]
        }
        guard let sigs = try await call("getSignaturesForAddress", [anchor, ["limit": 1]]) as? [[String: Any]], let sig = sigs.first?["signature"] as? String,
              let tx = try await call("getTransaction", [sig, ["encoding": "json", "maxSupportedTransactionVersion": 0]]) as? [String: Any],
              let logs = (tx["meta"] as? [String: Any])?["logMessages"] as? [String],
              let memo = logs.first(where: { $0.contains("Memo") }),
              let m = memo.range(of: #"log (\d+) ([0-9a-f]{64})"#, options: .regularExpression) else { return }
        let parts = memo[m].split(separator: " ")
        guard parts.count == 3, let aSize = Int(parts[1]), let aRoot = Data(hexString: String(parts[2])), let myRoot = Data(hexString: mine.root) else { return }
        var ok = false
        if aSize == mine.size {
            ok = aRoot == myRoot
        } else {
            let (from, to) = aSize < mine.size ? (aSize, mine.size) : (mine.size, aSize)
            let p: ProofReply = try await getJSON(api, "api/log/consistency?from=\(from)&to=\(to)")
            let proof = p.proof.compactMap { Data(hexString: $0) }
            ok = aSize < mine.size
                ? TLog.verifyConsistency(m: aSize, n: mine.size, root1: aRoot, root2: myRoot, proof: proof)
                : TLog.verifyConsistency(m: mine.size, n: aSize, root1: myRoot, root2: aRoot, proof: proof)
        }
        anchorCheck = (aSize, Date(), ok)
        if !ok { flag("The newest Solana anchor doesn't agree with the log this Mac cosigned (anchor at size \(aSize), tx \(sig)).") }
    }

    // MARK: evidence

    private func evidence(_ a: String, _ b: String, why: String) {
        let text = "MLX Node witness evidence, \(ISO8601DateFormatter().string(from: Date()))\n\(why)\n\n--- cosigned before ---\n\(a)\n--- served now ---\n\(b)\n"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MLX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("witness-evidence-\(Int(Date().timeIntervalSince1970)).txt")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        flag("Inconsistency found: \(why). Evidence saved.")
    }

    private func flag(_ why: String) {
        defaults.set(why, forKey: "witness.problem")
        withAnimationIfAvailable { self.problem = why }
    }

    /// The folder with saved evidence, for "Show evidence" in Settings.
    func revealEvidence() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MLX", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func withAnimationIfAvailable(_ body: () -> Void) { body() }

    /// GET with a query string (API.get appends a path component, which would escape the "?").
    private func getJSON<T: Decodable>(_ api: API, _ pathAndQuery: String) async throws -> T {
        guard let url = URL(string: api.base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + pathAndQuery) else { throw API.Failure(message: "Bad URL") }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw API.Failure(message: "mlx.app answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
