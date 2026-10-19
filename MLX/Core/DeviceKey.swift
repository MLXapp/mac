import CryptoKit
import Foundation

/// This Mac's identity on MLX Network: a P-256 key made in the Secure Enclave, so it can sign but
/// never leave the Mac. What's stored is only the Enclave's encrypted handle, which is useless on any
/// other Mac, so it lives in the app's own sandbox folder: no Keychain, so macOS never asks for the
/// login password. Macs without a Secure Enclave (virtual machines) use a software key, and say so.
final class DeviceKey: @unchecked Sendable {
    enum Kind: String { case secureEnclave = "Secure Enclave", software = "Software" }

    let kind: Kind
    private let se: SecureEnclave.P256.Signing.PrivateKey?
    private let sw: P256.Signing.PrivateKey?

    /// Compressed public key, lowercase hex (66 chars, starts 02 or 03).
    var publicKeyHex: String {
        let pub = se?.publicKey ?? sw!.publicKey
        return pub.compressedRepresentation.hex
    }

    /// ECDSA P-256 over SHA-256 of `message`, raw r||s as lowercase hex (128 chars).
    func sign(_ message: String) throws -> String {
        let data = Data(message.utf8)
        if let se { return try se.signature(for: data).rawRepresentation.hex }
        return try sw!.signature(for: data).rawRepresentation.hex
    }

    init(secureEnclave: SecureEnclave.P256.Signing.PrivateKey) {
        kind = .secureEnclave
        se = secureEnclave
        sw = nil
    }

    init(software: P256.Signing.PrivateKey) {
        kind = .software
        se = nil
        sw = software
    }

    // MARK: storage (Application Support in the sandbox container, owner-only)

    /// The key for this Mac, made on first use.
    static func loadOrCreate() throws -> DeviceKey {
        if let blob = read("secure-enclave"), let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) {
            return DeviceKey(secureEnclave: k)
        }
        if let raw = read("software"), let k = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return DeviceKey(software: k)
        }
        if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey() {
            try write("secure-enclave", k.dataRepresentation)
            return DeviceKey(secureEnclave: k)
        }
        let k = P256.Signing.PrivateKey()
        try write("software", k.rawRepresentation)
        return DeviceKey(software: k)
    }

    private static func fileURL(_ name: String) -> URL {
        // "MLX" is a folder name, not the app's name: renaming it (or the bundle id) would make a new device key and
        // unlink the Mac from its wallet, so it stays "MLX" whatever the app is called
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MLX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("device-\(name).key")
    }

    private static func read(_ name: String) -> Data? {
        try? Data(contentsOf: fileURL(name))
    }

    private static func write(_ name: String, _ data: Data) throws {
        let url = fileURL(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
