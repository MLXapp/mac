import Foundation

/// What the app and its installer (MLXUpdater.xpc, inside the app) share: names, the signature an update must
/// carry, the wire protocol between them and a few pure helpers. The app is sandboxed, so it can't replace
/// itself in /Applications or mount a disk image; the installer service (not sandboxed, only reachable by this
/// app) does those things, plus giving an install from before 0.9.0 its new name, and nothing else.
enum UpdateKit {
    static let bundleID = "app.mlx.mac"
    static let serviceName = "app.mlx.mac.updater"
    static let teamID = "CCKXS9W488"

    /// A Developer ID app from Flex UK Limited (team CCKXS9W488) with MLX Node's bundle id: the designated
    /// requirement codesign gives a Developer ID build. Nothing else is ever installed.
    static let appRequirement =
        #"anchor apple generic and identifier "app.mlx.mac" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "CCKXS9W488""#
    /// Anything signed by the team (used by the service to tell a release build from a local ad-hoc one).
    static let teamRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "CCKXS9W488""#

    /// The new copy waits next to the app under this hidden name until it is swapped in.
    static let stagingPrefix = ".MLX-update-"

    // MARK: the app's file name

    /// The app's file name from 0.9.0 (what the disk image holds and what an update ends up as).
    static let appFileName = "MLX Node.app"
    /// The file name of every install before 0.9.0.
    static let legacyAppFileName = "MLX.app"

    /// Where an app running from `app` should move to take the current name, or nil if it stays where it is.
    ///
    /// Why the rename happens on the first launch after an update, not in the installer: the update from 0.8.x to
    /// 0.9.0 is installed by 0.8.x's own installer service, which swaps the new version in under the path it was
    /// given (".../MLX.app") and can't be changed any more. So 0.9.0 arrives as MLX.app and, while it is restarting
    /// anyway, asks its own installer for one rename in the same folder that never replaces anything
    /// (`Installer.moveToCurrentName`). Only the exact old name moves (a copy the owner renamed keeps its name),
    /// never a copy macOS translocated, and never onto something already there (`exists`; the installer checks
    /// again and renames with RENAME_EXCL). Every other case keeps the installed path.
    static func renamedPath(for app: String, exists: (String) -> Bool) -> String? {
        let url = URL(fileURLWithPath: app, isDirectory: true)
        guard url.lastPathComponent == legacyAppFileName, !app.contains("/AppTranslocation/") else { return nil }
        let dest = url.deletingLastPathComponent().appendingPathComponent(appFileName, isDirectory: true).path
        guard dest != url.path, !exists(dest) else { return nil }
        return dest
    }

    /// After asking for the rename: the path to restart from, or nil to keep running where it is. The disk decides,
    /// not the installer's answer (which may not arrive): restart only if the app is at `new` and no longer at `old`.
    static func restartPath(old: String, new: String?, exists: (String) -> Bool) -> String? {
        guard let new, new != old, exists(new), !exists(old) else { return nil }
        return new
    }

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

    // MARK: installing from the disk image (0.9.8)

    /// The folders MLX Node installs into, in order: the Mac's Applications folder, then the owner's own.
    static func installFolders(home: String) -> [String] {
        ["/Applications", (home as NSString).appendingPathComponent("Applications")]
    }

    /// Is MLX Node running from its disk image? `path` is where it runs; `original` is where a copy macOS translocated
    /// came from (nil if unknown or not translocated); `readOnly` is whether that place's volume is read-only (nil if
    /// unknown). A disk image is mounted under /Volumes and read-only; an app on a writable external drive under
    /// /Volumes (someone's Applications folder there) runs as usual. A translocated copy counts by where it came from.
    static func isOnDiskImage(path: String, original: String?, readOnly: Bool?) -> Bool {
        let place = Translocation.isTranslocated(path) ? (original ?? "") : path
        guard place.hasPrefix("/Volumes/"), place.count > "/Volumes/".count else { return false }
        return readOnly != false
    }

