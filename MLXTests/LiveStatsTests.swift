import XCTest

/// The chart's two looks (MLX Node 0.9.4): a heartbeat on a free seat, a steady hum on a dedicated one. Always
/// measured speed, only smoothed.
@MainActor
final class LiveStatsTests: XCTestCase {
    private func snap(_ phase: LiveCounter.Phase, _ r: Double) -> LiveCounter.Snapshot {
        LiveCounter.Snapshot(phase: phase, tokPerSec: r, tokens: 0)
    }

    /// Free seat: a short job shows as a beat at the speed it ran, the line is flat again within a second, and the
    /// beat stays in the chart's history.
    func testFreeSeatBeats() {
        let l = LiveStats()
        var t = 100.0
        l.update(snap(.idle, 0), now: t)
        t += 0.1
        l.update(snap(.idle, 0), peak: 300, now: t)  // the job came and went between two samples
        XCTAssertEqual(l.shown, 300, accuracy: 0.1)
        for _ in 0..<10 {
            t += 0.1
            l.update(snap(.idle, 0), now: t)
        }
        XCTAssertEqual(l.shown, 0)
        XCTAssertEqual(l.samples.max() ?? 0, 300, accuracy: 0.1)
        XCTAssertTrue(l.flat == false, "the beat is still on screen")
    }

    /// Dedicated seat: jobs back to back (0.6 s at 300 tok/s, 0.4 s handing over to the next) read as a steady level
    /// with small bumps; it never steps by much from one sample to the next, and falls to 0 when the work stops.
    func testDedicatedSeatHums() {
        let l = LiveStats()
        l.steady = true
        var t = 0.0
        for _ in 0..<20 {
            t += 0.1
            l.update(snap(.idle, 0), now: t)
        }
        XCTAssertEqual(l.steadiness, 1, accuracy: 0.001)
        var seen: [Double] = []
        var prev = l.shown
        var biggestStep = 0.0
        for k in 0..<600 {
            t += 0.1
            let on = k % 10 < 6
            l.update(snap(on ? .generating : .idle, on ? 300 : 0), now: t)
            biggestStep = max(biggestStep, abs(l.shown - prev))
            prev = l.shown
            if k >= 100 { seen.append(l.shown) }
        }
        let mean = seen.reduce(0, +) / Double(seen.count)
        let lo = seen.min() ?? 0, hi = seen.max() ?? 0
        XCTAssertEqual(mean, 180, accuracy: 15, "the level is the work actually done")
        XCTAssertLessThan(hi - lo, mean * 0.3, "small bumps, not beats")
        XCTAssertLessThan(biggestStep, 40, "no jumps")
        XCTAssertTrue(l.active, "a hand-over between jobs is not idle")
        let stopAt = l.shown
        for _ in 0..<60 {
            t += 0.1
            l.update(snap(.idle, 0), now: t)
            XCTAssertLessThanOrEqual(l.shown, stopAt + 5, "falls, no bounce")
            XCTAssertLessThan(abs(l.shown - prev), 40, "no jumps")
            prev = l.shown
        }
        XCTAssertEqual(l.shown, 0, "and comes to rest at 0")
        XCTAssertFalse(l.active)
    }

    /// Changing the seat blends the two looks over about a second instead of switching.
    func testSeatChangeBlends() {
        let l = LiveStats()
        var t = 10.0
        l.update(snap(.idle, 0), now: t)
        l.steady = true
        for _ in 0..<6 {
            t += 0.1
            l.update(snap(.idle, 0), now: t)
        }
        XCTAssertEqual(l.steadiness, 0.5, accuracy: 0.01)
        for _ in 0..<6 {
            t += 0.1
            l.update(snap(.idle, 0), now: t)
        }
        XCTAssertEqual(l.steadiness, 1, accuracy: 0.01)
    }
}
