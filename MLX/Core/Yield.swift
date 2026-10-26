import Foundation

/// What an `mlx://` link asks MLX Node to do.
///
/// MLX Harness (the owner's other Mac app) runs AI models on this same Mac. While it does, it asks MLX Node to step
/// aside so the two don't fight over memory and the GPU:
///
///   mlx://yield?by=harness&minutes=10   pause network jobs for 10 minutes (default 10, 1…60)
///   mlx://resume?by=harness             end that pause now
///
/// Any app on this Mac can open these links (a URL scheme has no caller identity), so `by=harness` is a label, not
/// proof. What bounds the effect: a yield never lasts more than 60 minutes from the latest link, it ends on its own,
/// and it never touches the owner's own pause (`Limits.paused`). Every other `mlx://` link opens the panel, as before.
enum LinkCommand: Equatable {
    case yield(minutes: Int)
    case resume
    /// A yield or resume link from an unknown caller (`by` missing or not `harness`): do nothing.
    case ignore
    /// Anything else: show the panel.
    case show

    /// The only `by` value accepted for yield and resume.
    static let harness = "harness"

    static func parse(_ url: URL) -> LinkCommand {
        guard url.scheme?.lowercased() == "mlx" else { return .show }
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // mlx://yield?… (host) or mlx:yield?… / mlx:///yield?… (path)
        let host = (c?.host ?? "").lowercased()
        let action = host.isEmpty ? (c?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() : host
        guard action == "yield" || action == "resume" else { return .show }
        let items = c?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
        guard value("by")?.lowercased() == harness else { return .ignore }
        if action == "resume" { return .resume }
        return .yield(minutes: YieldState.clampMinutes(value("minutes").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }))
    }
}

/// MLX Node stepping aside for MLX Harness: no new network jobs until `until`, then it carries on by itself. Kept apart
/// from the owner's pause, so ending it never resumes a Mac the owner paused.
struct YieldState: Codable, Equatable {
    static let defaultMinutes = 10
    static let maxMinutes = 60

    /// When the yield ends; nil when MLX Node isn't yielding.
    var until: Date?

    static func clampMinutes(_ m: Int?) -> Int {
        guard let m else { return defaultMinutes }
        return min(maxMinutes, max(1, m))
    }

    func isActive(at now: Date) -> Bool {
        guard let until else { return false }
        return until > now
    }

    /// Whole minutes left, rounded up ("resumes in 1 min" in its last minute); 0 when not yielding.
    func minutesLeft(at now: Date) -> Int {
        guard let until, until > now else { return 0 }
        return Int((until.timeIntervalSince(now) / 60).rounded(.up))
    }

    /// A yield link: step aside for `minutes` from now. A repeated link extends the yield (it keeps whichever ends
    /// later), never beyond 60 minutes from now; so MLX Harness can repeat the link while its model runs.
    mutating func extend(minutes: Int, now: Date) {
        let cap = now.addingTimeInterval(TimeInterval(Self.maxMinutes * 60))
        let asked = now.addingTimeInterval(TimeInterval(Self.clampMinutes(minutes) * 60))
        let current = until.map { max($0, now) } ?? now
        until = min(cap, max(current, asked))
    }

    mutating func end() { until = nil }

    /// Drops a yield that has run out (or one more than 60 minutes ahead, after the clock moved back).
    func normalized(at now: Date) -> YieldState {
        guard let until, until > now, until <= now.addingTimeInterval(TimeInterval(Self.maxMinutes * 60)) else { return YieldState() }
        return self
    }

    // Saved, so a yield survives MLX Node restarting while MLX Harness still runs its model.
    static let key = "yield.v1"
    static func load(now: Date = Date()) -> YieldState {
        guard let d = UserDefaults.standard.data(forKey: key), let y = try? JSONDecoder().decode(YieldState.self, from: d) else { return YieldState() }
        return y.normalized(at: now)
    }
    func save() {
        if until == nil { UserDefaults.standard.removeObject(forKey: Self.key) } else if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
