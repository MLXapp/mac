import CryptoKit
import Foundation

/// The ledger's transparency log, as a witness checks it (lib/chain/tlog.ts on mlx.app, same rules): RFC 9162 Merkle
/// hashes, consistency proofs, and the C2SP signed-note checkpoint the sequencer signs with Ed25519.
enum TLog {
    static func leafHash(_ data: Data) -> Data { Data(SHA256.hash(data: Data([0]) + data)) }
    static func nodeHash(_ l: Data, _ r: Data) -> Data { Data(SHA256.hash(data: Data([1]) + l + r)) }

    private static func isPow2(_ n: Int) -> Bool { n > 0 && (n & (n - 1)) == 0 }

    /// RFC 9162 §2.1.4.2: is the tree (m, root1) a prefix of the tree (n, root2)?
    static func verifyConsistency(m: Int, n: Int, root1: Data, root2: Data, proof: [Data]) -> Bool {
        if m > n { return false }
        if m == n { return proof.isEmpty && root1 == root2 }
        if m == 0 { return proof.isEmpty }
        var path = proof
        if isPow2(m) { path.insert(root1, at: 0) }
        guard !path.isEmpty else { return false }
        var fn = m - 1, sn = n - 1
        while fn % 2 == 1 { fn >>= 1; sn >>= 1 }
        var fr = path[0], sr = path[0]
        for c in path.dropFirst() {
            if sn == 0 { return false }
            if fn % 2 == 1 || fn == sn {
                fr = nodeHash(c, fr)
                sr = nodeHash(c, sr)
                if fn % 2 == 0 {
                    repeat { fn >>= 1; sn >>= 1 } while fn % 2 == 0 && fn != 0
                }
            } else {
                sr = nodeHash(sr, c)
            }
            fn >>= 1
            sn >>= 1
        }
        return sn == 0 && fr == root1 && sr == root2
    }

    struct Checkpoint: Equatable {
        let origin: String
        let size: Int
        let root: Data
        let body: String
        let note: String
    }

    /// C2SP key ID: first 4 bytes of SHA-256(name ‖ "\n" ‖ 0x01 ‖ Ed25519 public key).
    static func keyID(_ name: String, _ pub: Data) -> Data { Data(SHA256.hash(data: Data((name + "\n").utf8) + Data([1]) + pub).prefix(4)) }

    /// Parse a signed note and check the sequencer's Ed25519 signature on it; nil if anything is off.
    static func parseCheckpoint(_ note: String, sequencer pubHex: String) -> Checkpoint? {
        guard let pub = Data(hexString: pubHex), pub.count == 32, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
              let split = note.range(of: "\n\n") else { return nil }
        let body = String(note[..<split.lowerBound]) + "\n"
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 4, let size = Int(lines[1]), size >= 0, let root = Data(base64Encoded: String(lines[2])), root.count == 32 else { return nil }
        let origin = String(lines[0])
        let kid = keyID(origin, pub)
        for line in note[split.upperBound...].split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "\u{2014}", parts[1] == origin, let raw = Data(base64Encoded: String(parts[2])), raw.count == 68,
                  raw.prefix(4) == kid else { continue }
            if key.isValidSignature(raw.suffix(64), for: Data(body.utf8)) {
                return Checkpoint(origin: origin, size: size, root: root, body: body, note: note)
            }
        }
        return nil
    }

    /// What a witness signs: "as of time t, this is the newest consistent checkpoint I've seen".
    static func cosignMessage(time: Int, body: String) -> String { "mlx-cosignature/v1\ntime \(time)\n\(body)" }
}

extension Data {
    init?(hexString: String) {
        let s = Array(hexString.utf8)
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = 0
        while i < s.count {
            guard let hi = Data.nibble(s[i]), let lo = Data.nibble(s[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}
