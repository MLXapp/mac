import Foundation

/// `"MLX Node.app/Contents/MacOS/MLX" --selftest`: checks this build end to end without the UI.
/// Signs a heartbeat to mlx.app (proves the signature format matches the server), then downloads
/// the smallest beta model and runs one greedy job on the GPU. Used by CI and for support.
enum SelfTest {
    /// `"/Volumes/MLX Node/MLX Node.app/Contents/MacOS/MLX" --selftest-install [--eject]`: what pressing Install does,
    /// without the window (CI runs it from the notarized disk image). Exit 0 with "installed: <path> (before: <v>)".
    static func install() async -> Int32 {
        func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
        let here = Bundle.main.bundleURL
        say("MLX Node \(SystemInfo.appVersion) install test from \(here.path)")
        guard DiskImage.isRunningFromDiskImage(here) else {
            say("not running from a disk image (real path: \(Translocation.realPath(of: here) ?? "?"))")
            return 5
        }
        let client = UpdaterClient()
        defer { client.close() }
        do {
            let done = try await client.installFromDisk(source: here.path, eject: CommandLine.arguments.contains("--eject"))
            say("installed: \(done.path) (before: \(done.previous ?? "none"))")
            return 0
        } catch {
            say("install failed: \(error.localizedDescription)")
            return 6
        }
    }

