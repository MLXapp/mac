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
    enum Screen: Hashable { case home, settings, feedback, connect, invite, wallet, upgrade }
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
    /// mlx.app gives this Mac (a free seat) AI jobs now and then and said when to ask again: until then the Mac is ready
    /// and waiting, which the network counts as mining, and the panel says "Waiting for the next AI job".
    @Published private(set) var waitingForJob = false
    /// Live speed, samples and token count for the menu, published apart so they don't redraw everything.
    let live = LiveStats()
    @Published var limits: Limits = .load() {
        didSet {
            guard limits != oldValue else { return }
            limits.save()
            if limits.paused != oldValue.paused { Task { await heartbeat() } }
        }
    }
    /// Stepping aside for MLX Harness (mlx://yield): no new network jobs until it ends on its own or is resumed. Apart
    /// from the owner's pause (`limits.paused`), which it never changes.
    @Published private(set) var yielding: YieldState = .load()
    /// True while MLX Node steps aside for MLX Harness.
    var isYielded: Bool { yielding.isActive(at: Date()) }

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
    /// What the panel says while there's no job and none is asked for (mlx.app's reason, without its full stop).
    private var noJobsReason = "No work right now"
    /// Seconds between heartbeats: mlx.app's `next` (10 s while commands from the phone are waiting), 10 to 120.
    private var helloEvery: Double = 60
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
                    try? await Task.sleep(for: .seconds(self?.helloEvery ?? 60))
                    await self?.heartbeat()
                    // wallet news for the wallet open in the panel, else the one this Mac works for
                    await WalletNews.shared.check(account: WalletBrowser.shared.account ?? self?.account)
                    // witness the MLX ledger: check the newest checkpoint and cosign it (every ten minutes)
                    if let api = self?.api { await Witness.shared.tick(api: api) }
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
                    self.live.update(self.worker.live.snapshot(), peak: self.worker.live.takePeak(), now: ProcessInfo.processInfo.systemUptime)
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

    /// The wallet in the panel, buying the seat `tier` (the wallet pays from its balance or opens the crypto checkout).
    /// Its back button returns to the screen that opened it (the upgrade screen).
    func openBuy(tier: String) {
        WalletBrowser.shared.openBuy(tier: tier)
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
        // leaving the wallet (perhaps with a seat just bought): ask mlx.app now, so the panel shows the new seat at once
        let fromWallet = screen == .wallet && s != .wallet
        withAnimation(.smooth(duration: 0.38)) { screen = s }
        if fromWallet { Task { await heartbeat() } }
    }

    private static func depth(_ s: Screen) -> Int {
        switch s {
        case .home: return 0
        case .settings, .upgrade: return 1
        case .feedback, .connect, .invite: return 2
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

    /// Setup always ends running (23 Oct 2026: "new devices enter in started mode instead of paused"), even on a
    /// Mac that kept a paused setting from an earlier install.
    func finishSetup() {
        if limits.paused { limits.paused = false }
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
            // stepping aside for MLX Harness reports as paused: the Mac does no network work then, so it isn't
            // eligible to mine (lib/compute/rewards.ts `eligible`), and MLX World and the phone show it as paused
            case .paused: return ("paused", isYielded && !limits.paused ? AppModel.yieldReason : "Paused")
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
            if let n = r.next { helloEvery = Double(min(max(n, 10), 120)) }
            if r.earning != earning { withAnimation(.smooth(duration: 0.4)) { earning = r.earning } }
            // the chart hums on a dedicated seat and beats like a heart on a free one (it eases between the two)
            live.steady = r.earning?.isThrottled == false
            // a dedicated seat now (just bought, or moved to this Mac): AI jobs come non-stop, so stop waiting at once
            if r.earning?.isThrottled == false, waitingForJob {
                noJobsUntil = .distantPast
                withAnimation(.smooth(duration: 0.35)) { waitingForJob = false }
            }
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
            case "resume":
                l.paused = false
                // the owner pressed Resume on the phone, which shows a yielded Mac as paused: carry on now
                endYield()
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

    // MARK: stepping aside for MLX Harness

    /// What the panel and the heartbeat say while MLX Node steps aside.
    nonisolated static let yieldReason = "Paused for MLX Harness"

    /// mlx://yield?by=harness&minutes=N: MLX Harness runs a model on this Mac. No new network jobs for N minutes
    /// (a repeated link extends it, never past 60 minutes from now); a job running now lets go of the GPU within a
    /// tenth of a second, as on a pause, and an idle model is unloaded so its memory is free at once. Never shows the
    /// panel and never changes the owner's pause.
    func yieldForHarness(minutes: Int) {
        var y = yielding
        y.extend(minutes: minutes, now: Date())
        let started = !isYielded
        y.save()
        withAnimation(.smooth(duration: 0.35)) { yielding = y }
        guard started else { return }
        let running = busy
        if !running {
            if phase == .ready, !stopping { setActivity(.paused) }
            Task { [worker] in await worker.unload() }
        }
        // a running job stops within a tenth of a second (`watch`): report the pause once it has
        Task {
            if running { try? await Task.sleep(for: .milliseconds(400)) }
            await heartbeat()
        }
    }

    /// mlx://resume?by=harness, the panel's Resume now, or Resume on the phone: carry on now (an owner pause stays).
    /// `kick` asks for the next job at once (the scheduler, which calls this when the time runs out, goes on itself).
    func endYield(kick: Bool = true) {
        guard yielding.until != nil else { return }
        let y = YieldState()
        y.save()
        withAnimation(.smooth(duration: 0.35)) { yielding = y }
        if case .paused = activity, phase == .ready, !busy, !stopping { setActivity(holdActivity() ?? .waiting("Ready")) }
        Task { await heartbeat() }
        if kick { Task { await tick() } }
    }

    // MARK: scheduler

    /// Every 4 seconds. A dedicated seat gets AI jobs back to back: as soon as a job's result is in, the next job is
    /// asked for, with every check made again first (pause, limits, battery, heat, the owner coming back, an update),
    /// so the GPU works without gaps. A free seat keeps its rhythm: one job per tick, and mlx.app holds the request for
    /// a random 1–9 s before handing out a short job.
    private func tick() async {
        while await step() && backToBack {}
    }

    /// AI jobs come back to back on this Mac's seat (mlx.app says the seat isn't throttled).
    private var backToBack: Bool { earning?.isThrottled == false }

    /// One scheduler step: true when a job ran to the end and its result was delivered.
    private func step() async -> Bool {
        guard phase == .ready, !busy, !stopping, !Task.isCancelled else { return false }
        if yielding.until != nil, !isYielded { endYield(kick: false) }  // stepping aside ran out: carry on
        if let hold = holdActivity() {
            setActivity(hold)
            return false
        }
        return await runOneJob()
    }

    /// What the Mac shows while it doesn't ask for a job, or nil when it's ready to ask for one now.
    private func holdActivity() -> Activity? {
        if limits.paused || isYielded { return .paused }
        let r = Policy.readiness(SystemInfo.conditions(), limits)
        guard r.ok else { return .waiting(r.reason) }
        guard jobsAllowed else { return .waiting(online ? "Waiting for mlx.app" : "Offline") }
        // a throttled free seat is ready for its next AI job ("Ready": the network counts it as mining)
        guard Date() >= noJobsUntil else { return .waiting(waitingForJob ? "Ready" : noJobsReason) }
        return nil
    }

    private func setActivity(_ a: Activity) {
        if a != activity { activity = a }
    }

    /// Ask mlx.app for a job, run it and send the result. True only when the job ran to the end and mlx.app took the
    /// result (the scheduler then asks for the next one at once on a dedicated seat).
    private func runOneJob() async -> Bool {
        guard let api else { return false }
        busy = true
        defer { busy = false }
        struct Ask: Encodable { let memoryGB: Int }
        let reply: JobReply
        do {
            reply = try await api.post("api/worker/job", Ask(memoryGB: SystemInfo.memoryGB), as: JobReply.self)
        } catch {
            online = false
            lastError = error.localizedDescription
            return false
        }
        guard let job = reply.job else {
            // a free seat gets AI jobs now and then: ask again when mlx.app says (5 s to 15 min); without a time, as
            // before, in 15 minutes
            let wait = reply.retryIn.map { min(max($0, 5), 15 * 60) } ?? 15 * 60
            noJobsUntil = Date().addingTimeInterval(wait)
            let throttled = reply.throttled == true
            if throttled != waitingForJob { withAnimation(.smooth(duration: 0.35)) { waitingForJob = throttled } }
            if throttled {
                // not a failure: the network is pacing a free seat
                lastError = nil
                setActivity(.waiting("Ready"))
            } else {
                let why = (reply.reason ?? "No work right now").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                noJobsReason = why.isEmpty ? "No work right now" : why
                setActivity(.waiting(noJobsReason))
            }
            return false
        }
        if waitingForJob { withAnimation(.smooth(duration: 0.35)) { waitingForJob = false } }
        // MLX Harness asked for the Mac while this job was on its way: leave it (mlx.app hands it out again)
        if isYielded {
            await worker.unload()
            setActivity(.paused)
            return false
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
                return false
            }
            if case .failure(let e) = await load.result {
                lastError = "Couldn't load \(job.model): \(e.localizedDescription)"
                noJobsUntil = Date().addingTimeInterval(10 * 60)
                return false
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
            setActivity(isYielded ? .paused : .waiting(stopped.reason))
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
            return stopped == nil && body.stop != "cancelled" && reply != nil
        case .failure(let e):
            if stopped == nil { lastError = e.localizedDescription }
            return false
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
            // stepping aside for MLX Harness lets go of the GPU and the model's memory the same way as a pause
            if isYielded {
                task.cancel()
                return Stopped(reason: AppModel.yieldReason, since: Date(), byOwner: false)
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
