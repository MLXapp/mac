import SwiftUI

/// The panel under the menu bar icon: live speed, the working blocks, today's numbers and the few
/// controls the app needs. The website's hero shows this same panel.
struct MenuView: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject private var wallet = WalletBrowser.shared
    @ObservedObject private var updater = AppModel.shared.updater
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if m.phase == .ready {
                LivePanel(live: m.live, model: m.currentModel ?? m.calibration.map { AppModel.display(id: $0.model) }, idleLine: idleLine, shown: shown)
                if m.yielding.until != nil {
                    YieldRow().transition(.opacity.combined(with: .move(edge: .top)))
                }
                ComputeGrid(counter: m.worker.live, live: m.live, shown: shown)
                if let p = progress {
                    ProgressView(value: p).progressViewStyle(.linear).tint(BrandMark.orange)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                stats
                if let e = m.lastError {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(3).transition(.opacity)
                }
            } else {
                setup
            }
            if m.phase == .ready, m.earning != nil { EarnCard().transition(.opacity.combined(with: .move(edge: .top))) }
            if let v = updater.justUpdated, !updater.busy, !m.updateAvailable {
                UpdatedRow(version: v).transition(.opacity.combined(with: .move(edge: .top)))
            }
            if m.updateAvailable || updater.state != .idle, let v = updateVersion {
                UpdateCard(updater: updater, version: v, notes: m.latest?.notes ?? "")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider()
            actions
        }
        .padding(16)
        .onAppear { shown = true }
        .onDisappear { shown = false }
        .animation(.smooth(duration: 0.35), value: m.activity)
        .animation(.smooth(duration: 0.35), value: m.phase)
        .animation(.smooth(duration: 0.35), value: m.lastError)
        .animation(.smooth(duration: 0.35), value: m.yielding)
        .animation(.smooth(duration: 0.35), value: m.updateAvailable)
        .animation(.smooth(duration: 0.35), value: updater.state)
        .animation(.smooth(duration: 0.35), value: updater.justUpdated)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Emblem(size: 24)
                // the MLX wordmark (X at 70%) and the product name, as the site's lockup (`Brand` suffix: semibold, muted)
                (Text("ML") + Text("X").foregroundColor(Color.primary.opacity(0.7))
                    + Text(" Node").fontWeight(.semibold).foregroundColor(.secondary))
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                StatusPill(state: pill)
            }
            Text("\(SystemInfo.name) · \(SystemInfo.chip) · \(SystemInfo.memoryGB) GB")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var pill: StatusPill.Kind {
        if !m.online { return .offline }
        if m.limits.paused { return m.limits.manual ? .stopped : .paused }
        if m.isYielded { return .paused }
        if case .paused = m.activity { return .paused }
        if case .downloading = m.activity { return .working }
        return m.isWorking ? .working : .idle
    }

    /// What the panel says under the model when no tokens are flowing.
    private var idleLine: String {
        switch m.activity {
        case .working: return "Starting"
        case .downloading(_, let p): return "Getting the model, \(Int(p * 100))%"
        case .calibrating: return "Measuring this Mac"
        // stepping aside for MLX Harness is always "Paused" (the line under the chart says why); the owner's own
        // pause reads "Stopped" in manual mode
        case .paused: return m.limits.paused && m.limits.manual ? "Stopped" : "Paused"
        // a free seat between its AI jobs is ready, not idle for want of work
        case .waiting(let r): return r == "Ready" ? (m.waitingForJob ? "Waiting for the next AI job" : "Waiting for work") : r
        }
    }

    private var progress: Double? {
        switch m.activity {
        case .downloading(_, let p): return p
        case .calibrating(let p): return p
        default: return nil
        }
    }

    // MARK: today

    private var stats: some View {
        let t = m.today.current()
        return HStack(spacing: 0) {
            stat("\(t.jobs)", "Jobs today")
            stat(compact(t.tokens), "AI tokens today")
            stat(t.passRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "Checks passed")
        }
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(spacing: 2) {
            Text(v)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .contentTransition(.numericText())
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: return "\(n / 1000)K"
        case 1000...: return String(format: "%.1fK", Double(n) / 1000)
        default: return "\(n)"
        }
    }

    // MARK: setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch m.phase {
            case .failed(let why):
                Text(why).foregroundStyle(.secondary)
            case .needsLink, .needsInvite:
                Text("Link this Mac to your MLX wallet to start.").foregroundStyle(.secondary)
            default:
                Text("Starting…").foregroundStyle(.secondary)
            }
            if !failed {
                Button("Finish setting up") { m.setupGo(.connect) }
                    .buttonStyle(.borderedProminent).tint(BrandMark.orange)
            }
        }
    }

    private var failed: Bool {
        if case .failed = m.phase { return true }
        return false
    }

    /// The version on the update card: the one installing while it works, otherwise the newest mlx.app offers.
    private var updateVersion: String? {
        updater.busy ? (updater.version ?? m.latest?.version) : (m.latest?.version ?? updater.version)
    }

    // MARK: actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            if m.phase == .ready {
                if m.limits.manual {
                    MenuRow(m.limits.paused ? "Start" : "Stop", icon: m.limits.paused ? "play.fill" : "stop.fill") { m.toggleRunning() }
                } else {
                    MenuRow(m.limits.paused ? "Resume" : "Pause", icon: m.limits.paused ? "play.fill" : "pause.fill") { m.toggleRunning() }
                }
            }
            MenuRow("Wallet", icon: "wallet.pass", detail: wallet.account ?? m.account, chevron: true) { m.openWallet() }
            MenuRow("Settings", icon: "gearshape", chevron: true) { m.go(.settings) }
            MenuRow("Quit MLX Node", icon: "power") { NSApp.terminate(nil) }
        }
    }
}

