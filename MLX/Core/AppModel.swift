import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// Everything the app knows and does. The scheduler checks every few seconds whether the Mac is
/// idle, plugged in and cool; then it runs one test job at a time, watching ten times a second for
/// the owner to come back, and stops at once when they do.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case starting, needsInvite, needsLink, ready, failed(String) }
    enum Activity: Equatable {
        case waiting(String)
        case paused
        case downloading(String, Double)
        case working(String, Int)
        case calibrating(Double)
    }
    struct Recent: Identifiable, Codable, Equatable {
        var id = UUID()
        let job: String
        let model: String
        let tokens: Int
        let tokPerSec: Double
        let stop: String
        let at: Date
    }
    struct Calibration: Codable, Equatable { let tokPerSec: Double; let model: String; let at: Date }

    /// What the panel shows. Everything lives in the one panel under the menu bar icon.
    enum Screen: Hashable { case home, settings, feedback, connect, invite, wallet }
    /// First-run steps, shown in the panel until the Mac is set up.
    enum SetupStep: Int, CaseIterable { case welcome, invite, connect, limits, measure, done }
    /// Connecting this Mac to a wallet in the browser.
    enum ConnectState: Equatable { case idle, waiting, done(String), failed(String) }

    @Published private(set) var screen: Screen = .home
    /// Slide direction for the next screen change.
    @Published private(set) var forward = true
    @Published private(set) var setupStep: SetupStep = .welcome
    /// True while the first-run steps are on screen (they stay up for limits and the speed test).
    @Published private(set) var setupOpen = false
    @Published private(set) var connectState: ConnectState = .idle
    /// Where the wallet's back button goes: the screen that opened it.
    @Published private(set) var walletReturn: Screen = .home
    /// The current connect request went to the browser (not the wallet in the panel).
    @Published private(set) var connectInBrowser = false
    private var connectTask: Task<Void, Never>?
    private var reRedeemed = false

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var activity: Activity = .waiting("Starting…")
    @Published private(set) var account: String?
    @Published private(set) var jobsAllowed = false
    @Published private(set) var latest: HelloReply.Latest?
    /// MLX this Mac's wallet has earned for compute (from the last heartbeat).
    @Published private(set) var earning: HelloReply.Earning?
    @Published private(set) var recent: [Recent] = []
    @Published private(set) var calibration: Calibration?
    @Published private(set) var lastError: String?
    @Published private(set) var stopTimes: [Int] = []
    @Published private(set) var online = true
    @Published private(set) var today = DayStats.load()
    /// The model of the job running now (or last run), as shown in the menu: "Qwen2.5 0.5B · 4-bit".
    @Published private(set) var currentModel: String?
    /// Live speed, samples and token count for the menu, published apart so they don't redraw everything.
    let live = LiveStats()
    @Published var limits: Limits = .load() {
        didSet {
            guard limits != oldValue else { return }
            limits.save()
            if limits.paused != oldValue.paused { Task { await heartbeat() } }
        }
    }

    private(set) var inviteCode: String? {
        get { UserDefaults.standard.string(forKey: "invite") }
        set { UserDefaults.standard.set(newValue, forKey: "invite") }
    }
    var walletName: String {
        get { UserDefaults.standard.string(forKey: "wallet") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "wallet") }
    }

    private(set) var key: DeviceKey?
    private var api: API?
    let worker = Worker()
    /// Updating MLX in place (the Update button in the panel).
    let updater = Updater()
    /// Set while an update installs: no new work starts and the running job lets go at once.
    private var stopping = false
    private var wakeObserver: NSObjectProtocol?
    private var calibrationSpec: CalibrationSpec?
    private var noJobsUntil = Date.distantPast
    private var busy = false
    private var loops: [Task<Void, Never>] = []
    private var lastHello = Date.distantPast
    /// Commands from the phone carried out but not yet acknowledged to mlx.app.
    private var acks: [String] = []

    var deviceID: String { key?.publicKeyHex ?? "" }
    var isBeta: Bool { true }

    // MARK: start

    func start() {
        guard key == nil else { return }
        guard SystemInfo.isAppleSilicon else {
            phase = .failed("MLX Node needs a Mac with Apple Silicon (M1 or later).")
            return
        }
        do {
            let k = try DeviceKey.loadOrCreate()
            key = k
            api = API(key: k)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        if let d = UserDefaults.standard.data(forKey: "recent"), let r = try? JSONDecoder().decode([Recent].self, from: d) { recent = r }
        if let d = UserDefaults.standard.data(forKey: "calibration"), let c = try? JSONDecoder().decode(Calibration.self, from: d) { calibration = c }
        stopTimes = UserDefaults.standard.array(forKey: "stops") as? [Int] ?? []
        let wallet = WalletBrowser.shared
        wallet.onLinkThisMac = { [weak self] in self?.connect() }
        Task {
            await refreshPhase()
            await heartbeat()
            if phase != .ready {
                setupStep = .welcome
                setupOpen = true
            }
        }
        // after sleep the next heartbeat (and a newer version, if there is one) shouldn't wait for the minute
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.heartbeatAfterWake() }
        }
        loops = [
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await self?.heartbeat()
                    // wallet news for the wallet open in the panel, else the one this Mac works for
                    await WalletNews.shared.check(account: WalletBrowser.shared.account ?? self?.account)
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tick()
                    try? await Task.sleep(for: .seconds(4))
                }
            },
            Task { [weak self] in
                // sample the worker's live counter ten times a second
                while !Task.isCancelled {
                    guard let self else { return }
                    self.live.update(self.worker.live.snapshot(), now: ProcessInfo.processInfo.systemUptime)
                    if self.today.day != DayStats.key(for: Date()) { self.today = self.today.current() }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            },
        ]
    }

    func refreshPhase() async {
        guard let api else { return }
        // since the public release no invite is needed: a Mac works once it's linked to a wallet
        do {
            let o = try await api.owner()
            online = true
            account = o.account
            phase = o.linked ? .ready : .needsLink
        } catch {
            online = false
            if phase == .starting { phase = account == nil ? .needsLink : .ready }
        }
    }

    // MARK: invite + link

    func redeem(_ raw: String) async -> String? {
        guard let api else { return "Not ready" }
        let code = raw.uppercased().replacingOccurrences(of: " ", with: "")
        struct Body: Encodable { let code: String }
        do {
            _ = try await api.post("api/worker/redeem", Body(code: code), as: OK.self)
            inviteCode = code
            await refreshPhase()
            await heartbeat()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Connect this Mac to a wallet: the wallet opens right here in the panel (or in the browser, if
    /// asked) with an open request from this Mac. The owner signs in or creates a wallet, confirms it's
    /// them and approves; this notices on its own and goes back to where it started.
    func connect(inBrowser: Bool = false) {
        guard let api else { return }
        connectTask?.cancel()
        connectState = .waiting
        connectInBrowser = inBrowser
        // where to come back to: the setup step, Settings → Wallet, or the wallet itself (Macs sheet)
        let origin: Screen = screen == .wallet ? walletReturn : screen
        let fromWallet = screen == .wallet
        connectTask = Task {
            let before = (try? await api.owner())?.at ?? 0
            do {
                let url = try await api.linkURL(account: Signing.anyWallet)
                if inBrowser {
                    NSWorkspace.shared.open(url)
                } else {
                    WalletBrowser.shared.open(url)
                    if !fromWallet { openWallet(returnTo: origin, load: false) }
                }
            } catch {
                connectState = .failed(error.localizedDescription)
                return
            }
            for _ in 0..<450 {  // 15 minutes, then the request has expired anyway
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                if let o = try? await api.owner(), o.linked, let a = o.account, (o.at ?? 0) > before {
                    await linked(a, origin: fromWallet ? nil : origin)
                    return
                }
            }
            connectState = .failed("Still waiting for your wallet. Connect again and approve this Mac in the wallet.")
        }
    }

    /// The wallet linked this Mac to `a`. Coming from setup or Settings, the panel lets the wallet's
    /// "Mac linked" show for a moment, then slides back there; from the wallet's own Macs sheet it stays.
    private func linked(_ a: String, origin: Screen?) async {
        account = a
        walletName = a
        phase = .ready
        withAnimation(.smooth(duration: 0.4)) { connectState = .done(a) }
        await heartbeat()
        guard let origin, screen == .wallet else { return }
        try? await Task.sleep(for: .seconds(1.6))
        if screen == .wallet { go(origin) }
    }

    /// Show the wallet in the panel.
    func openWallet(returnTo: Screen? = nil, load: Bool = true) {
        if load { WalletBrowser.shared.ensureLoaded() }
        walletReturn = returnTo ?? (screen == .wallet ? walletReturn : screen)
        go(.wallet)
    }

    /// The wallet in the panel, scrolled to its nodes.
    func openNodes() {
        WalletBrowser.shared.openNodes()
        openWallet(load: false)
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectState = .idle
    }

    // MARK: navigation

    func go(_ s: Screen) {
        // deeper screens slide in from the right; going back slides the other way
        forward = Self.depth(s) > Self.depth(screen)
        // Settings → Wallet starts fresh; coming back from the wallet keeps "Connected to …"
        if s == .connect, screen == .settings, case .done = connectState { connectState = .idle }
        withAnimation(.smooth(duration: 0.38)) { screen = s }
    }

    private static func depth(_ s: Screen) -> Int {
        switch s {
        case .home: return 0
        case .settings, .feedback: return 1
        case .connect, .invite: return 2
        case .wallet: return 3
        }
    }

    func setupGo(_ s: SetupStep) {
        forward = s.rawValue > setupStep.rawValue
        withAnimation(.smooth(duration: 0.4)) {
            setupStep = s
            setupOpen = true
        }
    }

    func finishSetup() {
        forward = true
        withAnimation(.smooth(duration: 0.4)) { setupOpen = false }
    }

    /// Start or stop (manual mode), pause or resume (idle mode).
    func toggleRunning() {
        limits.paused.toggle()
    }

    // MARK: heartbeat

    func heartbeat() async {
        guard let api else { return }
        lastHello = Date()
        let (state, reason): (String, String) = {
            switch activity {
            case .paused: return ("paused", "Paused")
            case .waiting(let r): return ("idle-waiting", r)
            case .downloading: return ("downloading", "")
            case .working(let j, _): return ("working", j)
            case .calibrating: return ("calibrating", "")
            }
        }()
        let s = stopTimes.sorted()
        let day = today.current()
        var body = HelloBody(
            app: SystemInfo.appVersion, os: SystemInfo.os, chip: SystemInfo.chip, memoryGB: SystemInfo.memoryGB, cores: SystemInfo.cores,
            state: state, reason: String(reason.prefix(80)), thermal: SystemInfo.thermal, onAC: SystemInfo.onAC, limits: limits,
            calibration: calibration.map { HelloBody.Calibration(tokPerSec: $0.tokPerSec, model: $0.model) },
            stops: .init(count: s.count, p50: s.isEmpty ? 0 : s[s.count / 2], max: s.last ?? 0))
        body.ack = acks
        body.today = .init(jobs: day.jobs, tokens: day.tokens, passRate: day.passRate)
        body.tps = (live.tokPerSec * 10).rounded() / 10
        let sentAcks = acks
        do {
            let r = try await api.post("api/worker/hello", body, as: HelloReply.self)
            online = true
            acks.removeAll { sentAcks.contains($0) }
            if let cmds = r.commands, !cmds.isEmpty { apply(cmds) }
            jobsAllowed = r.jobs
            if r.earning != earning { withAnimation(.smooth(duration: 0.4)) { earning = r.earning } }
            if let a = r.account { account = a }
            if r.account == nil, phase == .ready { phase = .needsLink }
            // a new device key (0.5 moved it out of the Keychain) needs the saved invite redeemed again
            if !r.invited, let code = inviteCode, !reRedeemed {
                reRedeemed = true
                _ = await redeem(code)
            }
            calibrationSpec = r.calibration
            // a newer public build slides the update card in
            if r.latest != latest { withAnimation(.smooth(duration: 0.35)) { latest = r.latest } }
        } catch {
            online = false
        }
    }

    /// The network takes a few seconds to come back after sleep: try at 3, 10 and 30 seconds until mlx.app answers.
    private func heartbeatAfterWake() async {
        for delay in [3, 10, 30] {
            try? await Task.sleep(for: .seconds(delay))
            await heartbeat()
            if online { return }
        }
    }

    // MARK: commands from the phone

    /// Pause, resume or new limits sent from MLX.app on the owner's iPhone or iPad. Acknowledged with the next
    /// heartbeat, which comes a few seconds later so the phone sees the change quickly.
    private func apply(_ cmds: [HelloReply.Command]) {
        var l = limits
        for c in cmds where !acks.contains(c.id) {
            switch c.action {
            case "pause": l.paused = true
            case "resume": l.paused = false
            case "limits":
                if let r = c.limits {
                    if let v = r.idleMinutes { l.idleMinutes = Int(v) }
                    if let v = r.memoryPct { l.memoryPct = Int(v) }
                    if let v = r.hoursFrom { l.hoursFrom = Int(v) }
                    if let v = r.hoursTo { l.hoursTo = Int(v) }
                    if let v = r.onlyOnAC { l.onlyOnAC = v }
                    if let v = r.maxThermal { l.maxThermal = v }
                    if let v = r.paused { l.paused = v }
                }
            default: break
            }
            acks.append(c.id)
        }
        l = l.clamped()
        if l != limits { withAnimation(.smooth(duration: 0.35)) { limits = l } }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.heartbeat()
        }
    }

    // MARK: scheduler

    private func tick() async {
        guard phase == .ready, !busy, !stopping else { return }
        let c = SystemInfo.conditions()
        let r = Policy.readiness(c, limits)
        if limits.paused {
            setActivity(.paused)
            return
        }
        guard r.ok else {
            setActivity(.waiting(r.reason))
            return
        }
        guard jobsAllowed else {
            setActivity(.waiting(online ? "Waiting for mlx.app" : "Offline"))
            return
        }
        guard Date() >= noJobsUntil else {
            setActivity(.waiting("No work right now"))
            return
        }
        await runOneJob()
    }

    private func setActivity(_ a: Activity) {
        if a != activity { activity = a }
    }

    private func runOneJob() async {
        guard let api else { return }
        busy = true
        defer { busy = false }
        struct Ask: Encodable { let memoryGB: Int }
        let reply: JobReply
        do {
            reply = try await api.post("api/worker/job", Ask(memoryGB: SystemInfo.memoryGB), as: JobReply.self)
        } catch {
            online = false
            lastError = error.localizedDescription
            return
        }
        guard let job = reply.job else {
            noJobsUntil = Date().addingTimeInterval(15 * 60)
            setActivity(.waiting(reply.reason ?? "No jobs right now"))
            return
        }
        await worker.setMemoryShare(limits.memoryPct)
        // download and load, stopping if the owner comes back
        if await worker.loadedModel != job.modelId {
            setActivity(.downloading(job.model, 0))
            let load = Task { [worker] in
                try await worker.load(job.modelId) { p in Task { @MainActor in self.updateDownload(job.model, p) } }
            }
            if await watch(load) != nil {
                await worker.unload()
                return
            }
            if case .failure(let e) = await load.result {
                lastError = "Couldn't load \(job.model): \(e.localizedDescription)"
                noJobsUntil = Date().addingTimeInterval(10 * 60)
                return
            }
        }
        currentModel = AppModel.display(id: job.modelId)
        setActivity(.working(job.id, 0))
        let run = Task { [worker] in try await worker.run(prompt: job.prompt, maxTokens: job.maxTokens) }
        let stopped = await watch(run)
        let result = await run.result
        if let stopped {
            // time from the owner's first touch to the job letting go of the GPU
            let ms = Int(Date().timeIntervalSince(stopped.since) * 1000)
            if stopped.byOwner { recordStop(ms) }
            await worker.unload()
            setActivity(.waiting(stopped.reason))
        }
        switch result {
        case .success(let out):
            let body = ResultBody(job: job.id, outHash: out.outHash, tokens: out.tokens.count, promptTokens: out.promptTokens, tokPerSec: out.tokPerSec, ttftMs: out.ttftMs, ms: out.ms, stop: stopped == nil ? out.stop : "cancelled", text: out.text)
            let reply = try? await api.post("api/worker/result", body, as: ResultReply.self)
            if body.stop != "cancelled" {
                // a result counts as checked only when mlx.app compared it with other Macs' answers to the same job
                // (`match`); a result that was only received is not a passed check
                let match = reply?.match
                today.record(tokens: out.tokens.count, checked: match != nil, passed: match == true)
                today.save()
            }
            let rec = Recent(job: job.id, model: job.model, tokens: out.tokens.count, tokPerSec: out.tokPerSec, stop: body.stop, at: Date())
            recent = Array(([rec] + recent).prefix(20))
            if let d = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(d, forKey: "recent") }
            lastError = nil
        case .failure(let e):
            if stopped == nil { lastError = e.localizedDescription }
        }
    }

    private func updateDownload(_ model: String, _ p: Double) {
        if case .downloading = activity { activity = .downloading(model, p) }
    }

    struct Stopped { let reason: String; let since: Date; let byOwner: Bool }

    /// Watch a running task ten times a second; cancel it the moment work must stop.
    private func watch<T: Sendable>(_ task: Task<T, Error>) async -> Stopped? {
        let done = DoneFlag()
        Task { _ = await task.result; await done.set() }
        while !(await done.value) {
            if stopping {
                task.cancel()
                return Stopped(reason: "Updating MLX Node", since: Date(), byOwner: false)
            }
            let c = SystemInfo.conditions()
            if let why = Policy.mustStop(c, limits) {
                let byOwner = c.idleSeconds < 1.0
                task.cancel()
                return Stopped(reason: why, since: byOwner ? Date().addingTimeInterval(-c.idleSeconds) : Date(), byOwner: byOwner)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func recordStop(_ ms: Int) {
        stopTimes = Array((stopTimes + [ms]).suffix(50))
        UserDefaults.standard.set(stopTimes, forKey: "stops")
    }

    // MARK: calibration

    /// A fixed run on the smallest model to measure this Mac (asked for by the owner, so it runs now).
    func calibrate() async -> String? {
        guard !busy, !stopping else { return "MLX Node is busy. Try again in a moment." }
        busy = true
        defer { busy = false }
        let spec = calibrationSpec ?? CalibrationSpec(modelId: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", prompt: "Write a short story of about 200 words about a lighthouse keeper who learns to code.", maxTokens: 256)
        await worker.setMemoryShare(limits.memoryPct)
        currentModel = AppModel.display(id: spec.modelId)
        setActivity(.calibrating(0))
        do {
            try await worker.load(spec.modelId) { p in Task { @MainActor in self.activity = .calibrating(p * 0.6) } }
            setActivity(.calibrating(0.7))
            let out = try await worker.run(prompt: spec.prompt, maxTokens: spec.maxTokens)
            await worker.unload()
            let c = Calibration(tokPerSec: out.tokPerSec, model: spec.modelId.components(separatedBy: "/").last ?? spec.modelId, at: Date())
            calibration = c
            if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: "calibration") }
            setActivity(.waiting("Ready"))
            await heartbeat()
            return nil
        } catch {
            await worker.unload()
            setActivity(.waiting("Ready"))
            return error.localizedDescription
        }
    }

    // MARK: feedback

    func sendFeedback(_ text: String, diagnostics: Bool) async -> String? {
        guard let api else { return "Not ready" }
        struct Body: Encodable { let text: String; let diagnostics: [String: String]? }
        var d: [String: String]? = nil
        if diagnostics {
            let s = stopTimes.sorted()
            d = [
                "app": SystemInfo.appVersion, "os": SystemInfo.os, "chip": SystemInfo.chip, "memoryGB": "\(SystemInfo.memoryGB)",
                "thermal": SystemInfo.thermal, "onAC": "\(SystemInfo.onAC)", "activity": "\(activity)", "limits": "\(limits)",
                "stopsMs": s.map(String.init).joined(separator: ","), "lastError": lastError ?? "", "key": key?.kind.rawValue ?? "",
            ]
        }
        do {
            _ = try await api.post("api/worker/feedback", Body(text: text, diagnostics: d), as: OK.self)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: misc

    /// "mlx-community/Llama-3.2-1B-Instruct-4bit" → "Llama 3.2 1B · 4-bit".
    nonisolated static func display(id: String) -> String {
        var base = id.components(separatedBy: "/").last ?? id
        var bits: String?
        for b in ["3", "4", "6", "8"] where base.lowercased().hasSuffix("-\(b)bit") {
            bits = "\(b)-bit"
            base = String(base.dropLast(5))
        }
        for word in ["-Instruct", "-Chat", "-it"] where base.hasSuffix(word) { base = String(base.dropLast(word.count)) }
        base = base.replacingOccurrences(of: "-", with: " ")
        return bits.map { "\(base) · \($0)" } ?? base
    }

    var updateAvailable: Bool {
        guard let v = latest?.version else { return false }
        return UpdateKit.isNewer(v, than: SystemInfo.appVersion)
    }

    /// Before the new version is swapped in: start nothing new, stop the job running now (it lets go of the GPU
    /// within a tenth of a second, as when the owner comes back) and free the model's memory.
    func stopForUpdate() async {
        stopping = true
        setActivity(.waiting("Updating MLX Node"))
        var waited = 0
        while busy && waited < 80 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        await worker.unload()
    }

    /// The update didn't install: carry on working.
    func resumeAfterUpdate() {
        stopping = false
        setActivity(.waiting("Ready"))
    }

    var invitePage: URL {
        var c = URLComponents(string: "https://mlx.app/beta")!
        if let code = inviteCode { c.queryItems = [URLQueryItem(name: "code", value: code)] }
        return c.url!
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { lastError = error.localizedDescription }
            objectWillChange.send()
        }
    }

    /// Remove the beta invite from this Mac (Settings). Work goes on: invites are no longer needed.
    func forgetInvite() {
        inviteCode = nil
        reRedeemed = true
        Task { await heartbeat() }
    }

    var currentInvite: String? { inviteCode }
}

private actor DoneFlag {
    var value = false
    func set() { value = true }
}

/// The menu's live numbers: speed now, the last 30 seconds of speed, tokens produced, and whether
/// the compute grid still has cells fading. Updated ten times a second; publishes only on change.
@MainActor
final class LiveStats: ObservableObject {
    static let sampleCount = 60
    static let sampleInterval: TimeInterval = 0.5

    @Published private(set) var tokPerSec: Double = 0
    @Published private(set) var phase: LiveCounter.Phase = .idle
    @Published private(set) var samples = [Double](repeating: 0, count: LiveStats.sampleCount)
    /// True while generating and for a moment after, so the grid can finish fading.
    @Published private(set) var animating = false
    /// Uptime of the newest sample; the sparkline scrolls continuously between samples.
    private(set) var lastSampleAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var idleSince: TimeInterval = 0

    var flat: Bool { tokPerSec == 0 && samples.allSatisfy { $0 == 0 } }

    func update(_ s: LiveCounter.Snapshot, now: TimeInterval) {
        let r = (s.tokPerSec * 10).rounded() / 10
        if r != tokPerSec { tokPerSec = r }
        if s.phase != phase {
            if s.phase == .idle { idleSince = now }
            phase = s.phase
        }
        let a = phase != .idle || now - idleSince < 1.2
        if a != animating { animating = a }
        if now - lastSampleAt >= LiveStats.sampleInterval {
            if !flat {
                var next = samples
                next.removeFirst()
                next.append(r)
                samples = next
            }
            lastSampleAt = now
        }
    }
}
