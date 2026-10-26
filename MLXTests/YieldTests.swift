import XCTest

/// MLX Node stepping aside for MLX Harness (0.9.6): the mlx:// links and how long a yield lasts.
final class LinkCommandTests: XCTestCase {
    private func parse(_ s: String) -> LinkCommand { LinkCommand.parse(URL(string: s)!) }

    func testYieldMinutes() {
        XCTAssertEqual(parse("mlx://yield?by=harness&minutes=15"), .yield(minutes: 15))
        XCTAssertEqual(parse("mlx://yield?by=harness"), .yield(minutes: 10))  // default
        XCTAssertEqual(parse("mlx://yield?by=harness&minutes=0"), .yield(minutes: 1))
        XCTAssertEqual(parse("mlx://yield?by=harness&minutes=-5"), .yield(minutes: 1))
        XCTAssertEqual(parse("mlx://yield?by=harness&minutes=600"), .yield(minutes: 60))
        XCTAssertEqual(parse("mlx://yield?by=harness&minutes=abc"), .yield(minutes: 10))
        XCTAssertEqual(parse("mlx://yield?minutes=5&by=harness"), .yield(minutes: 5))
        XCTAssertEqual(parse("MLX://Yield?by=Harness&minutes=5"), .yield(minutes: 5))
        XCTAssertEqual(parse("mlx:yield?by=harness&minutes=5"), .yield(minutes: 5))
        XCTAssertEqual(parse("mlx:///yield?by=harness&minutes=5"), .yield(minutes: 5))
    }

    func testResume() {
        XCTAssertEqual(parse("mlx://resume?by=harness"), .resume)
        XCTAssertEqual(parse("mlx://resume?by=harness&minutes=5"), .resume)
    }

    func testOnlyHarnessIsAccepted() {
        XCTAssertEqual(parse("mlx://yield"), .ignore)
        XCTAssertEqual(parse("mlx://yield?minutes=5"), .ignore)
        XCTAssertEqual(parse("mlx://yield?by=someone&minutes=5"), .ignore)
        XCTAssertEqual(parse("mlx://resume?by="), .ignore)
        XCTAssertEqual(parse("mlx://resume"), .ignore)
    }

    func testOtherLinksShowThePanel() {
        XCTAssertEqual(parse("mlx://"), .show)
        XCTAssertEqual(parse("mlx://open"), .show)
        XCTAssertEqual(parse("mlx://wallet?by=harness"), .show)
        XCTAssertEqual(parse("https://mlx.app/yield?by=harness"), .show)
    }
}

final class YieldStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_200_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testStartsAndRunsOut() {
        var y = YieldState()
        XCTAssertFalse(y.isActive(at: t0))
        XCTAssertEqual(y.minutesLeft(at: t0), 0)
        y.extend(minutes: 10, now: t0)
        XCTAssertEqual(y.until, at(10))
        XCTAssertTrue(y.isActive(at: at(9.9)))
        XCTAssertEqual(y.minutesLeft(at: t0), 10)
        XCTAssertEqual(y.minutesLeft(at: at(9.5)), 1)  // rounded up in the last minute
        XCTAssertFalse(y.isActive(at: at(10)))
        XCTAssertEqual(y.minutesLeft(at: at(11)), 0)
    }

    func testRepeatedYieldExtendsButNeverShortens() {
        var y = YieldState()
        y.extend(minutes: 10, now: t0)
        y.extend(minutes: 10, now: at(5))
        XCTAssertEqual(y.until, at(15))
        y.extend(minutes: 2, now: at(6))  // a shorter ask keeps the later end
        XCTAssertEqual(y.until, at(15))
    }

    func testNeverBeyondSixtyMinutesFromNow() {
        var y = YieldState()
        y.extend(minutes: 600, now: t0)
        XCTAssertEqual(y.until, at(60))
        y.extend(minutes: 60, now: at(30))
        XCTAssertEqual(y.until, at(90))  // 60 from the latest link
        y.extend(minutes: 60, now: at(30))
        XCTAssertEqual(y.until, at(90))
    }

    func testAfterRunningOutANewYieldStartsFromNow() {
        var y = YieldState()
        y.extend(minutes: 5, now: t0)
        y.extend(minutes: 3, now: at(20))
        XCTAssertEqual(y.until, at(23))
    }

    func testEndAndNormalize() {
        var y = YieldState()
        y.extend(minutes: 10, now: t0)
        y.end()
        XCTAssertNil(y.until)
        XCTAssertFalse(y.isActive(at: t0))
        XCTAssertNil(YieldState(until: at(-1)).normalized(at: t0).until)  // ran out
        XCTAssertNil(YieldState(until: at(61)).normalized(at: t0).until)  // clock moved back
        XCTAssertEqual(YieldState(until: at(30)).normalized(at: t0).until, at(30))
    }
}
