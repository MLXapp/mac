import SwiftUI

/// Settings, inside the panel: when MLX may work, the wallet, notifications and this Mac.
struct SettingsPanel: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject private var news = WalletNews.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubHeader(title: "Settings")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("When MLX may work") {
                        LimitsForm()
                    }
                    group("Account") {
                        row("Wallet", value: m.account ?? "Not connected", action: m.account == nil ? "Connect" : "Change") { m.go(.connect) }
                        Divider()
                        Toggle(isOn: Binding(get: { news.enabled }, set: { news.setEnabled($0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Wallet notifications").font(.system(size: 13, weight: .medium))
                                Text(news.denied ? "Allow MLX in System Settings → Notifications to turn these on." : "Money received, deposits, nodes and withdrawals.")
                                    .font(.caption).foregroundStyle(news.denied ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch).controlSize(.small)
                    }
                    group("This Mac") {
                        info("Chip", "Apple \(SystemInfo.chip)")
                        info("Memory", "\(SystemInfo.memoryGB) GB")
                        info("System", SystemInfo.os)
                        info("Key", m.key?.kind.rawValue ?? "–")
                        info("Device ID", m.deviceID.isEmpty ? "–" : String(m.deviceID.prefix(8)) + "…" + String(m.deviceID.suffix(6)), mono: true)
                        info("App", SystemInfo.appVersion)
                        if let c = m.calibration { info("Speed", "\(Int(c.tokPerSec.rounded())) tok/s") }
                        HStack {
                            Button(m.calibration == nil ? "Measure this Mac" : "Measure again") { Task { _ = await m.calibrate() } }
                                .controlSize(.small)
                            Spacer()
                        }
                    }
                    Toggle("Open MLX when you log in", isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 }))
                        .toggleStyle(.switch).controlSize(.small)
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 470)
        }
        .padding(16)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row(_ k: String, value: String, mono: Bool = false, action: String, _ go: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(k).font(.caption).foregroundStyle(.secondary)
                Text(value).font(mono ? .system(size: 13, weight: .medium, design: .monospaced) : .system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(action, action: go).controlSize(.small)
        }
    }

    private func info(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(mono ? .system(size: 11, design: .monospaced) : .caption).textSelection(.enabled).lineLimit(1)
        }
    }
}

/// The owner's limits, shared by setup and Settings.
struct LimitsForm: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        let l = $m.limits
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("After idle for").font(.callout)
                    Text(m.limits.manual ? "Off: you start and stop MLX yourself" : "Pauses when you're back, resumes when you leave")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(m.limits.manual ? "Off" : "\(m.limits.idleMinutes) min").monospacedDigit().font(.callout.weight(.medium))
                    .contentTransition(.numericText())
                Stepper("", value: l.idleMinutes, in: 0...60).labelsHidden()
            }
            Toggle("Only when plugged in", isOn: l.onlyOnAC).toggleStyle(.switch).controlSize(.small)
            HStack {
                Text("Memory MLX may use").font(.callout)
                Spacer()
                Slider(value: Binding(get: { Double(m.limits.memoryPct) }, set: { m.limits.memoryPct = Int($0) }), in: 20...75, step: 5)
                    .frame(width: 110)
                Text("\(m.limits.memoryPct)%").monospacedDigit().font(.callout).frame(width: 36, alignment: .trailing)
            }
            Picker("Hours", selection: Binding(get: { m.limits.hoursFrom == m.limits.hoursTo ? 0 : 1 }, set: { v in
                if v == 0 { m.limits.hoursFrom = 0; m.limits.hoursTo = 0 } else { m.limits.hoursFrom = 22; m.limits.hoursTo = 7 }
            })) {
                Text("Any time").tag(0)
                Text("Only at night").tag(1)
            }
            .pickerStyle(.segmented)
            if m.limits.hoursFrom != m.limits.hoursTo {
                HStack {
                    Picker("From", selection: l.hoursFrom) { ForEach(0..<24, id: \.self) { Text(Policy.hh($0)).tag($0) } }
                    Picker("To", selection: l.hoursTo) { ForEach(0..<24, id: \.self) { Text(Policy.hh($0)).tag($0) } }
                }
                .controlSize(.small)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Picker("Stop when the Mac is", selection: l.maxThermal) {
                Text("Warm").tag("fair")
                Text("Hot").tag("serious")
            }
            .controlSize(.small)
        }
        .animation(.smooth(duration: 0.3), value: m.limits)
    }
}
