import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// Updates MLX Node in place when mlx.app offers a newer public build (`latest` in the heartbeat). Nothing happens
/// until the owner presses Update in the panel; then it downloads the notarized disk image, hands it to the
/// installer service inside the app (MLXUpdater.xpc: mounts it, checks the Developer ID signature and the
/// version, copies the app next to this one), stops any work, swaps the new version in and restarts MLX Node.
/// Where MLX Node can't replace itself (a folder it may not write, or a copy macOS translocated), the disk image is
/// saved to Downloads and opened in Finder instead.
///
/// The app's file name changed in 0.9.0 ("MLX.app" → "MLX Node.app"); see `moveToCurrentName` for how older installs
/// get the new name.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case verifying
        case installing
        case readyToRelaunch
        /// Couldn't replace itself: the disk image is open in Finder; the message says what to do.
        case manual(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The version being installed (kept while the card shows it, even if mlx.app stops offering it).
    @Published private(set) var version: String?
    /// The version now running, on the first launch after an update (shown for a moment in the panel).
    @Published private(set) var justUpdated: String?

    var busy: Bool {
        switch state {
        case .downloading, .verifying, .installing, .readyToRelaunch: return true
        case .idle, .manual, .failed: return false
        }
    }

    private var download: URLSessionDownloadTask?
    private var job: Task<Void, Never>?

    /// Download page, for when updating in place doesn't work.
    static let browserPage = URL(string: "https://mlx.app/download")!
    /// Set just before the restart, read by the new instance (see `afterUpdate`).
    static let relaunchKey = "updateRelaunch"

    /// What the instance before a restart left for the new one.
    struct Restart {
        /// The version that was running before the update.
        let from: String
        /// Where the app was before it took its new name (only on the restart that renamed it).
        let movedFrom: String?
        /// Whether "Open MLX Node when you log in" was on before the rename.
        let loginItem: Bool
    }

    // MARK: update

    /// Download, check, install and restart into `newVersion`. The owner asked for it (the Update button).
    func update(to newVersion: String, size: Int?, model: AppModel) {
        guard !busy else { return }
        version = newVersion
        state = .downloading(0)
        job = Task { await run(size: size, model: model) }
    }

    private func run(size: Int?, model: AppModel) async {
        let fm = FileManager.default
        let from = SystemInfo.appVersion
        let work = fm.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)", isDirectory: true)
        let dmg = work.appendingPathComponent(UpdateKit.dmgName(version ?? "new"))
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try await fetch(to: dmg, size: size)
            let target = Bundle.main.bundleURL
            if let why = Self.cannotReplace(target) {
                manual(dmg, why)
                return
            }

            state = .verifying
            let service = UpdaterClient()
            defer { service.close() }
            let prepared = try await service.prepare(dmg: dmg, target: target.path)
            version = prepared.version

            // the job running now lets go of the GPU within a tenth of a second; nothing new starts
            state = .installing
            await model.stopForUpdate()
            do {
                try await service.install(staged: prepared.staged, target: target.path)
            } catch {
                await service.discard(staged: prepared.staged, target: target.path)
                model.resumeAfterUpdate()
                throw error
            }

            state = .readyToRelaunch
            try? fm.removeItem(at: work)
            try? await Task.sleep(for: .milliseconds(600))
            relaunch(target, from: from)
        } catch let e as UpdateFailure where e.code == .notWritable {
            manual(dmg, e.message)
        } catch let e as UpdateFailure {
            state = .failed(e.message)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// The public build from mlx.app (a 15-minute link to the notarized disk image), with progress.
    private func fetch(to dest: URL, size: Int?) async throws {
        var c = URLComponents(url: API.baseURL.appendingPathComponent("api/download/mac"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "via", value: "app")]
        let url = c.url!
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleProgress(size: size)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            poll.cancel()
            download = nil
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = Self.session.downloadTask(with: url) { tmp, response, error in
                // the file at `tmp` is gone once this returns, so it's moved here
                do {
                    if let error { throw error }
                    guard let tmp, let http = response as? HTTPURLResponse else { throw UpdateFailure(.failed, "mlx.app didn't answer.") }
                    guard http.statusCode == 200 else { throw UpdateFailure(.failed, "mlx.app answered \(http.statusCode).") }
                    // no public build right now: mlx.app sends its download page instead of a disk image
                    if http.mimeType?.hasPrefix("text/") == true {
                        throw UpdateFailure(.failed, "There's no public download right now. Try again in a little while.")
                    }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            download = task
            task.resume()
        }
        setProgress(1)
    }

    private func sampleProgress(size: Int?) {
        guard let t = download else { return }
        let total = t.countOfBytesExpectedToReceive > 0 ? t.countOfBytesExpectedToReceive : Int64(size ?? 0)
        guard total > 0 else { return }
        setProgress(min(1, Double(t.countOfBytesReceived) / Double(total)))
    }

    /// Whole percents only, so the panel redraws at most a hundred times.
    private func setProgress(_ p: Double) {
        guard case .downloading(let old) = state else { return }
        let q = (p * 100).rounded(.down) / 100
        if q != old { state = .downloading(q) }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 30 * 60
        c.httpAdditionalHeaders = ["User-Agent": "MLX-Mac/\(SystemInfo.appVersion) (\(SystemInfo.os)) updater"]
        return URLSession(configuration: c)
    }()

    // MARK: where MLX can't replace itself

    /// Why MLX can't replace itself where it runs, if it can't (seen from inside the sandbox; the service
    /// checks write access itself).
    static func cannotReplace(_ app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "MLX Node is running from a temporary copy macOS made of it, so it can't replace itself."
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return "MLX Node is running from its disk image, so it can't replace itself."
        }
        return nil
    }

    /// Save the disk image to Downloads and open it in Finder, so the owner can drag MLX Node to Applications.
    private func manual(_ dmg: URL, _ why: String) {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            state = .failed(why)
            return
        }
        var dest = downloads.appendingPathComponent(dmg.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("\(dmg.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970)).dmg")
        }
        do {
            try fm.moveItem(at: dmg, to: dest)
        } catch {
            state = .failed(why)
            return
        }
        NSWorkspace.shared.open(dest)
        // an install from before 0.9.0 is called MLX.app; the disk image now holds MLX Node.app, so the old copy stays
        let old = Bundle.main.bundleURL.lastPathComponent == UpdateKit.legacyAppFileName ? " You can move the old MLX to the Trash." : ""
        state = .manual("\(why) The new version is open in Finder: drag MLX Node to Applications, then open it from there.\(old)")
    }

    // MARK: restart

    /// Start the new version as a new instance, then quit. The new one waits for this one to be gone, so the
    /// menu bar never shows two icons.
    private func relaunch(_ app: URL, from: String) {
        Self.restart(app, info: ["at": Date().timeIntervalSince1970, "from": from])
    }

    /// Leave `info` for the new instance, start the app at `app` as a new instance and quit.
    private static func restart(_ app: URL, info: [String: Any]) {
        UserDefaults.standard.set(info, forKey: relaunchKey)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = false
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, error in
            Task { @MainActor in
                if error != nil { Updater.relaunchLater(app) }
                NSApp.terminate(nil)
            }
        }
    }

    /// Fallback: a shell that opens MLX Node a second after this one has quit.
    private static func relaunchLater(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", app.path]
        try? p.run()
    }

    /// On launch: if the updater just restarted MLX Node, wait (up to ten seconds) for the old version to quit and
    /// return what it left (the version it was). Called before the menu bar icon is made.
    static func afterUpdate() async -> Restart? {
        let d = UserDefaults.standard
        guard let info = d.dictionary(forKey: relaunchKey) else { return nil }
        d.removeObject(forKey: relaunchKey)
        guard let at = info["at"] as? Double, Date().timeIntervalSince1970 - at < 120, let from = info["from"] as? String else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let id = Bundle.main.bundleIdentifier ?? UpdateKit.bundleID
        for _ in 0..<100 {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me && !$0.isTerminated }
            if others.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Restart(from: from, movedFrom: info["movedFrom"] as? String, loginItem: info["loginItem"] as? Bool ?? false)
    }

    // MARK: the new name (0.9.0)

    /// An install from before 0.9.0 is called MLX.app, and the update to 0.9.0 lands there: 0.8.x's own installer
    /// swapped it in under that path, and nothing can change 0.8.x any more. So on the first launch after an update,
    /// before the menu bar icon appears, an app still called MLX.app asks its installer for one rename in the same
    /// folder ("MLX Node.app", never replacing anything, see `Installer.moveToCurrentName`) and restarts from there:
    /// the owner sees one restart, as with every update, and then MLX Node in Applications. If anything is in the
    /// way (no permission, a copy already called MLX Node.app, no answer), it carries on as MLX.app, as before; the
    /// next update tries again. Nothing that identifies the Mac changes: the bundle id, the device key in the
    /// sandbox container, settings, passkeys and the wallet link all stay. Returns true when it is restarting (the
    /// caller then does nothing more).
    static func moveToCurrentName(after r: Restart) async -> Bool {
        let fm = FileManager.default
        let here = Bundle.main.bundleURL
        guard UpdateKit.renamedPath(for: here.path, exists: { fm.fileExists(atPath: $0) }) != nil, cannotReplace(here) == nil else { return false }
        let loginItem = SMAppService.mainApp.status == .enabled
        let service = UpdaterClient()
        let reported = await service.moveToCurrentName(here.path)
        service.close()
        let expected = UpdateKit.renamedPath(for: here.path, exists: { _ in false })
        guard let to = UpdateKit.restartPath(old: here.path, new: reported ?? expected, exists: { fm.fileExists(atPath: $0) }) else { return false }
        Updater.restart(URL(fileURLWithPath: to, isDirectory: true), info: [
            "at": Date().timeIntervalSince1970, "from": r.from, "movedFrom": here.path, "loginItem": loginItem,
        ])
        return true
    }

    /// After the rename: "Open MLX Node when you log in" stays on. Registers the app at its new place only if it was
    /// on before and isn't any more (never turns it off, never asks when it's already fine).
    static func keepLoginItem(after r: Restart) {
        guard r.movedFrom != nil, r.loginItem, SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    /// "Updated to MLX Node 0.9.0" in the panel for a little while after the restart.
    func showUpdated(_ v: String) {
        withAnimation(.smooth(duration: 0.35)) { justUpdated = v }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            withAnimation(.smooth(duration: 0.35)) { self?.justUpdated = nil }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection. Try again when you're online."
            case .timedOut: return "The download timed out. Try again."
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// The app's side of the connection to MLXUpdater.xpc.
final class UpdaterClient {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(serviceName: UpdateKit.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: UpdaterProtocol.self)
        connection.resume()
    }

    func close() { connection.invalidate() }

    /// Hand the disk image over (as an open file: the service can't read inside the app's sandbox) and get the
    /// checked copy's path and version back.
    func prepare(dmg: URL, target: String) async throws -> (staged: String, version: String) {
        let handle = try FileHandle(forReadingFrom: dmg)
        defer { try? handle.close() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(staged: String, version: String), Error>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { e in
                if once.claim() { cont.resume(throwing: Self.unreachable(e)) }
            } as? UpdaterProtocol
            guard let proxy else {
                if once.claim() { cont.resume(throwing: UpdateFailure(.failed, "MLX Node couldn't start its installer.")) }
                return
            }
            proxy.prepare(handle, target: target) { staged, version, code, message in
                guard once.claim() else { return }
                if code == 0, let staged, let version {
                    cont.resume(returning: (staged, version))
                } else {
                    cont.resume(throwing: UpdateFailure(UpdateFailure.Code(rawValue: code) ?? .failed, message ?? "The update didn't install."))
                }
            }
        }
    }

    func install(staged: String, target: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { e in
                if once.claim() { cont.resume(throwing: Self.unreachable(e)) }
            } as? UpdaterProtocol
            guard let proxy else {
                if once.claim() { cont.resume(throwing: UpdateFailure(.failed, "MLX Node couldn't start its installer.")) }
                return
            }
            proxy.install(staged, target: target) { code, message in
                guard once.claim() else { return }
                if code == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: UpdateFailure(UpdateFailure.Code(rawValue: code) ?? .failed, message ?? "The update didn't install."))
                }
            }
        }
    }

    func discard(staged: String, target: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                if once.claim() { cont.resume() }
            } as? UpdaterProtocol
            guard let proxy else {
                if once.claim() { cont.resume() }
                return
            }
            proxy.discard(staged, target: target) {
                if once.claim() { cont.resume() }
            }
        }
    }

    /// The new path after giving an install from before 0.9.0 its new name, or nil if it keeps its place (or the
    /// service doesn't answer within `seconds`; the caller then looks at the disk).
    func moveToCurrentName(_ target: String, seconds: Double = 10) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if once.claim() { cont.resume(returning: nil) }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                if once.claim() { cont.resume(returning: nil) }
            } as? UpdaterProtocol
            guard let proxy else {
                if once.claim() { cont.resume(returning: nil) }
                return
            }
            proxy.moveToCurrentName(target) { path, code, _ in
                if once.claim() { cont.resume(returning: code == 0 ? path : nil) }
            }
        }
    }

    /// The service's answer, or nil if it doesn't answer within `seconds` (for the self-test).
    func ping(seconds: Double = 15) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if once.claim() { cont.resume(returning: nil) }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                if once.claim() { cont.resume(returning: nil) }
            } as? UpdaterProtocol
            guard let proxy else {
                if once.claim() { cont.resume(returning: nil) }
                return
            }
            proxy.ping { answer in
                if once.claim() { cont.resume(returning: answer) }
            }
        }
    }

    private static func unreachable(_ e: Error) -> UpdateFailure {
        UpdateFailure(.failed, "MLX Node's installer stopped answering (\(e.localizedDescription)).")
    }
}

/// Resumes a continuation once, whichever of the reply and the connection error comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
