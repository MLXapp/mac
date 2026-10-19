import Foundation

/// What the app and its installer (MLXUpdater.xpc, inside the app) share: names, the signature an update must
/// carry, the wire protocol between them and a few pure helpers. The app is sandboxed, so it can't replace
/// itself in /Applications or mount a disk image; the installer service (not sandboxed, only reachable by this
/// app) does those two things and nothing else.
enum UpdateKit {
    static let bundleID = "app.mlx.mac"
    static let serviceName = "app.mlx.mac.updater"
    static let teamID = "CCKXS9W488"

    /// A Developer ID app from Flex UK Limited (team CCKXS9W488) with MLX's bundle id: the designated
    /// requirement codesign gives a Developer ID build. Nothing else is ever installed.
    static let appRequirement =
        #"anchor apple generic and identifier "app.mlx.mac" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "CCKXS9W488""#
    /// Anything signed by the team (used by the service to tell a release build from a local ad-hoc one).
    static let teamRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "CCKXS9W488""#

    /// The new copy waits next to the app under this hidden name until it is swapped in.
    static let stagingPrefix = ".MLX-update-"

    /// Numbers of a version: "0.8.10" → [0, 8, 10]; anything after the dotted numbers ("-beta") is ignored.
    static func versionParts(_ v: String) -> [Int] {
        let head = v.trimmingCharacters(in: .whitespaces).prefix { ("0"..."9").contains($0) || $0 == "." }
        return head.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }

    /// Is `a` a later version than `b`? Compared number by number, so 0.8.10 > 0.8.9 and 0.9 == 0.9.0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = versionParts(a), y = versionParts(b)
        guard !x.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// The mount points in `hdiutil attach -plist` output (entities without a file system have none).
    static func mountPoints(hdiutilPlist data: Data) -> [String] {
        // hdiutil can print a line or two before the plist; start at the XML header
        var d = data
        if let r = data.range(of: Data("<?xml".utf8)) { d = data.subdata(in: r.lowerBound..<data.endIndex) }
        guard let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return [] }
        return entities.compactMap { $0["mount-point"] as? String }.filter { !$0.isEmpty }
    }

    /// "MLX-082.dmg" for 0.8.2, the name CI and mlx.app give the disk image.
    static func dmgName(_ version: String) -> String {
        "MLX-\(version.filter { $0 != "." }).dmg"
    }
}

/// Why an update stopped. The code crosses the XPC connection as an Int.
struct UpdateFailure: LocalizedError {
    enum Code: Int { case failed = 1, notWritable = 2, badSignature = 3, notNewer = 4 }
    let code: Code
    let message: String
    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
    var errorDescription: String? { message }
}

/// The installer service's interface (the app calls it over NSXPCConnection). Replies carry a code (0 = ok)
/// and a message; the explicit Objective-C name keeps the two modules' protocols identical.
@objc(MLXUpdaterProtocol) protocol UpdaterProtocol {
    /// Mount the disk image (read-only, hidden), check the app inside (signature, bundle id, newer than
    /// `target`), copy it next to `target` and check the copy. Replies with the copy's path and its version.
    func prepare(_ dmg: FileHandle, target: String, withReply reply: @escaping (String?, String?, Int, String?) -> Void)
    /// Swap the prepared copy in for `target` in one step and remove the old version.
    func install(_ staged: String, target: String, withReply reply: @escaping (Int, String?) -> Void)
    /// Remove a prepared copy that won't be installed.
    func discard(_ staged: String, target: String, withReply reply: @escaping () -> Void)
    /// "MLXUpdater 0.8.2 (release)": the service is there and answers this app (the self-test asks).
    func ping(withReply reply: @escaping (String) -> Void)
}
