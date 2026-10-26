import AppKit
import SwiftUI

/// Upgrade to a dedicated seat, inside the panel. A seat mines: it reserves a higher mining rate for the Mac that
/// carries it (nothing is paid out up front). The picker starts with the free seat every Mac runs on, then every seat
/// on sale (Nano, Lite, Core, Pro, Ultra); "Current" marks the seat this Mac runs now, "Best for your Mac" the biggest
/// it mines in full, and a seat it can't mine in full is greyed, "Not recommended", with what it mines here instead. Each one shows what it mines an
/// hour on THIS Mac ("~1.25 MLX/h"; rates are per hour only since 0.9.4), how many times a free seat, its price, when mined
/// MLX unlocks and how AI jobs come, and the button opens the wallet buying it. Every number comes from mlx.app (`earning.offers`); the app works nothing out.
struct UpgradePanel: View {
    typealias Offer = HelloReply.Earning.Offer
    typealias Earning = HelloReply.Earning
    @EnvironmentObject var m: AppModel
    /// The option picked ("free" or a tier id); nil = the best seat for this Mac.
    @State private var pick: String?
    @Namespace private var seg

    /// One option in the picker: the free seat (no offer) or a seat on sale.
    struct Choice: Identifiable, Equatable {
        let id: String
        let offer: Offer?
        var free: Bool { offer == nil }
        var name: String { offer?.name ?? "Free" }
        var short: String { offer.map { UpgradePanel.short($0.name) } ?? "Free" }
    }

    static let freeID = "free"
    /// Days mined MLX stays locked on a free seat (mlx.app's `COMPUTE_FREE_LOCK_DAYS`; change with it).
    static let freeLockDays = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SubHeader(title: m.earning?.dedicated == true ? "Upgrade your seat" : "Upgrade to a dedicated seat")
            if let e = m.earning, let offers = e.offers, !offers.isEmpty {
                let choices = [Choice(id: Self.freeID, offer: nil)] + offers.map { Choice(id: $0.tier, offer: $0) }
                let c = selected(e, choices)
                intro(e)
                picker(e, choices, c)
                if let o = c.offer, o.reduced {
                    reducedNote(e, o)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                figures(e, c)
                action(e, c)
            } else {
                // an older mlx.app sends no offers (the earn card then opens the wallet's seats directly)
                Text("A dedicated seat mines far more than a free one: AI jobs back to back at a higher mining rate.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "Compare all seats") { m.openNodes() }
            }
        }
        .padding(16)
        .animation(.smooth(duration: 0.35), value: pick)
        .animation(.smooth(duration: 0.35), value: m.earning)
        .onAppear(perform: pickDefault)
        .onChange(of: m.earning?.best) { _, _ in pickDefault() }
    }

    /// The default is the best seat for this Mac, set once: after that only the owner changes the selection, never a
    /// new reply from mlx.app.
    private func pickDefault() {
        guard pick == nil, let e = m.earning, let offers = e.offers, !offers.isEmpty else { return }
        pick = e.bestOffer?.tier ?? offers.last?.tier
    }

    private func selected(_ e: Earning, _ choices: [Choice]) -> Choice {
        if let pick, let c = choices.first(where: { $0.id == pick }) { return c }
        if let b = e.bestOffer, let c = choices.first(where: { $0.id == b.tier }) { return c }
        return choices.last ?? Choice(id: Self.freeID, offer: nil)
    }

    private func choose(_ id: String) {
        withAnimation(.smooth(duration: 0.35)) { pick = id }
    }

    /// The seat this Mac runs now: the free seat while the wallet has no dedicated one, else the offer that is its seat.
    private func isCurrent(_ e: Earning, _ c: Choice) -> Bool {
        c.free ? !e.dedicated : e.currentOffer?.tier == c.id
    }

    // MARK: the intro and the seat picker

