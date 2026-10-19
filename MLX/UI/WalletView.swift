import AppKit
import SwiftUI
import WebKit

/// The MLX wallet, inside the panel. It is the same wallet as wallet.mlx.app (create, restore, passkey
/// sign-in, send, receive, deposit, buy and sell, withdraw, nodes, history, security), shown in one
/// web view that lives as long as the app, so the wallet stays open while you move around the panel.
///
/// The page knows it's in the app from the user agent ("MLXMac/<version>") and drops the site's own
/// header and footer. It talks to the app through the `mlx` message handler: which wallet is open,
/// "connect this Mac", copy to the clipboard and passkey prompts (the panel stays open for those).
@MainActor
final class WalletBrowser: NSObject, ObservableObject {
    static let shared = WalletBrowser()

    @Published private(set) var loading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var url: URL?
    @Published private(set) var pageTitle = ""
    /// The wallet open in the panel (nil when locked or signed out).
    @Published private(set) var account: String?
    @Published private(set) var failed: String?
    /// True while a passkey prompt is up: the panel must not close under it.
    @Published private(set) var authActive = false
    /// A file the wallet just saved (CSV export), for the "Saved to Downloads" note.
    @Published private(set) var saved: URL?

    /// The wallet asked to connect this Mac (Macs → Connect this Mac).
    var onLinkThisMac: (() -> Void)?
    /// The wallet linked this Mac (or another) to `account`.
    var onLinked: ((String) -> Void)?

    private var web: WKWebView?
    private var watching: [NSKeyValueObservation] = []
    private var savedTimer: Task<Void, Never>?
    private var destinations: [ObjectIdentifier: URL] = [:]

    var home: URL { API.walletBaseURL }

    /// The web view, made on first use.
    var view: WKWebView { web ?? make() }

    /// True on the wallet's own page (not another mlx.app page opened from it).
    var onWallet: Bool {
        guard let u = url else { return true }
        return u.host == home.host && (home.path == "/" || u.path.hasPrefix(home.path))
    }

    /// Shows the wallet, loading it the first time.
    func ensureLoaded() {
        let v = view
        if v.url == nil, !v.isLoading { v.load(URLRequest(url: home)) }
    }

    func open(_ url: URL) {
        failed = nil
        view.load(URLRequest(url: url))
    }

    func back() { web?.goBack() }

    func reload() {
        failed = nil
        if let w = web, w.url != nil { w.reload() } else { ensureLoaded() }
    }

    func goHome() { open(home) }

