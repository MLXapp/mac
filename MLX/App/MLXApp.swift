import AppKit
import Combine
import SwiftUI

@main
struct MLXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Everything lives in the panel under the menu bar icon (PanelController); no windows.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

extension AppModel {
    static let shared = AppModel()
    var isWorking: Bool {
        if case .working = activity { return true }
        if case .calibrating = activity { return true }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController?

    private var keys: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            Task { exit(await SelfTest.run()) }
            return
        }
        keys = Self.editingKeys()
        Task { @MainActor in
            // restarted by the updater: let the old version quit first, so there's only ever one menu bar icon
            let updatedFrom = await Updater.afterUpdate()
            let updated = updatedFrom.map { UpdateKit.isNewer(SystemInfo.appVersion, than: $0) } ?? false
            let m = AppModel.shared
            let p = PanelController(model: m)
            panel = p
            WalletNews.shared.onOpen = { [weak p] in
                m.openWallet()
                p?.show()
            }
            m.start()
            if updated { m.updater.showUpdated(SystemInfo.appVersion) }
            // first run (or not finished setting up): open the panel on the setup steps; after an update, back
            // where the owner pressed Update, now saying it's done
            try? await Task.sleep(for: .milliseconds(900))
            if m.phase != .ready || m.setupOpen || updated { p.show() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in panel?.show() }
    }

    /// ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z and ⇧⌘Z in the panel (the wallet, the invite code). A menu bar app has no Edit
    /// menu on screen, so these go straight to whatever has focus.
    private static func editingKeys() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            guard mods == .command || mods == [.command, .shift] else { return e }
            // the typed letter; with a non-Latin input source (Korean, Russian…) fall back to the key's
            // position on a US keyboard, as the system's own shortcuts do
            var k = e.charactersIgnoringModifiers?.lowercased() ?? ""
            if !(k.count == 1 && k.first!.isASCII) {
                let us: [UInt16: String] = [8: "c", 9: "v", 7: "x", 0: "a", 6: "z"]
                k = us[e.keyCode] ?? ""
            }
            let action: Selector?
            switch (k, mods.contains(.shift)) {
            case ("c", false): action = #selector(NSText.copy(_:))
            case ("v", false): action = #selector(NSText.paste(_:))
            case ("x", false): action = #selector(NSText.cut(_:))
            case ("a", false): action = #selector(NSText.selectAll(_:))
            case ("z", false): action = Selector(("undo:"))
            case ("z", true): action = Selector(("redo:"))
            default: action = nil
            }
            guard let action else { return e }
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : e
        }
    }
}

/// The menu bar icon and its panel: an NSPopover hosting the SwiftUI panel, so the app can open it
/// itself (first run, mlx:// links) and it resizes smoothly as screens change.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        super.init()
        let host = NSHostingController(rootView: PanelView().environmentObject(model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        if let b = item.button {
            b.image = BrandMark.menuIcon(running: false)
            b.setAccessibilityLabel("MLX")
            b.target = self
            b.action = #selector(toggle)
        }
        // a passkey prompt is up: keep the panel open under it, then close on outside clicks again
        WalletBrowser.shared.$authActive
            .removeDuplicates()
            .sink { [weak self] on in self?.popover.behavior = on ? .applicationDefined : .transient }
            .store(in: &bag)
        // orange while MLX is started and running (set up, online, not paused or stopped); the plain template otherwise
        model.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .map { _ in model.phase == .ready && model.online && !model.limits.paused }
            .prepend(false)
            .removeDuplicates()
            .sink { [weak self] running in self?.item.button?.image = BrandMark.menuIcon(running: running) }
            .store(in: &bag)
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    func show() {
        guard let b = item.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // typing goes to the wallet when it's the screen on show
        if AppModel.shared.screen == .wallet { popover.contentViewController?.view.window?.makeFirstResponder(WalletBrowser.shared.view) }
    }

    func popoverDidClose(_ notification: Notification) {
        // back to the main screen next time, unless setup is still in progress
        let m = AppModel.shared
        if m.screen == .feedback || m.screen == .settings { m.go(.home) }
    }
}