/// "Paused for MLX Harness · resumes in 8 min" and Resume now, while MLX Node steps aside for MLX Harness (mlx://yield).
/// Quiet on purpose: a small line under the chart, not a card. The minutes count down on their own.
struct YieldRow: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            let left = max(1, m.yielding.minutesLeft(at: ctx.date))
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                (Text(AppModel.yieldReason).foregroundColor(.primary)
                    + Text(" · resumes in \(left) min").foregroundColor(.secondary))
                    .font(.caption)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.35), value: left)
                Spacer(minLength: 6)
                Button("Resume now") { m.endYield() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Working / Idle / Paused / Offline, as a small coloured capsule.
struct StatusPill: View {
    enum Kind { case working, idle, paused, stopped, offline }
    let state: Kind

    private var color: Color {
        switch state {
        case .working: return .green
        case .idle: return .gray
        case .paused: return .orange
        case .stopped: return .gray
        case .offline: return .red
        }
    }

    private var label: String {
        switch state {
        case .working: return "Working"
        case .idle: return "Idle"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .offline: return "Offline"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(state == .working ? 0.7 : 0), radius: 3)
            Text(label).contentTransition(.opacity)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(state == .idle || state == .stopped ? Color.secondary : color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .animation(.smooth(duration: 0.35), value: state)
    }
}

struct MenuRow: View {
    let title: String
    let icon: String
    var detail: String?
    var chevron = false
    let action: () -> Void
    init(_ title: String, icon: String, detail: String? = nil, chevron: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.detail = detail
        self.chevron = chevron
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .transition(.opacity)
                }
                if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct HoverRow<Content: View>: View {
    let pressed: Bool
    @ViewBuilder let content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover || pressed ? Color.primary.opacity(0.08) : .clear))
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// The seat this Mac runs and what its wallet has mined: today (UTC, paid every hour, all the wallet's Macs) and all of it
/// still locked, with dollar values at the network price. On top, the seat: a free seat is throttled (sporadic AI
/// jobs), a dedicated seat runs at full speed (AI jobs back to back) and mines at a higher rate; a seat bigger than this
/// Mac's class mines as the Mac's class, and the card says so. While a bigger seat would mine more here, the card
/// offers the upgrade.
struct EarnCard: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        let e = m.earning
        VStack(alignment: .leading, spacing: 10) {
            if let e { SeatStatus(e: e) }
            HStack(alignment: .top) {
                figure("Wallet mined today", e?.today, usd: e?.usdPerMlx, alignment: .leading)
                Spacer()
                figure("Locked", e?.mined, usd: e?.usdPerMlx, alignment: .trailing)
            }
            if let e, e.canUpgrade {
                UpgradeButton(
                    title: e.dedicated ? "Upgrade to \(EarnCard.article(e.bestOffer?.name ?? "bigger")) \(e.bestOffer?.name ?? "bigger") seat" : "Upgrade to a dedicated seat",
                    times: e.upgradeTimes.map { HelloReply.Earning.times($0) }
                ) {
                    // the seat picker needs mlx.app's offers; an older mlx.app has none, so the wallet's seats open instead
                    if e.offers?.isEmpty == false { m.go(.upgrade) } else { m.openNodes() }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.smooth(duration: 0.35), value: e)
    }

    /// "a Pro", "an Ultra".
    static func article(_ name: String) -> String {
        guard let f = name.first else { return "a" }
        return "AEIOU".contains(f.uppercased()) ? "an" : "a"
    }

    private func figure(_ label: String, _ units: String?, usd: Double?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(Self.mlx(units))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .contentTransition(.numericText())
            if let usd, usd > 0 {
                Text(Self.dollars(units, usd))
                    .font(.caption2).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    /// "≈ $0.20" for base units of MLX at `usd` per MLX.
    static func dollars(_ units: String?, _ usd: Double) -> String {
        let v = (Double(units ?? "0") ?? 0) / 1_000_000 * usd
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = v < 1 ? 4 : 2
        f.minimumFractionDigits = 2
        return "≈ \(f.string(from: NSNumber(value: v)) ?? "$0")"
    }

    /// "0.0104 MLX" from base units (6 decimals): four decimals under 100, none from 10,000.
    static func mlx(_ units: String?) -> String { "\(amount(units)) MLX" }

    /// "0.0104", "80", "1,280" from base units, without the unit.
    static func amount(_ units: String?) -> String {
        let v = (Double(units ?? "0") ?? 0) / 1_000_000
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = v == 0 ? 0 : v < 100 ? 4 : v < 10_000 ? 2 : 0
        return f.string(from: NSNumber(value: v)) ?? "0"
    }

    static func units(_ u: Double) -> String { u == u.rounded() ? String(Int(u)) : String(u) }
}

/// The seat line at the top of the earn card: a dot (amber throttled, green full speed), "Free seat · Throttled" or
/// "Core Latest seat #1 · Full speed", and what this Mac mines an hour on it.
struct SeatStatus: View {
    let e: HelloReply.Earning

    private var color: Color { e.isThrottled ? .orange : .green }

    /// Free: "Sporadic AI jobs. Your MacBook Pro (M5) mines ~0.0417 MLX/h."
    /// Dedicated: "AI jobs back to back. Mines up to ~0.83 MLX/h here."
    /// A seat mines; nothing is paid out up front. The rates are mlx.app's caps for this Mac, given per hour only.
    private var detail: String {
        if !e.dedicated {
            let mac = "Your \(SystemInfo.macName(chip: e.chip))"
            guard let day = e.freeDay else { return "Sporadic AI jobs. \(mac) mines a little MLX every hour." }
            return "Sporadic AI jobs. \(mac) mines \(HelloReply.Earning.rate(day))."
        }
        let day = HelloReply.Earning.value(e.perDayCap)
        let jobs = e.isThrottled ? "Sporadic AI jobs." : "AI jobs back to back."
        guard day > 0 else { return jobs }
        return "\(jobs) Mines up to \(HelloReply.Earning.rate(day)) here."
    }

    /// "Your Ultra seat mines as Pro on this Mac." when the wallet's biggest seat outranks this Mac's chip.
    private var carriedAs: String? {
        guard e.dedicated, let full = e.fullUnits, full > e.units, let seat = e.nodeName, let mac = e.macName else { return nil }
        return "Your \(seat) seat mines as \(mac) on this Mac."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 3)
                .padding(.top, 4.5)
            VStack(alignment: .leading, spacing: 2) {
                (Text(e.seatTitle).foregroundColor(.primary) + Text(" · ").foregroundColor(.secondary)
                    + Text(e.isThrottled ? "Throttled" : "Full speed").foregroundColor(color))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if let carriedAs {
                    Text(carriedAs)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.smooth(duration: 0.35), value: e)
    }
}

/// The card's call to action: "Upgrade to a dedicated seat" with "Mine up to 80× more" under it. Tinted with the brand
/// orange, a touch brighter under the pointer.
struct UpgradeButton: View {
    let title: String
    let times: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(BrandMark.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .contentTransition(.opacity)
                    if let times {
                        Text("Mine up to \(times) more")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrandMark.orange)
                            .contentTransition(.numericText())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(BrandMark.orange.opacity(0.14), in: Capsule())
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BrandMark.orange.opacity(hover ? 0.14 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(BrandMark.orange.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .animation(.smooth(duration: 0.35), value: times)
        .animation(.smooth(duration: 0.35), value: title)
    }
}