    /// The wallet with its Nodes box open.
    func openNodes() {
        var c = URLComponents(url: home, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "tab", value: "nodes")]
        open(c.url ?? home)
    }

    /// For `--selftest`: the delegate methods WebKit will call, and the wallet page as the app loads it.
    static func selfTest() async -> [String] {
        var out: [String] = []
        let b = WalletBrowser.shared
        for s in ["webView:decidePolicyForNavigationAction:decisionHandler:", "webView:decidePolicyForNavigationResponse:decisionHandler:",
                  "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", "webView:navigationAction:didBecomeDownload:",
                  "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:", "downloadDidFinish:",
                  "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:", "webView:didFailProvisionalNavigation:withError:"] {
            out.append("\(s) \(b.responds(to: NSSelectorFromString(s)) ? "ok" : "MISSING")")
        }
        b.ensureLoaded()
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if !b.view.isLoading, b.view.url != nil { break }
        }
        try? await Task.sleep(for: .seconds(3))  // let the page render
        let js = "JSON.stringify({url: location.href, embed: document.documentElement.dataset.embed || null, app: !!window.__MLX_APP__, header: (function(){var h=document.querySelector('.header');return h?getComputedStyle(h).display:null})(), onboard: !!document.querySelector('#name') || !!document.querySelector('.wallet-main .glass'), webauthn: !!window.PublicKeyCredential, ua: navigator.userAgent})"
        if let r = try? await b.view.evaluateJavaScript(js) as? String { out.append("page \(r)") } else { out.append("page: no result (\(b.failed ?? "no error"))") }
        _ = try? await b.view.evaluateJavaScript("window.PublicKeyCredential && PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(function(v){ window.__pa = String(v) }, function(e){ window.__pa = 'error ' + e }); 1")
        try? await Task.sleep(for: .seconds(1))
        let pa = (try? await b.view.evaluateJavaScript("String(window.__pa)")) as? String
        out.append("platform authenticator: \(pa ?? "unknown")")
        return out
    }

    // MARK: making the web view

    private func make() -> WKWebView {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        // "MLXMac/0.6.0 macOS/26.1": the site shows the wallet without its own header, and lists this
        // Mac as "MLX for Mac · macOS 26.1" under Devices
        let v = ProcessInfo.processInfo.operatingSystemVersion
        c.applicationNameForUserAgent = "MLXMac/\(SystemInfo.appVersion) macOS/\(v.majorVersion).\(v.minorVersion)"
        c.preferences.isElementFullscreenEnabled = false
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        let uc = c.userContentController
        uc.add(WeakHandler(self), name: "mlx")
        uc.addUserScript(WKUserScript(source: Self.bridge(device: AppModel.shared.deviceID), injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: WalletPanel.width, height: 600), configuration: c)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = false
        w.setValue(false, forKey: "drawsBackground")  // the panel shows through until the page paints
        w.underPageBackgroundColor = .clear
        w.isInspectable = UserDefaults.standard.bool(forKey: "inspectWallet")
        watching = [
            w.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
            w.observe(\.isLoading, options: [.new]) { [weak self] v, _ in Task { @MainActor in self?.loading = v.isLoading } },
            w.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            w.observe(\.url, options: [.new]) { [weak self] v, _ in Task { @MainActor in self?.url = v.url } },
            w.observe(\.title, options: [.new]) { [weak self] v, _ in Task { @MainActor in self?.pageTitle = v.title ?? "" } },
        ]
        web = w
        return w
    }

    /// Runs before the page: tells it about the app and this Mac, routes clipboard writes to the Mac's
    /// pasteboard (reliable inside a menu bar app), drops the Web Share sheet (the page then copies the
    /// link instead) and reports passkey prompts so the panel stays open under them.
    private static func bridge(device: String) -> String {
        let info: [String: String] = ["version": SystemInfo.appVersion, "device": device, "name": SystemInfo.name]
        let json = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function(){
          var post = function(m){ try { window.webkit.messageHandlers.mlx.postMessage(m); } catch (e) {} };
          try { Object.defineProperty(window, '__MLX_APP__', { value: Object.freeze(\(json)), configurable: false }); } catch (e) {}
          var writeText = function(t){ post({ type: 'copy', text: String(t == null ? '' : t) }); return Promise.resolve(); };
          try {
            if (navigator.clipboard) { navigator.clipboard.writeText = writeText; }
            else { Object.defineProperty(navigator, 'clipboard', { value: { writeText: writeText }, configurable: true }); }
          } catch (e) {}
          try { Object.defineProperty(navigator, 'share', { value: undefined, configurable: true }); } catch (e) {}
          try { Object.defineProperty(navigator, 'canShare', { value: undefined, configurable: true }); } catch (e) {}
          var c = navigator.credentials;
          if (c) ['get', 'create'].forEach(function(k){
            var f = c[k] && c[k].bind(c);
            if (!f) return;
            c[k] = function(o){
              var pk = !!(o && o.publicKey);
              if (pk) post({ type: 'auth', on: true });
              var p = f(o);
              if (pk) p.then(function(){ post({ type: 'auth', on: false }); }, function(){ post({ type: 'auth', on: false }); });
              return p;
            };
          });
        })();
        """
    }

    fileprivate func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "copy":
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(body["text"] as? String ?? "", forType: .string)
        case "auth":
            authActive = body["on"] as? Bool ?? false
        case "wallet":
            account = body["name"] as? String
        case "linkThisMac":
            onLinkThisMac?()
        case "linked":
            if let a = body["account"] as? String { onLinked?(a) }
        default:
            break
        }
    }

    // MARK: where links go

    /// mlx.app pages stay in the panel; anything else opens in the browser (or the app that handles it:
    /// a Solana wallet for a `solana:` payment link, Mail for `mailto:`).
    static func staysInside(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "about", "blob", "data": return true
        case "http", "https":
            guard let h = url.host?.lowercased() else { return false }
            if h == "mlx.app" || h.hasSuffix(".mlx.app") { return true }
            // a local test server set with `defaults write app.mlx.mac apiBase …`
            return h == API.walletBaseURL.host?.lowercased()
        default: return false
        }
    }

    // MARK: downloads

    fileprivate func downloadDestination(_ name: String) -> URL? {
        // the real ~/Downloads (the app's sandbox may write there), not the container's
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent("Downloads", isDirectory: true)
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var url = dir.appendingPathComponent(clean.isEmpty ? "MLX download" : clean)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    fileprivate func didSave(_ url: URL) {
        withAnimation(.smooth(duration: 0.3)) { saved = url }
        savedTimer?.cancel()
        savedTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { self?.saved = nil }
        }
    }

    func dismissSaved() {
        savedTimer?.cancel()
        withAnimation(.smooth(duration: 0.3)) { saved = nil }
    }
}

/// Breaks the retain cycle between the content controller and the browser.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WalletBrowser?
    init(_ t: WalletBrowser) { target = t }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        // only mlx.app pages, top frame, may talk to the app
        let o = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, o.protocol == "https" || o.host == "localhost",
              let origin = URL(string: "\(o.protocol)://\(o.host)"), WalletBrowser.staysInside(origin),
              let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { target?.handle(body) }
    }
}

extension WalletBrowser: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // frames inside a page (payment widgets) load as they like; only the page itself is kept to mlx.app
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if !mainFrame || Self.staysInside(url) { return decisionHandler(.allow) }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { failed = nil }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }

    private func fail(_ error: Error) {
        let e = error as NSError
        // a link that went to the browser, a download, or a newer page replacing this one: not failures
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain", e.code == 102 || e.code == 204 { return }
        withAnimation(.smooth(duration: 0.3)) {
            failed = e.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost].contains(e.code)
                ? "You're offline. Check your connection and try again."
                : e.localizedDescription
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        authActive = false
        webView.reload()
    }

    // target=_blank and window.open: mlx.app pages open here, everything else in the browser
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if Self.staysInside(url) { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        authActive = true
        let a = NSAlert()
        a.messageText = message
        a.runModal()
        authActive = false
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        authActive = true
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let ok = a.runModal() == .alertFirstButtonReturn
        authActive = false
        completionHandler(ok)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let to = downloadDestination(suggestedFilename)
        destinations[ObjectIdentifier(download)] = to
        completionHandler(to)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let u = destinations.removeValue(forKey: ObjectIdentifier(download)) { didSave(u) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        withAnimation(.smooth(duration: 0.3)) { failed = "Couldn't save the file: \(error.localizedDescription)" }
    }
}

// MARK: - the screen

struct WalletPanel: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var b = WalletBrowser.shared

    static let width: CGFloat = 400
    /// As tall as the screen allows, up to a phone-like 760 pt.
    static var height: CGFloat {
        let h = NSScreen.main?.visibleFrame.height ?? 800
        return max(480, min(760, h - 40))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                WebHost(view: b.view)
                if let e = b.failed { failure(e).transition(.opacity) }
                progressBar
                if let s = b.saved { savedNote(s).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
        .frame(width: WalletPanel.width, height: WalletPanel.height)
        .onAppear { b.ensureLoaded() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                if b.canGoBack, !atWalletHome { b.back() } else { m.go(m.walletReturn) }
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(b.canGoBack && !atWalletHome ? "Back" : "Close the wallet")
            VStack(alignment: .leading, spacing: 0) {
                Text(b.onWallet ? "Wallet" : shortTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if b.onWallet, let a = b.account {
                    Text(a).font(.caption2).foregroundStyle(.secondary).lineLimit(1).transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: b.account)
            Spacer()
            if !b.onWallet {
                Button { b.goHome() } label: {
                    Image(systemName: "wallet.pass").font(.system(size: 13)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Back to the wallet")
                .transition(.opacity)
            }
            Menu {
                Button("Reload") { b.reload() }
                Button("Open in Browser") { NSWorkspace.shared.open(b.url ?? b.home) }
                if !b.onWallet { Button("Back to the Wallet") { b.goHome() } }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.smooth(duration: 0.3), value: b.onWallet)
    }

    /// On the wallet's first screen (no asset page or other page to go back to).
    private var atWalletHome: Bool {
        guard b.onWallet, let u = b.url else { return true }
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return !q.contains { $0.name == "asset" || $0.name == "view" }
    }

    private var shortTitle: String {
        let t = b.pageTitle.components(separatedBy: " | ").first?.components(separatedBy: " — ").first ?? ""
        return t.isEmpty ? (b.url?.host ?? "MLX") : t
    }

    private var progressBar: some View {
        GeometryReader { g in
            Capsule()
                .fill(BrandMark.gradient)
                .frame(width: max(0, g.size.width * b.progress), height: 2)
                .opacity(b.loading ? 1 : 0)
                .animation(.smooth(duration: 0.25), value: b.progress)
                .animation(.easeOut(duration: 0.4).delay(b.loading ? 0 : 0.2), value: b.loading)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private func failure(_ e: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(e).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Try again") { b.reload() }.controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func savedNote(_ url: URL) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved to Downloads").font(.system(size: 12, weight: .semibold))
                    Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Show") {
                    b.dismissSaved()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(12)
        }
    }
}

/// Hosts the one wallet web view; it moves between hosts as the panel changes screens.
private struct WebHost: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        attach(to: box)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        if view.superview !== box { attach(to: box) }
    }

    static func dismantleNSView(_ box: NSView, coordinator: ()) {
        for v in box.subviews { v.removeFromSuperview() }
    }

    private func attach(to box: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            view.topAnchor.constraint(equalTo: box.topAnchor),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }
}
