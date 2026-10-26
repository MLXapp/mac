import Foundation

/// The JSON the server signs and verifies: object keys sorted, no spaces, strings escaped exactly
/// like JavaScript's JSON.stringify (lib/chain/crypto.ts `canonical`). Only what the app signs.
indirect enum Canon {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case object([String: Canon])
    case array([Canon])

    var json: String {
        switch self {
        case .string(let s): return Canon.quote(s)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[" + a.map(\.json).joined(separator: ",") + "]"
        case .object(let o):
            // JavaScript sorts keys by UTF-16 code units
            let keys = o.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            return "{" + keys.map { Canon.quote($0) + ":" + o[$0]!.json }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

enum Signing {
    /// An open link request: the owner approves it from whichever wallet they sign in to.
    static let anyWallet = "*"

    /// What a device signs to ask to be linked to a wallet (lib/chain/device.ts `linkMessage`).
    static func linkMessage(chain: String, account: String, device: String, name: String, chip: String, memoryGB: Int, os: String, ts: Int) -> String {
        Canon.object([
            "type": .string("mlx-device-link"), "chain": .string(chain), "account": .string(account), "device": .string(device),
            "name": .string(name), "chip": .string(chip), "memoryGB": .int(memoryGB), "os": .string(os), "ts": .int(ts),
        ]).json
    }

    /// What a device signs for each API request (lib/worker/core.ts `deviceRequestMessage`).
    static func requestMessage(chain: String, device: String, method: String, path: String, body: Data, ts: Int) -> String {
        Canon.object([
            "type": .string("mlx-device-request"), "chain": .string(chain), "device": .string(device),
            "method": .string(method.uppercased()), "path": .string(path), "body": .string(sha256Hex(body)), "ts": .int(ts),
        ]).json
    }

    /// The server cleans names this way; send them already clean so the signature still matches.
    static func clean(_ s: String, max: Int) -> String {
        let noControl = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 }))
        let trimmed = noControl.trimmingCharacters(in: .whitespacesAndNewlines)
        // JavaScript slices by UTF-16 code units
        let u = Array(trimmed.utf16)
        if u.count <= max { return trimmed }
        var cut = String(decoding: u[0..<max], as: UTF16.self)
        while cut.utf16.count > max || cut.unicodeScalars.last == "\u{FFFD}" { cut = String(cut.dropLast()) }
        return cut
    }

    static func isWalletName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9-]{2,32}\\.mlx$", options: .regularExpression) != nil
    }

    /// "luca" → "luca.mlx"; trims and lowercases.
    static func walletName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !s.isEmpty && !s.hasSuffix(".mlx") { s += ".mlx" }
        return s
    }
}