    @ViewBuilder
    private func intro(_ e: Earning) -> some View {
        if let best = e.bestOffer {
            // "Your MacBook Pro (M5) can carry up to a Core Latest seat."
            (Text("Your \(SystemInfo.macName(chip: e.chip)) can carry up to \(EarnCard.article(best.name)) ")
                + Text(best.name).fontWeight(.semibold).foregroundColor(.primary) + Text(" seat."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Free · Nano · Lite over Core · Pro · Ultra, as tiles: the name, and under it "Current", "Best for your Mac",
    /// a red "Not recommended" (a seat this Mac can't mine in full, greyed) or the price. The picked tile sits on a thumb
    /// that slides from tile to tile.
    private func picker(_ e: Earning, _ choices: [Choice], _ c: Choice) -> some View {
        let rows = stride(from: 0, to: choices.count, by: 3).map { Array(choices[$0..<min($0 + 3, choices.count)]) }
        return VStack(spacing: 2) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 2) {
                    ForEach(rows[i]) { x in
                        segment(e, x, on: x.id == c.id)
                    }
                }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private enum Tag { case current, best, notRecommended, price }

    private func tag(_ e: Earning, _ x: Choice) -> Tag {
        if isCurrent(e, x) { return .current }
        if x.offer?.reduced == true { return .notRecommended }
        if let b = e.bestOffer, b.tier == x.id { return .best }
        return .price
    }

    private func segment(_ e: Earning, _ x: Choice, on: Bool) -> some View {
        let t = tag(e, x)
        let caption: String
        let color: Color
        switch t {
        case .current: caption = "Current"; color = .green
        case .best: caption = "Best for your Mac"; color = .green
        case .notRecommended: caption = "Not recommended"; color = .red
        case .price: caption = Self.caption(x); color = .secondary
        }
        let greyed = t == .notRecommended
        return Button {
            choose(x.id)
        } label: {
            VStack(spacing: 1) {
                Text(x.short)
                    .font(.system(size: 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(greyed ? Color.secondary.opacity(0.6) : on ? Color.primary : Color.secondary)
                Text(caption)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color.opacity(greyed ? 0.85 : 1))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Self.thumb)
                        .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "seat-thumb", in: seg)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(x.name) seat, \(caption)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The thumb under the picked option: white in light mode, a lighter glass in dark mode (as a segmented control).
    private static let thumb = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.2) : NSColor.white
    })

    /// "$50", "$1,000" under a seat's name; "$0" under Free.
    static func caption(_ x: Choice) -> String {
        x.offer.map { price($0.price) } ?? "$0"
    }

    /// A seat this Mac can't mine in full: "Your MacBook Pro (M5) mines this seat as Core: up to ~0.83 MLX/h, not ~1.25.
    /// It mines in full once you link a Mac with an M6."
    private func reducedNote(_ e: Earning, _ o: Offer) -> some View {
        let mac = SystemInfo.macName(chip: e.chip)
        let here = Earning.rate(Earning.value(o.perDay))
        let full = Earning.perHour(Earning.value(o.fullPerDay))
        var text = "Your \(mac) mines this seat as \(o.earnsAs ?? "a smaller seat"): up to \(here), not ~\(full)."
        if let carrier = Self.carrier(o.tier) { text += " It mines in full once you link a Mac with \(carrier)." }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The chip a Mac needs to mine a seat in full, from the seat's tier (mlx.app's `LATEST_CHIPS`: M6, M5 Pro, M5 Max,
    /// M5 Ultra; change with it when Apple ships new chips).
    static func carrier(_ tier: String) -> String? {
        switch tier {
        case "SX": return "an M6"
        case "MX": return "an M5 Pro or M5 Max"
        case "LX": return "an M5 Ultra"
        case "M": return "a Pro or Max chip"
        case "L": return "an Ultra chip"
        default: return nil
        }
    }

    // MARK: what the picked seat mines here

    /// MLX a day the option mines on this Mac (mlx.app's figure; the panel shows it per hour).
    private func perDay(_ e: Earning, _ c: Choice) -> Double? {
        if let o = c.offer { return Earning.value(o.perDay) }
        return e.freeDay
    }

    /// "~1.25 MLX/h", then "30× your free seat", the price, when mined MLX unlocks and how AI jobs come.
    private func figures(_ e: Earning, _ c: Choice) -> some View {
        let day = perDay(e, c)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(day.map { "~\(Earning.perHour($0))" } ?? "–")
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: day ?? 0))
                Text("MLX/h")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            Text(timesLine(c))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.free ? Color.secondary : BrandMark.orange)
                .contentTransition(.numericText(value: c.offer?.times ?? 1))
            if let usd = e.usdPerMlx, usd > 0, let day {
                // "≈ $0.0125/h at today's price"
                Text("\(EarnCard.dollars(String(Int64((day / 24 * 1_000_000).rounded())), usd))/h at today's price")
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: day))
            }
            VStack(alignment: .leading, spacing: 5) {
                fact("tag.fill", c.offer.map { Self.price($0.price) } ?? "Free")
                fact("lock.fill", lockLine(c))
                fact(c.free ? "hourglass" : "bolt.fill", c.free ? "Sporadic AI jobs" : "AI jobs back to back")
            }
            .padding(.top, 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "30× your free seat"; on the free seat itself, "The free seat every Mac runs on".
    private func timesLine(_ c: Choice) -> String {
        guard let o = c.offer, o.times > 0 else { return "The free seat every Mac runs on" }
        return "\(Earning.times(o.times)) your free seat"
    }

    /// "Mined MLX unlocks after 10 days".
    private func lockLine(_ c: Choice) -> String {
        let days = c.offer == nil ? Self.freeLockDays : c.offer?.lockDays
        guard let days, days > 0 else { return "Mined MLX unlocks after its lock-in" }
        return days == 1 ? "Mined MLX unlocks after 1 day" : "Mined MLX unlocks after \(days) days"
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }

    // MARK: buy

    /// The buy button. On a seat this Mac can't mine in full it offers the best seat instead ("Get Core instead · $250")
    /// and keeps "Buy Pro anyway" as a text button where "Compare all seats" sits, so nothing below moves.
    private func action(_ e: Earning, _ c: Choice) -> some View {
        let current = isCurrent(e, c)
        let instead: Offer? = {
            guard let o = c.offer, o.reduced, let b = e.bestOffer, b.tier != o.tier, !b.reduced else { return nil }
            return b
        }()
        let title: String
        if current {
            title = "Your current seat"
        } else if let b = instead {
            title = "Get \(b.name) instead · \(Self.price(b.price))"
        } else if let o = c.offer {
            title = "Get \(o.name) seat · \(Self.price(o.price))"
        } else {
            title = "Free with MLX Node"
        }
        return VStack(spacing: 8) {
            Button {
                if let b = instead { m.openBuy(tier: b.tier) } else if let o = c.offer, !current { m.openBuy(tier: o.tier) }
            } label: {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandMark.ink)
            .controlSize(.large)
            .disabled(c.free || current)
            .keyboardShortcut(.defaultAction)
            ZStack {
                if let o = c.offer, instead != nil, !current {
                    Button("Buy \(o.name) anyway") { m.openBuy(tier: o.tier) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .transition(.opacity)
                } else {
                    Button("Compare all seats") { m.openNodes() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: words

    /// "Nano"… "Ultra" for the picker: a Latest edition keeps its class's name there (the intro and button say "Latest").
    static func short(_ name: String) -> String {
        name.components(separatedBy: " ").first ?? name
    }

    /// "$1,000", "$375", "$1,500"; cents only when there are any.
    static func price(_ usd: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = usd == usd.rounded() ? 0 : 2
        f.minimumFractionDigits = usd == usd.rounded() ? 0 : 2
        return f.string(from: NSNumber(value: usd)) ?? "$\(Int(usd))"
    }
}
