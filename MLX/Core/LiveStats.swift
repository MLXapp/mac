import Combine
import Foundation

/// The menu's live numbers: speed now, the last 30 seconds of it for the chart, and whether the compute grid still has
/// cells fading. Updated ten times a second; publishes only on change.
///
/// What the chart and the big number show (`shown`) is always measured tokens a second, shaped by the seat:
/// - free seat: a heartbeat. Each short AI job rises at once to the speed it ran at (`LiveCounter.takePeak`, so a job
///   shorter than a tenth of a second is not missed) and falls back within about half a second; flat between jobs.
/// - dedicated seat: a hum. The same readings, averaged over the last 1.5 s and eased (0.6 s), so back-to-back jobs
///   read as a steady level with small bumps where one job hands over to the next; it falls to 0 within a few
///   seconds when the work stops.
/// Nothing is invented: only smoothing. When the seat changes, the two blend over 1.2 s, so the line never jumps.
@MainActor
final class LiveStats: ObservableObject {
    /// 30 seconds of samples, ten a second.
    static let sampleCount = 300
    static let sampleInterval: TimeInterval = 0.1

    /// MLX's generation rate now (1 s window), as reported to mlx.app.
    @Published private(set) var tokPerSec: Double = 0
    /// What the big number and the head of the chart show (see above).
    @Published private(set) var shown: Double = 0
    @Published private(set) var phase: LiveCounter.Phase = .idle
    @Published private(set) var samples = [Double](repeating: 0, count: LiveStats.sampleCount)
    /// True while generating and for a moment after, so the grid can finish fading.
    @Published private(set) var animating = false
    /// Tokens are flowing: generating now, or on a dedicated seat between two back-to-back jobs (up to 1.5 s).
    @Published private(set) var active = false
    /// Uptime of the newest sample and the time since the one before; the chart scrolls continuously between them.
    private(set) var lastSampleAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    private(set) var sampleGap: TimeInterval = LiveStats.sampleInterval
    private var idleSince: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0

    /// The seat this Mac runs: true on a dedicated seat (AI jobs back to back), false on a free one. Set from the
    /// heartbeat; the chart eases from one look to the other.
    var steady = false
    /// 0 = heartbeat, 1 = hum; moves toward `steady` at 1/1.2 a second.
    private(set) var steadiness: Double = 0
    private var spike: Double = 0
    private var hum: Double = 0
    private var recentReadings: [(t: TimeInterval, v: Double)] = []

    static let spikeFall: TimeInterval = 0.12
    static let humWindow: TimeInterval = 1.5
    static let humEase: TimeInterval = 0.6
    static let blend: TimeInterval = 1.2

    var flat: Bool { shown == 0 && samples.allSatisfy { $0 == 0 } }

    func update(_ s: LiveCounter.Snapshot, peak: Double = 0, now: TimeInterval) {
        let dt = lastUpdate == 0 ? LiveStats.sampleInterval : min(0.5, max(0.001, now - lastUpdate))
        lastUpdate = now
        let r = (s.tokPerSec * 10).rounded() / 10
        if r != tokPerSec { tokPerSec = r }
        if s.phase != phase {
            if s.phase == .idle { idleSince = now }
            phase = s.phase
        }
        let a = phase != .idle || now - idleSince < 1.2
        if a != animating { animating = a }

        // the reading: the rate now, or a short run that came and went since the last update
        let reading = max(s.tokPerSec, peak)
        // the seat's look, eased
        let target: Double = steady ? 1 : 0
        steadiness += max(-dt / LiveStats.blend, min(dt / LiveStats.blend, target - steadiness))
        // heartbeat: rise at once, fall fast
        spike = max(reading, spike * exp(-dt / LiveStats.spikeFall))
        if reading == 0, spike < 0.5 { spike = 0 }
        // hum: a short moving average, eased
        recentReadings.append((t: now, v: reading))
        recentReadings.removeAll { $0.t <= now - LiveStats.humWindow }
        let avg = recentReadings.isEmpty ? 0 : recentReadings.reduce(0) { $0 + $1.v } / Double(recentReadings.count)
        hum += (avg - hum) * (1 - exp(-dt / LiveStats.humEase))
        if avg == 0, hum < 0.5 { hum = 0 }
        let e = steadiness * steadiness * (3 - 2 * steadiness)
        let v = ((spike * (1 - e) + hum * e) * 10).rounded() / 10

        let act = phase != .idle || (steady && hum > 0 && now - idleSince < 1.5)
        if act != active { active = act }
        let wasFlat = flat
        if v != shown { shown = v }
        // one sample per update (ten a second); nothing to publish while the chart lies flat
        if !(wasFlat && v == 0) {
            var next = samples
            next.removeFirst()
            next.append(v)
            samples = next
        }
        sampleGap = min(0.3, max(0.05, now - lastSampleAt))
        lastSampleAt = now
    }
}
