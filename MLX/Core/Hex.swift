import CryptoKit
import Foundation

extension Data {
    /// Lowercase hex, as the server expects.
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// base64url without padding, for links.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

func sha256Hex(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }
func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }
