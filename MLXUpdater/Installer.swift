import CoreServices
import Foundation
import Security

/// The installer's work, step by step. Every step checks again what the one before it did: the app in the disk
/// image and its copy next to the running app must both carry MLX Node's Developer ID signature (team CCKXS9W488,
/// bundle id app.mlx.mac) and be newer than the version installed; otherwise nothing is touched.
enum Installer {
    struct Prepared {
        let staged: String
        let version: String
    }

    // MARK: prepare

    static func prepare(dmg: FileHandle, target: String) throws -> Prepared {
        let app = try checkTarget(target)
        let installed = try bundleVersion(app)
        let dir = app.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: dir.path), fm.isWritableFile(atPath: app.path) else {
            throw UpdateFailure(.notWritable, "MLX Node can't replace itself in \(dir.path) (no permission to write there).")
        }
        removeLeftovers(in: dir)

        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MLX-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let image = work.appendingPathComponent("MLX.dmg")
        try copy(dmg, to: image)

        let mount = try attach(image)
        defer { detach(mount) }  // runs before the work folder is removed
        let source = try findApp(in: URL(fileURLWithPath: mount, isDirectory: true))
        let version = try verify(source)
        guard UpdateKit.isNewer(version, than: installed) else {
            throw UpdateFailure(.notNewer, "MLX Node \(installed) is already up to date (the download is \(version)).")
        }

        // the copy waits next to the app (same volume, so the swap is one rename)
        let staged = dir.appendingPathComponent("\(UpdateKit.stagingPrefix)\(UUID().uuidString).app", isDirectory: true)
        let (status, _, err) = try run("/usr/bin/ditto", [source.path, staged.path])
        guard status == 0 else {
            try? fm.removeItem(at: staged)
            throw UpdateFailure(.failed, "Couldn't copy the new version (\(err.trimmed.isEmpty ? "ditto \(status)" : err.trimmed)).")
        }
        // nothing here came through a browser, but make sure: no quarantine, so macOS opens it without asking
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        do {
            let copied = try verify(staged)
            guard copied == version else { throw UpdateFailure(.badSignature, "The copied app doesn't match the download.") }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return Prepared(staged: staged.path, version: version)
    }

    // MARK: install

    static func install(staged: String, target: String) throws {
        let app = try checkTarget(target)
        let new = try checkStaged(staged, next: app)
        let version = try verify(new)
        let installed = try bundleVersion(app)
        guard UpdateKit.isNewer(version, than: installed) else {
            throw UpdateFailure(.notNewer, "MLX Node \(installed) is already up to date.")
        }
        // one atomic step: the new version takes the app's place, the old one takes the copy's
        if renamex_np(new.path, app.path, UInt32(RENAME_SWAP)) == 0 {
            try? FileManager.default.removeItem(at: new)
            register(app)
            return
        }
        // a file system without swap: two renames, putting the old version back if the second one fails
        let old = app.deletingLastPathComponent().appendingPathComponent("\(UpdateKit.stagingPrefix)old-\(UUID().uuidString).app", isDirectory: true)
        guard rename(app.path, old.path) == 0 else {
            throw UpdateFailure(.notWritable, "MLX Node can't replace itself in \(app.deletingLastPathComponent().path) (\(errnoText)).")
        }
        guard rename(new.path, app.path) == 0 else {
            let why = errnoText
            _ = rename(old.path, app.path)
            throw UpdateFailure(.failed, "Couldn't move the new version into place (\(why)).")
        }
        try? FileManager.default.removeItem(at: old)
        register(app)
    }

    /// Tell Launch Services the app at this path changed (ditto kept the build's dates), so it opens the new one.
    static func register(_ app: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
        _ = LSRegisterURL(app as CFURL, true)
    }

    static func discard(staged: String, target: String) {
        guard let app = try? checkTarget(target), let new = try? checkStaged(staged, next: app) else { return }
        try? FileManager.default.removeItem(at: new)
    }

    // MARK: install from the disk image (0.9.8)

    struct Installed {
        let path: String
        /// The version that was installed there before (nil for a fresh install).
        let previous: String?
        /// The disk image's volume, to eject once the app has quit (nil if it isn't one).
        let volume: String?
    }

    /// MLX Node opened from its disk image asks to be installed. The app on the image must carry MLX Node's Developer
    /// ID signature; it is copied to /Applications (or ~/Applications when /Applications can't be written) as
    /// "MLX Node.app", checked again, and moved into place in one rename. Never a downgrade: the same or a newer
    /// version already installed is kept and its path returned. An older one is swapped out in one step (the same
    /// staging and RENAME_SWAP as an update); an older copy still called MLX.app (before 0.9.0) goes to the Trash once
    /// the new one is in place.
    static func installFromDisk(source path: String) throws -> Installed {
        let given = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        // a translocated copy is a read-only mirror of the app on the image; read from the image itself when macOS says where
        let source = Translocation.originalPath(of: given).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? given
        guard source.pathExtension == "app" else { throw UpdateFailure(.failed, "\(source.lastPathComponent) isn't an app.") }
        let version: String
        do {
            version = try verify(source)
        } catch let e as UpdateFailure where e.code == .badSignature {
            throw UpdateFailure(.badSignature, "This copy of MLX Node isn't signed by its developer, so it wasn't installed. Download it again from mlx.app/download.")
        }
        let volume = ejectableVolume(of: Translocation.realPath(of: given).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? source)

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let plan = UpdateKit.diskInstallPlan(
            version: version, home: home,
            installed: { p in fm.fileExists(atPath: p) ? (try? bundleVersion(URL(fileURLWithPath: p, isDirectory: true))) : nil },
            writable: { fm.isWritableFile(atPath: $0) })
        let dest = URL(fileURLWithPath: plan.path, isDirectory: true)
        let dir = dest.deletingLastPathComponent()

        switch plan.kind {
        case .open:
            return Installed(path: plan.path, previous: plan.previous, volume: volume)

        case .fresh:
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    throw UpdateFailure(.notWritable, "MLX Node couldn't make the folder \(dir.path) (\(error.localizedDescription)).")
                }
            }
            let staged = try stage(source, version: version, in: dir)
            guard renamex_np(staged.path, dest.path, UInt32(RENAME_EXCL)) == 0 else {
                let why = errno == EEXIST ? "something called \(dest.lastPathComponent) is already there" : errnoText
                try? fm.removeItem(at: staged)
                throw UpdateFailure(.failed, "MLX Node couldn't be moved into \(dir.path) (\(why)).")
            }

        case .replace:
            guard let oldPath = plan.old, let previous = plan.previous else { throw UpdateFailure(.failed, "Nothing to replace.") }
            let old = URL(fileURLWithPath: oldPath, isDirectory: true)
            let staged = try stage(source, version: version, in: dir)
            // check again right before the swap: still MLX Node, still older
            guard let now = try? bundleVersion(old), now == previous, UpdateKit.isNewer(version, than: now) else {
                try? fm.removeItem(at: staged)
                throw UpdateFailure(.failed, "MLX Node in \(dir.path) changed while installing. Try again.")
            }
            if old.path == dest.path {
                // one atomic step: the new version takes the old one's place, the old one takes the copy's
                if renamex_np(staged.path, dest.path, UInt32(RENAME_SWAP)) == 0 {
                    try? fm.removeItem(at: staged)
                } else {
                    // a file system without swap: two renames, putting the old version back if the second one fails
                    let aside = dir.appendingPathComponent("\(UpdateKit.stagingPrefix)old-\(UUID().uuidString).app", isDirectory: true)
                    guard rename(dest.path, aside.path) == 0 else {
                        let why = errnoText
                        try? fm.removeItem(at: staged)
                        throw UpdateFailure(.notWritable, "MLX Node can't replace the older version in \(dir.path) (\(why)).")
                    }
                    guard rename(staged.path, dest.path) == 0 else {
                        let why = errnoText
                        _ = rename(aside.path, dest.path)
                        try? fm.removeItem(at: staged)
                        throw UpdateFailure(.failed, "Couldn't move MLX Node into place (\(why)).")
                    }
                    try? fm.removeItem(at: aside)
                }
            } else {
                // the older copy is still called MLX.app: the new one goes in under its own name, then the old one leaves
                guard renamex_np(staged.path, dest.path, UInt32(RENAME_EXCL)) == 0 else {
                    let why = errno == EEXIST ? "something called \(dest.lastPathComponent) is already there" : errnoText
                    try? fm.removeItem(at: staged)
                    throw UpdateFailure(.failed, "MLX Node couldn't be moved into \(dir.path) (\(why)).")
                }
                try? fm.trashItem(at: old, resultingItemURL: nil)
            }
        }
        register(dest)
        retireLegacy(in: dir, olderThan: version)
        return Installed(path: dest.path, previous: plan.previous, volume: volume)
    }

    /// Copy the app on the disk image next to where it goes (same volume, so moving it in is one rename), without
    /// quarantine, and check the copy's signature and version again.
    private static func stage(_ source: URL, version: String, in dir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: dir.path) else {
            throw UpdateFailure(.notWritable, "MLX Node can't be copied to \(dir.path) (no permission to write there).")
        }
        removeLeftovers(in: dir)
        let staged = dir.appendingPathComponent("\(UpdateKit.stagingPrefix)\(UUID().uuidString).app", isDirectory: true)
        let (status, _, err) = try run("/usr/bin/ditto", [source.path, staged.path])
        guard status == 0 else {
            try? fm.removeItem(at: staged)
            let why = err.trimmed.isEmpty ? "ditto \(status)" : err.trimmed
            throw UpdateFailure(.failed, "Couldn't copy MLX Node to \(dir.path) (\(why)). Is there enough free space?")
        }
        // the disk image came through a browser: the installed copy opens without asking again
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        do {
            let copied = try verify(staged)
            guard copied == version else { throw UpdateFailure(.badSignature, "The copy doesn't match the app on the disk image.") }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// An older copy still called MLX.app beside the new one goes to the Trash (MLX Node is the only one then).
    private static func retireLegacy(in dir: URL, olderThan version: String) {
        let legacy = dir.appendingPathComponent(UpdateKit.legacyAppFileName, isDirectory: true)
        guard let v = try? bundleVersion(legacy), UpdateKit.isNewer(version, than: v) else { return }
        try? FileManager.default.trashItem(at: legacy, resultingItemURL: nil)
    }

    /// The disk image's volume the app sits on, if it is one the installer may eject.
    static func ejectableVolume(of app: URL) -> String? {
        guard let values = try? app.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey]),
              let volume = values.volume?.standardizedFileURL.path,
              UpdateKit.isEjectableVolume(volume, readOnly: values.volumeIsReadOnly)
        else { return nil }
        return volume
    }

    /// Eject the disk image once the app that asked has quit (it runs from that image): a small shell in its own
    /// session (so it outlives this service, which stops with the app) waits up to a minute for `pid` to exit, then
    /// detaches the volume, retrying and finally forcing. If the app is still running after a minute (it stayed
    /// open), nothing is ejected.
    static func scheduleEject(_ volume: String, after pid: pid_t) {
        let script = """
            p="$1"; v="$2"; i=0
            if [ "$p" -gt 0 ] 2>/dev/null; then
              while kill -0 "$p" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 300 ] && exit 0; sleep 0.2; done
            fi
            sleep 1.5
            [ -d "$v" ] || exit 0
            /usr/bin/hdiutil detach "$v" -quiet && exit 0
            sleep 2
            /usr/bin/hdiutil detach "$v" -quiet && exit 0
            sleep 3
            /usr/bin/hdiutil detach "$v" -force -quiet
            """
        spawnDetached(["/bin/sh", "-c", script, "mlx-eject", String(pid), volume])
    }

    /// Start a process in a new session with no inherited descriptors (stdin/out/err on /dev/null), not waiting for it.
    @discardableResult
    static func spawnDetached(_ args: [String]) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID (0x0400) | POSIX_SPAWN_CLOEXEC_DEFAULT (0x4000), from <spawn.h>
        posix_spawnattr_setflags(&attr, Int16(0x0400 | 0x4000))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&files, 2, "/dev/null", O_WRONLY, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envStrings: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let env: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { env.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, args[0], &files, &attr, argv, env) == 0
    }

    // MARK: name

    /// Give an install from before 0.9.0 the app's current name: ".../MLX.app" becomes ".../MLX Node.app" in the same
    /// folder (see `UpdateKit.renamedPath` for when). One rename that never replaces anything (RENAME_EXCL), so at
    /// every moment exactly one complete copy is installed, under the old name or the new one; if anything is in
    /// the way, the app keeps its old name. Nothing is copied or installed and the app's identity doesn't change
    /// (bundle id, signature, sandbox container, settings). Returns the new path.
    static func moveToCurrentName(_ target: String) throws -> String {
        let app = try checkTarget(target)
        let fm = FileManager.default
        guard let dest = UpdateKit.renamedPath(for: app.path, exists: { fm.fileExists(atPath: $0) }) else {
            throw UpdateFailure(.failed, "\(app.lastPathComponent) keeps its name.")
        }
        let dir = app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: dir.path) else {
            throw UpdateFailure(.notWritable, "MLX Node can't rename itself in \(dir.path) (no permission to write there).")
        }
        guard renamex_np(app.path, dest, UInt32(RENAME_EXCL)) == 0 else {
            throw UpdateFailure(.failed, "MLX Node keeps its old name (\(errnoText)).")
        }
        register(URL(fileURLWithPath: dest, isDirectory: true))
        return dest
    }

    // MARK: checks

    /// The installed MLX Node the app asked to replace: a real bundle with its id, not a translocated copy.
    static func checkTarget(_ path: String) throws -> URL {
        let app = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        if app.path.contains("/AppTranslocation/") {
            throw UpdateFailure(.notWritable, "MLX Node is running from a temporary copy macOS made of it, so it can't replace itself.")
        }
        guard app.pathExtension == "app" else { throw UpdateFailure(.failed, "\(app.path) isn't an app.") }
        _ = try bundleVersion(app)
        return app
    }

    /// A copy this service made: hidden, next to `app`.
    static func checkStaged(_ path: String, next app: URL) throws -> URL {
        let new = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard new.deletingLastPathComponent().path == app.deletingLastPathComponent().path,
              new.lastPathComponent.hasPrefix(UpdateKit.stagingPrefix), new.pathExtension == "app"
        else { throw UpdateFailure(.failed, "The prepared update isn't where it should be. Try again.") }
        return new
    }

    /// MLX Node's version from a bundle's Info.plist, if the bundle is MLX Node (bundle id app.mlx.mac, whatever its file name).
    static func bundleVersion(_ app: URL) throws -> String {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == UpdateKit.bundleID,
              let v = info["CFBundleShortVersionString"] as? String, !v.isEmpty
        else { throw UpdateFailure(.failed, "\(app.lastPathComponent) isn't MLX Node.") }
        return v
    }

    /// Strict check of the whole bundle (every architecture, nested code, no symlinks out) against MLX Node's
    /// Developer ID requirement. Returns the bundle's version.
    @discardableResult
    static func verify(_ app: URL) throws -> String {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw UpdateFailure(.badSignature, "The new version isn't signed, so it wasn't installed (\(status)).")
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(UpdateKit.appRequirement as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw UpdateFailure(.failed, "Couldn't read the signature rule (\(status)).")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSRestrictSymlinks))
        var errors: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &errors)
        guard status == errSecSuccess else {
            let why = errors.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "error \(status)"
            throw UpdateFailure(.badSignature, "The new version isn't signed by MLX Node's developer, so it wasn't installed (\(why)).")
        }
        return try bundleVersion(app)
    }

    /// Is this service itself signed by the team (a release build) rather than ad hoc (a local build)?
    static var isReleaseSigned: Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(UpdateKit.teamRequirement as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(me, [], requirement) == errSecSuccess
    }

    // MARK: disk image

    /// The app's copy of the download, read through the file handle it sent (the app's own files are in its sandbox).
    static func copy(_ source: FileHandle, to dest: URL) throws {
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            throw UpdateFailure(.failed, "Couldn't save the download for installing.")
        }
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        try source.seek(toOffset: 0)
        while let chunk = try source.read(upToCount: 4 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
    }

    static func attach(_ image: URL) throws -> String {
        let (status, out, err) = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-noautoopen", "-readonly", "-plist", image.path])
        guard status == 0, let mount = UpdateKit.mountPoints(hdiutilPlist: out).first else {
            throw UpdateFailure(.failed, "Couldn't open the downloaded disk image (\(err.trimmed.isEmpty ? "hdiutil \(status)" : err.trimmed)).")
        }
        return mount
    }

    static func detach(_ mount: String) {
        if (try? run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]))?.status != 0 {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force", "-quiet"])
        }
    }

    /// The app at the top of the disk image, whatever its file name ("MLX Node.app" from 0.9.0, "MLX.app" before), by
    /// its bundle id (not the Applications shortcut).
    static func findApp(in volume: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        for u in items where u.pathExtension == "app" {
            if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if (try? bundleVersion(u)) != nil { return u }
        }
        throw UpdateFailure(.failed, "The download doesn't contain MLX Node.")
    }

    /// Copies an earlier update left behind (the app quit between steps), after an hour.
    static func removeLeftovers(in dir: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        for u in items where u.lastPathComponent.hasPrefix(UpdateKit.stagingPrefix) && u.pathExtension == "app" {
            let at = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(at) > 3600 { try? fm.removeItem(at: u) }
        }
    }

    // MARK: tools

    /// Run a system tool and collect what it prints (stderr on the side, so a full pipe can't stall it).
    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        let errReader = err.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errReader.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, data, String(decoding: errBox.data, as: UTF8.self))
    }

    private static var errnoText: String { String(cString: strerror(errno)) }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