    static func run() async -> Int32 {
        func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
        do {
            say("MLX Node \(SystemInfo.appVersion) self-test on \(SystemInfo.os), Apple \(SystemInfo.chip), \(SystemInfo.memoryGB) GB")
            let key = try DeviceKey.loadOrCreate()
            say("device key: \(key.kind.rawValue) \(key.publicKeyHex.prefix(12))…")
            let api = API(key: key)
            say("chain: \(try await api.chain()) at \(api.base.absoluteString)")
            let hello = HelloBody(
                app: SystemInfo.appVersion, os: SystemInfo.os, chip: SystemInfo.chip, memoryGB: SystemInfo.memoryGB, cores: SystemInfo.cores,
                state: "off", reason: "self-test", thermal: SystemInfo.thermal, onAC: SystemInfo.onAC, limits: Limits(), calibration: nil,
                stops: .init(count: 0, p50: 0, max: 0))
            let r = try await api.post("api/worker/hello", hello, as: HelloReply.self)
            say("signed heartbeat accepted: invited=\(r.invited) jobs=\(r.jobs)")
            guard let seats = seatDecoding() else {
                say("seats: the earning reply (0.9.2 seat fields) didn't decode as expected")
                return 4
            }
            say("seats: \(seats)")
            let link = try await api.linkURL(account: Signing.anyWallet)
            say("link url ok (\(link.absoluteString.count) chars)")
            for line in await WalletBrowser.selfTest() { say("wallet: \(line)") }
            // the installer service inside the app (Contents/XPCServices) must answer, or 0.8.2+ can't update itself
            let updater = UpdaterClient()
            let answer = await updater.ping()
            updater.close()
            guard let answer else {
                say("updater: the installer service (MLXUpdater.xpc) didn't answer")
                return 3
            }
            say("updater: \(answer)")
            if CommandLine.arguments.contains("--no-model") { return 0 }
            let w = Worker()
            await w.setMemoryShare(50)
            let t0 = Date()
            try await w.load("mlx-community/Qwen2.5-0.5B-Instruct-4bit") { _ in }
            say(String(format: "model loaded in %.1f s", Date().timeIntervalSince(t0)))
            // sample the live meter the menu uses while the job runs
            let live = w.live
            let sampler = Task { () -> (peak: Double, mean: Double) in
                var xs: [Double] = []
                while !Task.isCancelled {
                    let s = live.snapshot()
                    if s.phase == .generating, s.tokPerSec > 0 { xs.append(s.tokPerSec) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return (xs.max() ?? 0, xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count))
            }
            let out = try await w.run(prompt: "List the planets of the solar system in order from the Sun.", maxTokens: 48)
            sampler.cancel()
            let meter = await sampler.value
            say(String(format: "generated %ld tokens at %.1f tok/s, first token %ld ms, stop=%@", out.tokens.count, out.tokPerSec, out.ttftMs, out.stop))
            say(String(format: "live meter: %.1f tok/s mean, %.1f peak (1 s window, as the menu shows), %ld tokens counted", meter.mean, meter.peak, live.snapshot().tokens))
            let pod = Worker.podReady
            say("pod-ready: jaccl=\(pod.jaccl) rdma=\(pod.rdma)")
            say("output hash \(out.outHash)")
            say("text: \(out.text.replacingOccurrences(of: "\n", with: " ").prefix(160))")
            return out.tokens.isEmpty ? 2 : 0
        } catch {
            say("self-test failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// The earning shapes the panel reads: mlx.app's seat fields (0.9.2: a free M4 Pro, Ultra running as Pro there), a
    /// dedicated seat, and an older reply without any of them, and the per-hour rates the panel shows (0.9.4: "~0.83
    /// MLX/h"). Nil when one decodes or formats wrong.
    static func seatDecoding() -> String? {
        let base = #""units":0,"weight":0.125,"today":"0","mined":"0","perDayCap":"1000000","perDayCapSmall":"20000000","score":0,"started":true"#
        let free = "{" + base + #","usdPerMlx":0.01,"seat":"free","throttled":true,"macTier":"M","chip":"M4 Pro","freePerDay":"1000000","best":"M","maxTimes":80,"offers":[{"tier":"N","name":"Nano","price":50,"units":0.5,"perDay":"4000000","fullPerDay":"4000000","times":4,"lockDays":20,"fits":"full"},{"tier":"M","name":"Pro","price":1000,"units":10,"perDay":"80000000","fullPerDay":"80000000","times":80,"lockDays":7,"fits":"full"},{"tier":"L","name":"Ultra","price":4000,"units":40,"perDay":"80000000","fullPerDay":"320000000","times":80,"lockDays":3,"fits":"reduced","earnsAs":"Pro"}]}"#
        let dedicated = #"{"units":10,"weight":10,"today":"0","mined":"0","perDayCap":"80000000","perDayCapSmall":"20000000","score":0,"started":true,"seat":"dedicated","throttled":false,"seatTier":"M","seatName":"Pro","seatNumber":12,"best":"M","maxTimes":80,"offers":[{"tier":"M","name":"Pro","price":1000,"units":10,"perDay":"80000000","fullPerDay":"80000000","times":80,"lockDays":7,"fits":"full"}]}"#
        let old = "{" + base + "}"
        let d = JSONDecoder()
        guard let a = try? d.decode(HelloReply.Earning.self, from: Data(free.utf8)),
              let b = try? d.decode(HelloReply.Earning.self, from: Data(dedicated.utf8)),
              let c = try? d.decode(HelloReply.Earning.self, from: Data(old.utf8)),
              let j = try? d.decode(JobReply.self, from: Data(#"{"job":null,"retryIn":90,"throttled":true}"#.utf8))
        else { return nil }
        guard a.isThrottled, !a.dedicated, a.bestOffer?.name == "Pro", a.offers?.last?.reduced == true,
              a.upgradeTimes.map({ HelloReply.Earning.times($0) }) == "80×", a.seatTitle == "Free seat",
              b.dedicated, !b.isThrottled, b.seatTitle == "Pro seat #12", !b.canUpgrade, b.currentOffer?.tier == "M",
              a.currentOffer == nil, a.freeDay == 1, b.freeDay == 1, c.freeDay == 1,
              HelloReply.Earning.perHour(1) == "0.0417", HelloReply.Earning.perHour(30) == "1.25",
              HelloReply.Earning.perHour(80) == "3.33", HelloReply.Earning.perHour(480) == "20",
              HelloReply.Earning.perHour(20) == "0.83", HelloReply.Earning.perHour(4) == "0.17",
              HelloReply.Earning.rate(1) == "~0.0417 MLX/h", HelloReply.Earning.rate(20) == "~0.83 MLX/h",
              HelloReply.Earning.rate(30) == "~1.25 MLX/h", HelloReply.Earning.rate(80) == "~3.33 MLX/h",
              HelloReply.Earning.rate(320) == "~13.33 MLX/h", HelloReply.Earning.rate(480) == "~20 MLX/h",
              c.offers == nil, !c.dedicated, c.isThrottled, c.upgradeTimes.map({ HelloReply.Earning.times($0) }) == "20×",
              j.job == nil, j.retryIn == 90, j.throttled == true
        else { return nil }
        return "\(SystemInfo.macName()): free \(HelloReply.Earning.rate(a.freeDay ?? 0)), \(a.seatTitle) up to \(HelloReply.Earning.times(a.maxTimes ?? 0)), dedicated \(b.seatTitle), older reply ok, throttled job reply ok"
    }
}
