import AppKit
import SwiftUI

/// The MLX emblem: the X from the site, white on the ink-to-orange gradient.
enum BrandMark {
    static let ink = Color(red: 0.114, green: 0.114, blue: 0.122)
    static let orange = Color(red: 0.941, green: 0.541, blue: 0.0)
    static let gradient = LinearGradient(colors: [ink, orange], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The X outline in the 7×11 box the site uses (viewBox 8.5 6.5 7 11).
    static func xPath(in r: CGRect) -> CGPath {
        let pts: [(CGFloat, CGFloat)] = [(9, 7), (11, 12), (9, 17), (11, 17), (12, 14.5), (13, 17), (15, 17), (13, 12), (15, 7), (13, 7), (12, 9.5), (11, 7)]
        let s = min(r.width / 7, r.height / 11)
        let ox = r.midX - 3.5 * s, oy = r.midY - 5.5 * s
        let p = CGMutablePath()
        for (i, (x, y)) in pts.enumerated() {
            let pt = CGPoint(x: ox + (x - 8.5) * s, y: oy + (y - 6.5) * s)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }

    /// Menu bar icon: the MDI "alpha-x-box" glyph (pictogrammers.com/library/mdi/icon/alpha-x-box), a rounded square
    /// with the X cut out. A template image (follows light and dark menu bars) while MLX isn't mining; filled with the
    /// brand orange while it mines (the Mac is eligible to earn: working, or ready and waiting for the next job).
    static func menuIcon(mining: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(mining ? NSColor(srgbRed: 0.941, green: 0.541, blue: 0.0, alpha: 1).cgColor : NSColor.black.cgColor)
            ctx.addPath(boxPath(in: rect.insetBy(dx: 1.5, dy: 1.5)))
            ctx.fillPath(using: .evenOdd)
            return true
        }
        img.isTemplate = !mining
        img.accessibilityDescription = mining ? "MLX Node, mining" : "MLX Node"
        return img
    }

    /// MDI alpha-x-box in its 24-unit grid (box 3…21, corner radius 2, the X from xPath), fitted to `r`.
    /// Filled even-odd, the X is a hole in the box.
    static func boxPath(in r: CGRect) -> CGPath {
        let s = min(r.width, r.height) / 18
        let ox = r.midX - 9 * s, oy = r.midY - 9 * s
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: ox, y: oy, width: 18 * s, height: 18 * s), cornerWidth: 2 * s, cornerHeight: 2 * s)
        let pts: [(CGFloat, CGFloat)] = [(9, 7), (11, 12), (9, 17), (11, 17), (12, 14.5), (13, 17), (15, 17), (13, 12), (15, 7), (13, 7), (12, 9.5), (11, 7)]
        for (i, (x, y)) in pts.enumerated() {
            let pt = CGPoint(x: ox + (x - 3) * s, y: oy + (y - 3) * s)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

struct XShape: Shape {
    func path(in rect: CGRect) -> Path { Path(BrandMark.xPath(in: rect)) }
}

/// The app icon in SwiftUI: rounded square, gradient, white X.
struct Emblem: View {
    var size: CGFloat = 56
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(BrandMark.gradient)
            .frame(width: size, height: size)
            .overlay(XShape().fill(.white).frame(width: size * 0.36, height: size * 0.56))
            .shadow(color: BrandMark.orange.opacity(0.25), radius: size * 0.18, y: size * 0.08)
    }
}
