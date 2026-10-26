import AppKit
import SwiftUI

/// MLX Node opened from its disk image (0.9.8): instead of setting up, it offers to install itself. One small
/// window (the menu bar panel needs an installed app): the app icon, "MLX Node runs from your Applications folder.",
/// Install. The copy is made by the installer service inside the app (MLXUpdater.xpc, not sandboxed): it checks the
/// Developer ID signature, copies MLX Node to /Applications (or ~/Applications), never over the same or a newer
/// version, and ejects the disk image once this copy has quit. Then the installed MLX Node opens on its panel.
@MainActor
final class InstallWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = DiskInstaller()

    func show() {
        let host = NSHostingController(rootView: InstallView(model: model))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Install MLX Node"
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: InstallView.size.width, height: InstallView.size.height))
        w.isReleasedWhenClosed = false
        w.animationBehavior = .alertPanel
        w.delegate = self
        w.center()
        window = w
        // a menu bar app has no Dock icon; while the installer is open it gets one, like any app being installed
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

/// Installing: idle → installing → opening (then this copy quits), or failed with the reason and Try again.
@MainActor
final class DiskInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case installing
        case opening
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 0…1 for the bar: eases towards 90% while the service copies (it doesn't report steps), 100% when done.
    @Published private(set) var progress: Double = 0

    /// One key per look, so the action area cross-fades between them.
    var look: String {
        switch state {
        case .idle: return "idle"
        case .installing, .opening: return "working"
        case .failed: return "failed"
        }
    }

    func install() {
        if state == .installing || state == .opening { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { progress = 0 }
        withAnimation(.smooth(duration: 0.3)) { state = .installing }
        // the bar starts moving once it has faded in, and slows as it nears 90%
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard state == .installing else { return }
            withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 9)) { progress = 0.9 }
        }
        Task { await run() }
    }

    private func run() async {
        let client = UpdaterClient()
        defer { client.close() }
        do {
            let done = try await client.installFromDisk(source: Bundle.main.bundleURL.path, eject: true)
            withAnimation(.smooth(duration: 0.45)) {
                progress = 1
                state = .opening
            }
            try? await Task.sleep(for: .milliseconds(650))
            open(URL(fileURLWithPath: done.path, isDirectory: true), previous: done.previous)
        } catch let e as UpdateFailure {
            fail(e.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        withAnimation(.smooth(duration: 0.35)) { state = .failed(message) }
    }

    /// Open the installed MLX Node on its panel and quit this copy (the disk image is ejected after).
    private func open(_ app: URL, previous: String?) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: UpdateKit.bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        let here = app.standardizedFileURL.resolvingSymlinksInPath().path
        let kept = previous.map { !UpdateKit.isNewer(SystemInfo.appVersion, than: $0) } ?? false
        let runningThere = others.contains { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == here }

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.addsToRecentItems = false
        if kept && runningThere {
            // the same or a newer MLX Node is already running from there: it just opens its panel
            cfg.createsNewApplicationInstance = false
            launch(app, cfg)
            return
        }
        Task {
            // an older MLX Node still running (its app was just replaced underneath it) quits first, so there's only
            // ever one menu bar icon; the new one also waits for it (Updater.afterUpdate)
            await Self.quit(others)
            // what the new instance reads: the version before (it shows "Updated to …" when this was an update)
            UserDefaults.standard.set(["at": Date().timeIntervalSince1970, "from": previous ?? SystemInfo.appVersion], forKey: Updater.relaunchKey)
            cfg.createsNewApplicationInstance = true
            launch(app, cfg)
        }
    }

    /// Opens `app` with the mlx:// link that shows its panel, then quits this copy.
    private func launch(_ app: URL, _ cfg: NSWorkspace.OpenConfiguration) {
        NSWorkspace.shared.open([URL(string: "mlx://open")!], withApplicationAt: app, configuration: cfg) { _, error in
            Task { @MainActor in
                if let error {
                    let folder = app.deletingLastPathComponent().path
                    self.fail("MLX Node is installed in \(folder), but it didn't open (\(error.localizedDescription)). Open it from there.")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func quit(_ apps: [NSRunningApplication]) async {
        guard !apps.isEmpty else { return }
        for a in apps { a.terminate() }
        for _ in 0..<40 where apps.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for a in apps where !a.isTerminated { a.forceTerminate() }
        try? await Task.sleep(for: .milliseconds(200))
    }
}

struct InstallView: View {
    @ObservedObject var model: DiskInstaller

    static let size = CGSize(width: 360, height: 392)

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
                .shadow(color: BrandMark.orange.opacity(0.18), radius: 18, y: 8)
                .padding(.top, 40)
            Text("Install MLX Node")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 14)
            Text("MLX Node runs from your Applications folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 0)
            // a fixed area, so the window never changes size: the button, the bar or the error fade into it
            ZStack(alignment: .top) {
                actions
                    .id(model.look)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)),
                        removal: .opacity.combined(with: .offset(y: -6))))
            }
            .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .top)
            Text("Version \(SystemInfo.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 14)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.smooth(duration: 0.3), value: model.look)
    }

    @ViewBuilder private var actions: some View {
        switch model.state {
        case .idle:
            PrimaryButton(title: "Install") { model.install() }
                .padding(.top, 8)
        case .installing, .opening:
            VStack(spacing: 10) {
                InstallBar(value: model.progress)
                    .padding(.top, 20)
                Text(model.state == .opening ? "Opening MLX Node…" : "Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.3), value: model.state)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
                PrimaryButton(title: "Try again") { model.install() }
            }
        }
    }
}

/// A thin bar in the brand gradient; its width animates, so it never jumps.
private struct InstallBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(BrandMark.gradient)
                    .frame(width: max(6, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}
