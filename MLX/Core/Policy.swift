import Foundation

/// The owner's limits. Saved on this Mac and reported to mlx.app with each heartbeat.
struct Limits: Codable, Equatable {
    /// Minutes without keyboard, mouse or trackpad input before work starts. 0 = manual: MLX works
    /// whenever it's started, even while the Mac is in use, until the owner stops it.
    /// New installs start in manual mode (18 Oct 2026): the owner starts and stops MLX.
    var idleMinutes: Int = 0
    /// Share of this Mac's memory MLX may use for a job.
    var memoryPct: Int = 50
    /// Work only between these hours (local time). Equal values mean any time.
    var hoursFrom: Int = 0
    var hoursTo: Int = 0
    /// Work only when plugged in.
    var onlyOnAC: Bool = true
    /// Stop when the Mac reports this thermal state or hotter.
    var maxThermal: String = "fair"
    /// The owner paused (or, in manual mode, stopped) MLX from the panel.
    var paused: Bool = false

    var manual: Bool { idleMinutes == 0 }

    static let key = "limits.v1"
    static func load() -> Limits {
        guard let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode(Limits.self, from: d) else {
            // a Mac set up before manual became the default, that never saved its limits, keeps the old 3 minutes
            let existing = UserDefaults.standard.data(forKey: "calibration") != nil || !(UserDefaults.standard.string(forKey: "wallet") ?? "").isEmpty
            var l = Limits()
            if existing { l.idleMinutes = 3 }
            return l
        }
        return l.clamped()
    }
    func save() { if let d = try? JSONEncoder().encode(clamped()) { UserDefaults.standard.set(d, forKey: Limits.key) } }

    func clamped() -> Limits {
        var l = self
        l.idleMinutes = min(60, max(0, l.idleMinutes))
        l.memoryPct = min(75, max(20, l.memoryPct))
        l.hoursFrom = min(24, max(0, l.hoursFrom)) % 24
        l.hoursTo = min(24, max(0, l.hoursTo)) % 24
        if !["fair", "serious"].contains(l.maxThermal) { l.maxThermal = "fair" }
        return l
    }
}

/// What the Mac is doing right now, as the scheduler sees it.
struct Conditions: Equatable {
    var idleSeconds: Double
    var onAC: Bool
    var thermal: String  // nominal, fair, serious, critical
    var lowPowerMode: Bool
    var hour: Int
}

/// Whether MLX may work now, and if not, a short reason to show in the menu.
enum Policy {
    static let thermalOrder = ["nominal", "fair", "serious", "critical"]

    static func readiness(_ c: Conditions, _ l: Limits) -> (ok: Bool, reason: String) {
        if l.paused { return (false, l.manual ? "Stopped" : "Paused") }
        if l.onlyOnAC && !c.onAC { return (false, "Waiting for power") }
        if c.lowPowerMode { return (false, "Low Power Mode is on") }
        if !inHours(c.hour, l) { return (false, "Outside your hours (\(hh(l.hoursFrom))–\(hh(l.hoursTo)))") }
        if tooHot(c.thermal, l) { return (false, "Letting your Mac cool down") }
        let need = Double(l.idleMinutes * 60)
        if !l.manual && c.idleSeconds < need {
            let left = Int((need - c.idleSeconds).rounded(.up))
            return (false, left >= 60 ? "Starts after \(Int((Double(left) / 60).rounded(.up))) min idle" : "Starts after \(left) s idle")
        }
        return (true, l.manual ? "Working" : "Working while you're away")
    }

    /// While working: stop at once when the owner touches the Mac, unplugs it, or it gets warm.
    static func mustStop(_ c: Conditions, _ l: Limits) -> String? {
        if l.paused { return l.manual ? "Stopped" : "Paused" }
        if !l.manual && c.idleSeconds < 1.0 { return "You're back" }
        if l.onlyOnAC && !c.onAC { return "Unplugged" }
        if c.lowPowerMode { return "Low Power Mode" }
        if tooHot(c.thermal, l) { return "Cooling down" }
        if !inHours(c.hour, l) { return "Outside your hours" }
        return nil
    }

    static func inHours(_ hour: Int, _ l: Limits) -> Bool {
        if l.hoursFrom == l.hoursTo { return true }
        if l.hoursFrom < l.hoursTo { return hour >= l.hoursFrom && hour < l.hoursTo }
        return hour >= l.hoursFrom || hour < l.hoursTo  // over midnight, e.g. 22–7
    }

    static func tooHot(_ thermal: String, _ l: Limits) -> Bool {
        let t = thermalOrder.firstIndex(of: thermal) ?? 0
        let max = thermalOrder.firstIndex(of: l.maxThermal) ?? 1
        return t > max
    }

    static func hh(_ h: Int) -> String { String(format: "%02d:00", h) }
}
