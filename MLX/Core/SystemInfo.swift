import AppKit
import Foundation
import IOKit.ps

/// Facts about this Mac the app reports and signs into its link request.
enum SystemInfo {
    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf)
        return Signing.clean(s.replacingOccurrences(of: "Apple ", with: ""), max: 24)
    }

    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }
    static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }

    static var os: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    static var name: String { Signing.clean(Host.current().localizedName ?? "My Mac", max: 40) }

    /// "MacBookPro18,3", "Mac14,13"… from the hardware model.
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// An SF Symbol that looks like this Mac: a laptop, or a desktop Mac.
    static var symbol: String {
        let m = model.lowercased()
        let n = name.lowercased()
        if m.contains("book") || n.contains("macbook") { return "laptopcomputer" }
        if n.contains("studio") { return "macstudio" }
        if n.contains("mini") { return "macmini" }
        if n.contains("imac") { return "desktopcomputer" }
        return "laptopcomputer"
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    static var isAppleSilicon: Bool {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }

    // MARK: live conditions

    /// Seconds since the last keyboard, mouse, trackpad or scroll input.
    static var idleSeconds: Double {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    static var onAC: Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "fair"
        }
    }

    static func conditions() -> Conditions {
        Conditions(
            idleSeconds: idleSeconds, onAC: onAC, thermal: thermal, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            hour: Calendar.current.component(.hour, from: Date()))
    }
}
