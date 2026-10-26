import SwiftUI

/// Big tokens-per-second number, the model and phase, and a scrolling chart of the last 30 s. The number and the chart
/// show `LiveStats.shown`: measured speed, a heartbeat on a free seat and a steady hum on a dedicated one.
struct LivePanel: View {
    @ObservedObject var live: LiveStats
    let model: String?
    let idleLine: String
    let shown: Bool

    private var phaseLine: String {
        switch live.phase {
        case .generating: return "Generating"
        // on a dedicated seat the next job's prefill and the hand-over between jobs are part of the same steady run
        case .prefill: return live.steady ? "Generating" : "Prefill"
        case .idle: return live.active ? "Generating" : idleLine
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(live.shown.rounded()))")
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundStyle(live.active || live.shown > 0 ? Color.primary : Color.secondary)
                    .contentTransition(.numericText(value: live.shown))
                    .animation(.smooth(duration: 0.3), value: Int(live.shown.rounded()))
                Text("tok/s")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text([model, phaseLine].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.3), value: phaseLine)
            Sparkline(live: live, shown: shown)
                .frame(height: 56)
                .padding(.top, 2)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Brand colours that follow the appearance: ink→orange in light mode, white→orange in dark.
private func brandStops(_ scheme: ColorScheme) -> [Color] {
    [scheme == .dark ? .white : BrandMark.ink, BrandMark.orange]
}

/// Area chart of tok/s over the last 30 s (ten samples a second). It scrolls continuously between samples and its head
/// eases from the last sample to the newest, so nothing jumps when a sample arrives. The shape is the seat's: crisp
/// beats on a free seat, a steady hum on a dedicated one (`LiveStats`).
struct Sparkline: View {
    @ObservedObject var live: LiveStats
    let shown: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale = Scale()

    /// The y-axis top eases toward its target instead of snapping.
    final class Scale {
        var top: Double = 10
        var at: TimeInterval = 0
        func step(toward target: Double, now: TimeInterval) -> Double {
            let dt = at == 0 ? 1 : min(1, max(0, now - at))
            at = now
            top += (target - top) * min(1, dt * 3)
            return top
        }
    }

    var body: some View {
        let paused = !shown || reduceMotion || live.flat
        TimelineView(.animation(minimumInterval: 1 / 60, paused: paused)) { _ in
            Canvas { ctx, size in
                draw(&ctx, size, now: ProcessInfo.processInfo.systemUptime)
            }
        }
        .accessibilityLabel("Speed over the last 30 seconds")
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, now: TimeInterval) {
        let w = size.width, h = size.height
        // faint baseline
        var base = Path()
        base.move(to: CGPoint(x: 0, y: h - 0.5))
        base.addLine(to: CGPoint(x: w, y: h - 0.5))
        ctx.stroke(base, with: .color(.primary.opacity(0.08)), lineWidth: 1)

        let s = live.samples
        let n = s.count
        guard n > 2 else { return }
        let peak = max(s.max() ?? 0, live.shown)
        let top = scale.step(toward: max(10, peak * 1.2), now: now)
        // how far the time since the newest sample is through a sample's span (0…1)
        let frac = reduceMotion ? 1 : min(1, max(0, (now - live.lastSampleAt) / live.sampleGap))
        let headX = w - 4
        let step = headX / CGFloat(n - 2)
        let zeroY = h - 2
        func y(_ v: Double) -> CGFloat { zeroY - CGFloat(min(max(v, 0), top) / top) * (h - 6) }
        // every sample but the newest scrolls left as time passes; the head moves from the one before the newest to the
        // newest over a sample's span, and lands where the next sample starts, so the line never jumps
        var pts: [CGPoint] = (0..<(n - 1)).map { i in
            CGPoint(x: headX - (CGFloat(n - 2 - i) + CGFloat(frac)) * step, y: y(s[i]))
        }
        let headV = s[n - 2] + (s[n - 1] - s[n - 2]) * frac
        pts.append(CGPoint(x: headX, y: y(headV)))

        let line = Sparkline.catmullRom(pts, floor: zeroY)
        var area = line
        area.addLine(to: CGPoint(x: headX, y: h))
        area.addLine(to: CGPoint(x: pts[0].x, y: h))
        area.closeSubpath()

        ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [BrandMark.orange.opacity(0.28), BrandMark.orange.opacity(0)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
        ctx.stroke(line, with: .linearGradient(
            Gradient(colors: brandStops(scheme)),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w, y: 0)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        // the live head
        if live.active || headV > 0, let head = pts.last {
            let r: CGFloat = 3
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)), with: .color(BrandMark.orange))
        }
    }

