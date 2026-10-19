import Foundation

/// `"MLX Node.app/Contents/MacOS/MLX" --selftest`: checks this build end to end without the UI.
/// Signs a heartbeat to mlx.app (proves the signature format matches the server), then downloads
/// the smallest beta model and runs one greedy job on the GPU. Used by CI and for support.
enum SelfTest {
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
}