    /// A volume the installer may eject once MLX Node has been copied from it: a read-only mount directly under
    /// /Volumes ("/Volumes/MLX Node", "/Volumes/MLX Node 1"), never the start-up disk or anything deeper.
    static func isEjectableVolume(_ mount: String, readOnly: Bool?) -> Bool {
        let m = mount.hasSuffix("/") ? String(mount.dropLast()) : mount
        guard m.hasPrefix("/Volumes/"), readOnly == true else { return false }
        let name = m.dropFirst("/Volumes/".count)
        return !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// What installing `version` from the disk image does.
    struct DiskInstallPlan: Equatable {
        enum Kind: Equatable {
            /// The same or a newer MLX Node is already installed at `path`: nothing is copied, that one is opened.
            case open
            /// Nothing installed yet: copy to `path`.
            case fresh
            /// An older MLX Node at `old`: the new one takes its place at `path` (the current name; `old` may be the
            /// legacy MLX.app beside it, which then goes to the Trash).
            case replace
        }
        let kind: Kind
        /// Where MLX Node ends up (what the app opens afterwards).
        let path: String
        /// The older copy being replaced (`replace` only).
        let old: String?
        /// The version installed there before (nil for a fresh install).
        let previous: String?
    }

    /// Where and how to install `version`, never downgrading. `installed(path)` is the version of the MLX Node at
    /// `path` (bundle id app.mlx.mac), nil if there is none; `writable(folder)` says whether a folder can be written.
    ///  1. The same or a newer version already in /Applications or ~/Applications (either name): open that one.
    ///  2. An older one in a folder that can be written: replace it, under the current name.
    ///  3. Otherwise a fresh copy in /Applications, or ~/Applications when /Applications can't be written.
    static func diskInstallPlan(version: String, home: String, installed: (String) -> String?, writable: (String) -> Bool) -> DiskInstallPlan {
        let folders = installFolders(home: home)
        func at(_ folder: String, _ name: String) -> String { (folder as NSString).appendingPathComponent(name) }
        for f in folders {
            for name in [appFileName, legacyAppFileName] {
                let p = at(f, name)
                if let v = installed(p), !isNewer(version, than: v) {
                    return DiskInstallPlan(kind: .open, path: p, old: nil, previous: v)
                }
            }
        }
        for f in folders where writable(f) {
            let current = at(f, appFileName)
            if let v = installed(current) { return DiskInstallPlan(kind: .replace, path: current, old: current, previous: v) }
            let legacy = at(f, legacyAppFileName)
            if let v = installed(legacy) { return DiskInstallPlan(kind: .replace, path: current, old: legacy, previous: v) }
        }
        let folder = writable(folders[0]) ? folders[0] : folders[1]
        return DiskInstallPlan(kind: .fresh, path: at(folder, appFileName), old: nil, previous: nil)
    }

    /// "MLX-Node-090.dmg" for 0.9.0, the name CI and mlx.app give the disk image (before 0.9.0: "MLX-084.dmg").
    static func dmgName(_ version: String) -> String {
        "MLX-Node-\(version.filter { $0 != "." }).dmg"
    }
}

/// Copies macOS translocated: a quarantined app opened from where it was downloaded can run from a temporary
/// read-only mirror (".../AppTranslocation/<id>/d/MLX Node.app"). Where it really is comes from Security.framework's
/// SecTranslocate calls, which aren't in the public headers, so they are looked up at run time.
enum Translocation {
    static func isTranslocated(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    private typealias IsTranslocatedFn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
    private typealias OriginalPathFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// Where a translocated copy came from, if Security.framework says (nil when it isn't translocated or the call
    /// isn't available).
    static func originalPath(of url: URL) -> String? {
        guard isTranslocated(url.path),
              let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let isSym = dlsym(lib, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        let isTranslocatedURL = unsafeBitCast(isSym, to: IsTranslocatedFn.self)
        let createOriginalPath = unsafeBitCast(origSym, to: OriginalPathFn.self)
        var translocated = false
        guard isTranslocatedURL(url as CFURL, &translocated, nil).boolValue, translocated,
              let original = createOriginalPath(url as CFURL, nil)?.takeRetainedValue()
        else { return nil }
        let path = (original as URL).standardizedFileURL.path
        return path.isEmpty ? nil : path
    }

    /// Fallback: the mirror is a nullfs mount whose source is the folder the app really sits in.
    static func mountSource(of path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let from = withUnsafeBytes(of: &fs.f_mntfromname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return from.hasPrefix("/") ? from : nil
    }

    /// Where the app at `url` really is: its original place if macOS translocated it, else `url`'s own path.
    static func realPath(of url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard isTranslocated(path) else { return path }
        return originalPath(of: url) ?? mountSource(of: path)
    }
}

/// Is this MLX Node running from its disk image (straight from it, or from a copy macOS translocated from it)?
/// Then it offers to install itself instead of setting up (`InstallWindow`, 0.9.8).
enum DiskImage {
    static func isRunningFromDiskImage(_ bundle: URL = Bundle.main.bundleURL) -> Bool {
        let path = bundle.standardizedFileURL.path
        if Translocation.isTranslocated(path) {
            let original = Translocation.realPath(of: bundle)
            let readOnly = original.flatMap { volumeIsReadOnly(URL(fileURLWithPath: $0)) }
            return UpdateKit.isOnDiskImage(path: path, original: original, readOnly: readOnly)
        }
        return UpdateKit.isOnDiskImage(path: path, original: nil, readOnly: volumeIsReadOnly(bundle))
    }

    static func volumeIsReadOnly(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
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
    /// Give an install from before 0.9.0 ("MLX.app") the current name ("MLX Node.app") in the same folder, with
    /// one rename that never replaces anything (0.9.0+). Replies with the new path, or nil, a code and a message.
    func moveToCurrentName(_ target: String, withReply reply: @escaping (String?, Int, String?) -> Void)
    /// Install MLX Node from its disk image (0.9.8+): `source` is the app running from the image (or macOS's
    /// translocated copy of it). Checks its Developer ID signature, copies it to /Applications (or ~/Applications)
    /// as "MLX Node.app", never over the same or a newer version, and, with `eject`, ejects the disk image once the
    /// calling app has quit. Replies with the installed path, the version that was there before (nil if none), a
    /// code (0 = ok) and a message.
    func installFromDisk(_ source: String, eject: Bool, withReply reply: @escaping (String?, String?, Int, String?) -> Void)
    /// Remove a prepared copy that won't be installed.
    func discard(_ staged: String, target: String, withReply reply: @escaping () -> Void)
    /// "MLXUpdater 0.9.0 (release)": the service is there and answers this app (the self-test asks).
    func ping(withReply reply: @escaping (String) -> Void)
}
