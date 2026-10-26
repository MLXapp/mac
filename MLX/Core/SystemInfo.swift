import AppKit
import Foundation
import IOKit
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

    /// "MacBook Pro", "Mac mini"…: what kind of Mac this is. Apple Silicon Macs name themselves in the device tree
    /// ("MacBook Pro (14-inch, M5, 2025)", the part before the bracket); else the hardware model we are sure of (same
    /// table as mlx.app's lib/world/hw.ts); else the computer's own name if it says ("Luca's MacBook Air"); else "Mac".
    static let productName: String = {
        if let p = deviceTreeProductName() { return p }
        if let k = kindFromModel(model) { return k }
        let n = name
        for k in ["MacBook Air", "MacBook Pro", "Mac mini", "Mac Studio", "Mac Pro", "iMac"] where n.localizedCaseInsensitiveContains(k) {
            return k
        }
        return "Mac"
    }()

    /// "MacBook Pro M5 (16 GB)": the kind of Mac, its chip and memory, as the panel names this Mac in a sentence.
    static func describe(chip: String? = nil) -> String {
        let c = (chip?.isEmpty == false ? chip! : self.chip)
        return [productName, c].filter { !$0.isEmpty }.joined(separator: " ") + " (\(memoryGB) GB)"
    }

    /// "MacBook Pro (M5)": the kind of Mac and its chip, as the seat lines name this Mac ("Your MacBook Pro (M5) mines…").
    static func macName(chip: String? = nil) -> String {
        let c = (chip?.isEmpty == false ? chip! : self.chip)
        return c.isEmpty ? productName : "\(productName) (\(c))"
    }

    private static func deviceTreeProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let ref = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        var s: String?
        if let d = ref as? Data {
            s = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
        } else if let str = ref as? String {
            s = str
        }
        guard let full = s?.trimmingCharacters(in: .whitespacesAndNewlines), !full.isEmpty else { return nil }
        let kind = (full.components(separatedBy: " (").first ?? full).trimmingCharacters(in: .whitespaces)
        // only a real Mac's name ("Apple Virtual Machine 1" on a CI runner is not one)
        guard kind.hasPrefix("Mac") || kind.hasPrefix("iMac"), kind.count <= 24 else { return nil }
        return kind
    }

    private static func kindFromModel(_ hw: String) -> String? {
        let table: [String: String] = [
            "Mac14,2": "MacBook Air", "Mac14,15": "MacBook Air", "Mac15,12": "MacBook Air", "Mac15,13": "MacBook Air",
            "Mac16,12": "MacBook Air", "Mac16,13": "MacBook Air",
            "Mac14,5": "MacBook Pro", "Mac14,6": "MacBook Pro", "Mac14,7": "MacBook Pro", "Mac14,9": "MacBook Pro", "Mac14,10": "MacBook Pro",
            "Mac15,3": "MacBook Pro", "Mac15,6": "MacBook Pro", "Mac15,7": "MacBook Pro", "Mac15,8": "MacBook Pro", "Mac15,9": "MacBook Pro",
            "Mac15,10": "MacBook Pro", "Mac15,11": "MacBook Pro",
            "Mac16,1": "MacBook Pro", "Mac16,5": "MacBook Pro", "Mac16,6": "MacBook Pro", "Mac16,7": "MacBook Pro", "Mac16,8": "MacBook Pro",
            "Macmini9,1": "Mac mini", "Mac14,3": "Mac mini", "Mac14,12": "Mac mini", "Mac16,10": "Mac mini", "Mac16,11": "Mac mini",
            "Mac13,1": "Mac Studio", "Mac13,2": "Mac Studio", "Mac14,13": "Mac Studio", "Mac14,14": "Mac Studio", "Mac15,14": "Mac Studio",
            "Mac16,9": "Mac Studio",
            "iMac21,1": "iMac", "iMac21,2": "iMac", "Mac15,4": "iMac", "Mac15,5": "iMac", "Mac16,2": "iMac", "Mac16,3": "iMac",
            "Mac14,8": "Mac Pro",
        ]
        if let k = table[hw] { return k }
        if hw.hasPrefix("MacBookAir") { return "MacBook Air" }
        if hw.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if hw.hasPrefix("Macmini") { return "Mac mini" }
        if hw.hasPrefix("iMac") { return "iMac" }
        return nil
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
