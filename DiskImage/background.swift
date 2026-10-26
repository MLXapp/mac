// The disk image window's background (0.9.8+): `swift mac/DiskImage/background.swift <out dir>` writes background.png
// (560 × 400) and background@2x.png, drawn with the system font (SF Pro) on the Mac that builds the image.
// The app icon sits at (280, 150) from the top left (mac/DiskImage/settings.py); the words go under its label.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
let W: CGFloat = 560, H: CGFloat = 400
let icon = CGPoint(x: 280, y: 150)  // from the top left, as Finder places it

let paper = NSColor(srgbRed: 0.973, green: 0.973, blue: 0.976, alpha: 1)
let ink = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
let orange = NSColor(srgbRed: 0.941, green: 0.541, blue: 0.0, alpha: 1)
let quiet = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)

func draw() {
    paper.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    // a soft orange glow behind the icon
    let centre = NSPoint(x: icon.x, y: H - icon.y)
    if let glow = NSGradient(colors: [orange.withAlphaComponent(0.16), orange.withAlphaComponent(0.05), orange.withAlphaComponent(0)],
                             atLocations: [0, 0.55, 1], colorSpace: .sRGB) {
        glow.draw(fromCenter: centre, radius: 0, toCenter: centre, radius: 170, options: [])
    }
    func line(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centreY: CGFloat) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
        let s = NSAttributedString(string: text, attributes: attrs)
        let h = s.size().height
        s.draw(in: NSRect(x: 20, y: H - centreY - h / 2, width: W - 40, height: h))
    }
    line("Open MLX Node to install", size: 20, weight: .semibold, color: ink, centreY: 276)
    line("Double-click MLX Node, then click Install.", size: 13, weight: .regular, color: quiet, centreY: 304)
}

for scale in [1, 2] {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("no bitmap") }
    rep.size = NSSize(width: W, height: H)  // points, so @2x draws the same layout sharper
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    draw()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    let file = out.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png")
    try png.write(to: file)
    print("\(file.path): \(rep.pixelsWide)×\(rep.pixelsHigh)")
}
