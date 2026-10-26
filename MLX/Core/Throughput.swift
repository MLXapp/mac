import Foundation

/// Tokens per second over a sliding window. Times are seconds on any monotonic clock.
/// While a run is younger than the window, the rate is taken over the run so far, so the number
/// is right from the first moment instead of ramping up from zero.
struct ThroughputMeter: Sendable {
    let window: TimeInterval
    private(set) var stamps: [TimeInterval] = []
    private var firstToken: TimeInterval?

    init(window: TimeInterval = 1.0) { self.window = window }

    /// A new run starts (prefill begins); earlier tokens are forgotten.
    mutating func begin(at t: TimeInterval) {
        stamps.removeAll(keepingCapacity: true)
        firstToken = nil
    }

    /// One token arrived at `t`.
    mutating func add(at t: TimeInterval) {
        if firstToken == nil { firstToken = t }
        stamps.append(t)
    }

    /// The run ended: the rate drops to zero.
    mutating func end() {
        stamps.removeAll(keepingCapacity: true)
        firstToken = nil
    }

    /// Tokens per second at `now`: tokens in the last `window` seconds over the window, or over the
    /// time since the run's first token when that is shorter (prefill is not generation time).
    mutating func rate(at now: TimeInterval) -> Double {
        let cutoff = now - window
        if let i = stamps.firstIndex(where: { $0 > cutoff }) {
            if i > 0 { stamps.removeFirst(i) }
        } else {
            stamps.removeAll(keepingCapacity: true)
        }
        guard !stamps.isEmpty, let first = firstToken else { return 0 }
        let span = min(window, now - first)
        guard span >= 0.05 else { return 0 }
        return Double(stamps.count) / span
    }
}

/// What the worker is doing right now, shared between the worker (which counts tokens as they
/// stream) and the menu (which samples it ten times a second). Thread-safe.
final class LiveCounter: @unchecked Sendable {
    enum Phase: String, Sendable { case idle, prefill, generating }
    struct Snapshot: Sendable, Equatable {
        let phase: Phase
        let tokPerSec: Double
        let tokens: Int  // tokens produced since launch; the compute grid steps one cell per token
    }

    private let lock = NSLock()
    private var meter: ThroughputMeter
    private var phase: Phase = .idle
    private var total = 0
    /// The run so far: its token count and first token, for `takePeak`.
    private var runCount = 0
    private var runStart: TimeInterval = 0
    private var peak: Double = 0
    private let clock: @Sendable () -> TimeInterval

    init(window: TimeInterval = 1.0, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        meter = ThroughputMeter(window: window)
        self.clock = clock
    }

    func begin() {
        lock.lock(); defer { lock.unlock() }
        meter.begin(at: clock())
        phase = .prefill
        runCount = 0
    }

    func token() {
        lock.lock(); defer { lock.unlock() }
        let t = clock()
        meter.add(at: t)
        total += 1
        phase = .generating
        // the run's own rate (tokens after the first over the time since it), kept as the highest since `takePeak`:
        // a free seat's short job can start and end between two samples of the menu, and would otherwise be missed
        runCount += 1
        if runCount == 1 {
            runStart = t
        } else if t - runStart >= 0.03 {
            peak = max(peak, Double(runCount - 1) / (t - runStart))
        }
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        meter.end()
        phase = .idle
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(phase: phase, tokPerSec: meter.rate(at: clock()), tokens: total)
    }

    /// The highest generation rate measured since the last call (0 when no tokens came), and start over. Only the
    /// menu's sampler calls it, ten times a second.
    func takePeak() -> Double {
        lock.lock(); defer { lock.unlock() }
        defer { peak = 0 }
        return peak
    }
}

/// Today's counts for the menu: jobs, AI tokens generated and how many results passed their checks.
/// Kept per UTC day in UserDefaults; a new day starts from zero.
struct DayStats: Codable, Equatable, Sendable {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    var day: String
    var jobs = 0
    var tokens = 0
    var checked = 0
    var passed = 0

    /// The UTC day, the same day mlx.app pays "Mined today" for, so the panel's numbers line up.
    static func key(for date: Date, calendar: Calendar = DayStats.utc) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Share of checked results that passed, or nil before the first check.
    var passRate: Double? { checked > 0 ? Double(passed) / Double(checked) : nil }

    /// Today's stats, rolling over to a fresh day when the date changed.
    func current(_ now: Date = Date()) -> DayStats {
        let k = DayStats.key(for: now)
        return k == day ? self : DayStats(day: k)
    }

    mutating func record(tokens n: Int, checked: Bool, passed ok: Bool, at now: Date = Date()) {
        self = current(now)
        jobs += 1
        tokens += n
        if checked {
            self.checked += 1
            if ok { passed += 1 }
        }
    }

    static func load(_ d: UserDefaults = .standard) -> DayStats {
        if let data = d.data(forKey: "today"), let s = try? JSONDecoder().decode(DayStats.self, from: data) { return s.current() }
        return DayStats(day: key(for: Date()))
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: "today") }
    }
}