    /// Catmull-Rom spline through the points, as cubic Béziers. Control points never go below `floor` (the zero line),
    /// so a beat that rises from a flat line doesn't dip under it first.
    static func catmullRom(_ p: [CGPoint], floor: CGFloat = .greatestFiniteMagnitude) -> Path {
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(floor, p1.y + (p2.y - p0.y) / 6))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(floor, p2.y - (p3.y - p1.y) / 6))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

/// The working blocks: a 12×4 grid where each generated token lights the next cell, which fades
/// over 0.6 s. The cursor snakes column by column, so a run reads as a wave moving across.
struct ComputeGrid: View {
    let counter: LiveCounter
    @ObservedObject var live: LiveStats
    let shown: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = GridState()

    static let cols = 12, rows = 4
    static let fade: TimeInterval = 0.6

    /// Per-cell light times, advanced by the tokens produced since the last frame.
    final class GridState {
        var litAt = [TimeInterval](repeating: -10, count: ComputeGrid.cols * ComputeGrid.rows)
        var cursor = 0
        var seen: Int?
        var lastFrame: TimeInterval = 0

        func advance(tokens: Int, now: TimeInterval) {
            defer { lastFrame = now }
            guard let prev = seen else { seen = tokens; return }
            seen = tokens
            let new = min(tokens - prev, litAt.count)
            guard new > 0 else { return }
            // spread this frame's tokens over the time since the last frame, so the wave is even
            let from = max(lastFrame, now - 0.1)
            for k in 0..<new {
                litAt[ComputeGrid.order[cursor]] = from + (now - from) * Double(k + 1) / Double(new)
                cursor = (cursor + 1) % litAt.count
            }
        }
    }

    /// Snake order: down column 0, up column 1, down column 2…
    static let order: [Int] = (0..<cols).flatMap { c in
        (c % 2 == 0 ? Array(0..<rows) : Array((0..<rows).reversed())).map { r in r * cols + c }
    }

    var body: some View {
        let paused = !shown || reduceMotion || !live.animating
        TimelineView(.animation(minimumInterval: 1 / 60, paused: paused)) { _ in
            Canvas { ctx, size in
                let now = ProcessInfo.processInfo.systemUptime
                if !reduceMotion { state.advance(tokens: counter.snapshot().tokens, now: now) }
                draw(&ctx, size, now: now)
            }
        }
        .frame(height: 64)
        .accessibilityLabel(live.phase == .idle ? "Compute idle" : "Computing")
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, now: TimeInterval) {
        let gap: CGFloat = 4
        let cw = (size.width - gap * CGFloat(Self.cols - 1)) / CGFloat(Self.cols)
        let ch = (size.height - gap * CGFloat(Self.rows - 1)) / CGFloat(Self.rows)
        let ink = scheme == .dark ? Color.white : BrandMark.ink
        let busy = live.phase != .idle
        for r in 0..<Self.rows {
            for c in 0..<Self.cols {
                let i = r * Self.cols + c
                let rect = CGRect(x: CGFloat(c) * (cw + gap), y: CGFloat(r) * (ch + gap), width: cw, height: ch)
                let cell = Path(roundedRect: rect, cornerRadius: 3.5, style: .continuous)
                ctx.fill(cell, with: .color(.primary.opacity(busy ? 0.1 : 0.06)))
                let b: Double
                if reduceMotion {
                    b = busy && (i % 3 == 0) ? 0.6 : 0
                } else {
                    b = max(0, 1 - (now - state.litAt[i]) / Self.fade)
                }
                guard b > 0 else { continue }
                // colour runs ink→orange across the grid, like the brand gradient
                let t = Double(c) / Double(Self.cols - 1)
                ctx.fill(cell, with: .color(BrandMark.orange.opacity(b * (0.55 + 0.45 * t))))
                ctx.fill(cell, with: .color(ink.opacity(b * 0.35 * (1 - t))))
            }
        }
    }
}
