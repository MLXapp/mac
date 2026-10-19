import XCTest

final class ThroughputTests: XCTestCase {
    /// 100 tokens a second, evenly spaced: the meter reads 100 at any point after the first token.
    func testSteadyRate() {
        var m = ThroughputMeter(window: 1.0)
        m.begin(at: 0)
        for i in 0..<300 { m.add(at: 0.5 + Double(i) * 0.01) }  // prefill took 0.5 s
        XCTAssertEqual(m.rate(at: 3.495), 100, accuracy: 1.5)
        XCTAssertEqual(m.stamps.count, 100, "only the last second is kept")
    }

    /// Early in a run the rate is taken over the time since the first token, not the whole window.
    func testEarlyRunIsNotDiluted() {
        var m = ThroughputMeter(window: 1.0)
        m.begin(at: 10)
        for i in 0..<20 { m.add(at: 10.2 + Double(i) * 0.01) }
        XCTAssertEqual(m.rate(at: 10.4), 100, accuracy: 1)
    }

    func testIdleAndEndReadZero() {
        var m = ThroughputMeter(window: 1.0)
        XCTAssertEqual(m.rate(at: 5), 0)
        m.begin(at: 0)
        for i in 0..<50 { m.add(at: Double(i) * 0.02) }
        XCTAssertEqual(m.rate(at: 3), 0, "nothing in the last second")
        m.add(at: 3.0)
        m.end()
        XCTAssertEqual(m.rate(at: 3.1), 0)
    }

    func testSpeedChangeFollowsWithinAWindow() {
        var m = ThroughputMeter(window: 1.0)
        m.begin(at: 0)
        var t = 0.0
        while t < 2 { m.add(at: t); t += 0.02 }   // 50 tok/s
        while t < 4 { m.add(at: t); t += 0.005 }  // then 200 tok/s
        XCTAssertEqual(m.rate(at: t), 200, accuracy: 3)
    }

    func testLiveCounterPhases() {
        final class Clock: @unchecked Sendable { var t = 0.0 }
        let clock = Clock()
        let c = LiveCounter(window: 1.0, clock: { clock.t })
        XCTAssertEqual(c.snapshot().phase, .idle)
        c.begin()
        XCTAssertEqual(c.snapshot().phase, .prefill)
        for _ in 0..<10 { clock.t += 0.01; c.token() }
        let s = c.snapshot()
        XCTAssertEqual(s.phase, .generating)
        XCTAssertEqual(s.tokens, 10)
        XCTAssertEqual(s.tokPerSec, 10 / 0.09, accuracy: 1)
        c.end()
        XCTAssertEqual(c.snapshot().tokPerSec, 0)
        XCTAssertEqual(c.snapshot().tokens, 10, "the total keeps counting across runs")
    }

    func testDayStatsRollOver() {
        let d1 = Date(timeIntervalSince1970: 1_792_200_000)
        var s = DayStats(day: DayStats.key(for: d1))
        s.record(tokens: 96, checked: true, passed: true, at: d1)
        s.record(tokens: 96, checked: true, passed: false, at: d1)
        XCTAssertEqual(s.jobs, 2)
        XCTAssertEqual(s.tokens, 192)
        XCTAssertEqual(s.passRate, 0.5)
        let d2 = d1.addingTimeInterval(86_400 * 2)
        XCTAssertEqual(s.current(d2).jobs, 0)
        XCTAssertNil(s.current(d2).passRate)
    }

    /// Days follow UTC, like "Mined today" on mlx.app: 23:30 and 00:30 UTC are different days wherever the Mac is.
    func testDayStatsUseUTC() {
        let late = Date(timeIntervalSince1970: 1_792_193_400)  // 2026-10-16 23:30 UTC
        XCTAssertEqual(DayStats.key(for: late), "2026-10-16")
        XCTAssertEqual(DayStats.key(for: late.addingTimeInterval(3600)), "2026-10-17")
    }

    /// A result only received by mlx.app is not a passed check: before any comparison the rate is unknown.
    func testUncheckedResultsHaveNoPassRate() {
        var s = DayStats(day: DayStats.key(for: Date()))
        s.record(tokens: 160, checked: false, passed: false)
        XCTAssertEqual(s.jobs, 1)
        XCTAssertEqual(s.tokens, 160)
        XCTAssertNil(s.passRate)
    }
}
