import Cocoa
// Simple icon designs, drawn in 1024 coordinates
typealias Painter = () -> Void
func tile(_ top: NSColor, _ bottom: NSColor) -> NSBezierPath {
    let t = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(colors: [top, bottom])!.draw(in: t, angle: -90); return t
}
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: a) }
let navyT = c(0.13, 0.17, 0.36), navyB = c(0.05, 0.07, 0.17)
let cream = c(0.99, 0.94, 0.80)
func crescent(_ rect: NSRect, cut: NSPoint, bg: NSColor, fg: NSColor) {
    // Cut out the missing part instead of filling with the background color (no seams over gradients)
    let ctx = NSGraphicsContext.current!.cgContext; ctx.saveGState()
    let clip = NSBezierPath(rect: NSRect(x: -2000, y: -2000, width: 6000, height: 6000))
    clip.append(NSBezierPath(ovalIn: NSRect(x: rect.minX + cut.x, y: rect.minY + cut.y, width: rect.width, height: rect.height)))
    clip.windingRule = .evenOdd; clip.addClip()
    fg.setFill(); NSBezierPath(ovalIn: rect).fill()
    ctx.restoreGState()
}
func steam(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat, width: CGFloat, color: NSColor) {
    let p = NSBezierPath(); p.lineWidth = width; p.lineCapStyle = .round
    p.move(to: NSPoint(x: x, y: y)); p.curve(to: NSPoint(x: x, y: y + h), controlPoint1: NSPoint(x: x - h * 0.35, y: y + h * 0.33), controlPoint2: NSPoint(x: x + h * 0.35, y: y + h * 0.66))
    color.setStroke(); p.stroke()
}
func cup(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, color: NSColor, stroke: Bool, lw: CGFloat = 28) {
    let body = NSBezierPath()
    body.move(to: NSPoint(x: x, y: y + w * 0.75)); body.line(to: NSPoint(x: x + w, y: y + w * 0.75))
    body.curve(to: NSPoint(x: x, y: y + w * 0.75), controlPoint1: NSPoint(x: x + w, y: y - w * 0.15), controlPoint2: NSPoint(x: x, y: y - w * 0.15))
    let handle = NSBezierPath(ovalIn: NSRect(x: x + w * 0.90, y: y + w * 0.30, width: w * 0.30, height: w * 0.30))
    color.set(); handle.lineWidth = lw * 0.8; handle.stroke()
    if stroke { body.lineWidth = lw; body.lineJoinStyle = .round; body.stroke() } else { body.fill() }
}
let variants: [(String, Painter)] = [
    ("A Crescent Moon", {
        let bg = c(0.09, 0.12, 0.27); _ = tile(navyT, navyB)
        crescent(NSRect(x: 300, y: 300, width: 420, height: 420), cut: NSPoint(x: 120, y: 90), bg: bg, fg: cream)
        NSColor(white: 1, alpha: 0.8).setFill(); NSBezierPath(ovalIn: NSRect(x: 690, y: 680, width: 22, height: 22)).fill()
    }),
    ("B Hat Only", {
        _ = tile(c(0.16, 0.19, 0.30), c(0.08, 0.09, 0.15))
        let h = NSBezierPath(); h.move(to: NSPoint(x: 300, y: 330)); h.line(to: NSPoint(x: 724, y: 330))
        h.curve(to: NSPoint(x: 560, y: 780), controlPoint1: NSPoint(x: 680, y: 520), controlPoint2: NSPoint(x: 600, y: 700))
        h.curve(to: NSPoint(x: 700, y: 700), controlPoint1: NSPoint(x: 620, y: 800), controlPoint2: NSPoint(x: 690, y: 770))
        h.curve(to: NSPoint(x: 300, y: 330), controlPoint1: NSPoint(x: 560, y: 690), controlPoint2: NSPoint(x: 360, y: 560)); h.close()
        c(0.82, 0.30, 0.28).setFill(); h.fill()
        NSColor(white: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 280, y: 300, width: 464, height: 56), xRadius: 28, yRadius: 28).fill()
    }),
    ("C Steaming Cup", {
        _ = tile(c(0.20, 0.17, 0.15), c(0.10, 0.08, 0.07))
        cup(330, 330, 320, color: cream, stroke: true, lw: 34)
        for dx in [410.0, 490.0, 570.0] { steam(dx, 610, 150, width: 26, color: cream.withAlphaComponent(0.85)) }
    }),
    ("D Moon as Steam", {
        let bg = c(0.09, 0.12, 0.27); _ = tile(navyT, navyB)
        cup(330, 300, 320, color: cream, stroke: false)
        crescent(NSRect(x: 440, y: 590, width: 190, height: 190), cut: NSPoint(x: 60, y: 40), bg: bg.blended(withFraction: 0.1, of: navyT)!, fg: cream)
    }),
    ("E Lit Window at Night", {
        _ = tile(navyT, navyB)
        let house = NSBezierPath(); house.move(to: NSPoint(x: 300, y: 260)); house.line(to: NSPoint(x: 300, y: 560))
        house.line(to: NSPoint(x: 512, y: 740)); house.line(to: NSPoint(x: 724, y: 560)); house.line(to: NSPoint(x: 724, y: 260)); house.close()
        c(0.03, 0.04, 0.10).setFill(); house.fill()
        c(1.0, 0.82, 0.45).setFill(); NSBezierPath(roundedRect: NSRect(x: 452, y: 390, width: 120, height: 120), xRadius: 14, yRadius: 14).fill()
        NSColor(white: 1, alpha: 0.85).setFill(); NSBezierPath(ovalIn: NSRect(x: 690, y: 760, width: 24, height: 24)).fill()
    }),
    ("F Hat + Moon", {
        let bg = c(0.09, 0.12, 0.27); _ = tile(navyT, navyB)
        let h = NSBezierPath(); h.move(to: NSPoint(x: 330, y: 320)); h.line(to: NSPoint(x: 694, y: 320)); h.line(to: NSPoint(x: 512, y: 700)); h.close()
        cream.setFill(); h.fill()
        crescent(NSRect(x: 600, y: 640, width: 160, height: 160), cut: NSPoint(x: 52, y: 34), bg: bg, fg: cream)
    }),
]

// ── Gnome designs (avoid white trim, pom-pom, and red + white beard so it doesn't look like Santa)
let moss = c(0.36, 0.52, 0.38), mossD = c(0.24, 0.36, 0.27), skin = c(0.96, 0.80, 0.66), lamp = c(1.0, 0.80, 0.42)
func cap(_ base: CGFloat, _ left: CGFloat, _ right: CGFloat, tipX: CGFloat, tipY: CGFloat, droop: CGFloat, color: NSColor) {
    let h = NSBezierPath(); h.move(to: NSPoint(x: left, y: base)); h.line(to: NSPoint(x: right, y: base))
    h.curve(to: NSPoint(x: tipX, y: tipY), controlPoint1: NSPoint(x: right - 20, y: base + (tipY - base) * 0.5), controlPoint2: NSPoint(x: tipX + droop * 0.2, y: tipY - 40))
    h.curve(to: NSPoint(x: left, y: base), controlPoint1: NSPoint(x: tipX - 60, y: tipY - 60), controlPoint2: NSPoint(x: left + 10, y: base + (tipY - base) * 0.45))
    h.close(); color.setFill(); h.fill()
}
func glow(_ center: NSPoint, _ r: CGFloat) {
    NSGradient(colors: [lamp.withAlphaComponent(0.55), lamp.withAlphaComponent(0)])!.draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), relativeCenterPosition: .zero)
}
let gnomeVariants: [(String, Painter)] = [
    ("G Lantern Gnome", {
        _ = tile(navyT, navyB)
        glow(NSPoint(x: 640, y: 380), 210)
        // Body (cloak, moss green)
        let body = NSBezierPath(); body.move(to: NSPoint(x: 360, y: 260)); body.line(to: NSPoint(x: 600, y: 260))
        body.curve(to: NSPoint(x: 480, y: 560), controlPoint1: NSPoint(x: 600, y: 420), controlPoint2: NSPoint(x: 560, y: 540))
        body.curve(to: NSPoint(x: 360, y: 260), controlPoint1: NSPoint(x: 400, y: 540), controlPoint2: NSPoint(x: 360, y: 420)); body.close()
        mossD.setFill(); body.fill()
        skin.setFill(); NSBezierPath(ovalIn: NSRect(x: 450, y: 500, width: 60, height: 60)).fill()          // Nose (face under the hat)
        cap(560, 390, 570, tipX: 330, tipY: 790, droop: 0, color: moss)                                       // Long hat with the tip drooping backward
        // Lantern
        NSColor(white: 0.85, alpha: 1).setStroke(); let arm = NSBezierPath(); arm.lineWidth = 16; arm.lineCapStyle = .round
        arm.move(to: NSPoint(x: 580, y: 420)); arm.line(to: NSPoint(x: 640, y: 450)); arm.stroke()
        lamp.setFill(); NSBezierPath(roundedRect: NSRect(x: 605, y: 330, width: 70, height: 100), xRadius: 18, yRadius: 18).fill()
    }),
    ("H Hatted Gnome Face", {
        _ = tile(c(0.16, 0.20, 0.30), c(0.07, 0.09, 0.15))
        skin.setFill(); NSBezierPath(ovalIn: NSRect(x: 452, y: 360, width: 120, height: 110)).fill()           // Round nose
        cap(450, 280, 744, tipX: 640, tipY: 860, droop: 0, color: moss)
        c(0.75, 0.66, 0.55).setFill()                                                                         // Short beard (brown)
        let b = NSBezierPath(); b.move(to: NSPoint(x: 330, y: 440)); b.curve(to: NSPoint(x: 694, y: 440), controlPoint1: NSPoint(x: 380, y: 200), controlPoint2: NSPoint(x: 644, y: 200))
        b.curve(to: NSPoint(x: 330, y: 440), controlPoint1: NSPoint(x: 600, y: 400), controlPoint2: NSPoint(x: 424, y: 400)); b.fill()
        skin.setFill(); NSBezierPath(ovalIn: NSRect(x: 452, y: 380, width: 120, height: 100)).fill()
    }),
    ("I Gnome and Moon", {
        _ = tile(navyT, navyB)
        crescent(NSRect(x: 560, y: 600, width: 220, height: 220), cut: NSPoint(x: 70, y: 46), bg: .clear, fg: cream)
        mossD.setFill(); NSBezierPath(roundedRect: NSRect(x: 360, y: 250, width: 200, height: 230), xRadius: 90, yRadius: 90).fill()
        skin.setFill(); NSBezierPath(ovalIn: NSRect(x: 425, y: 440, width: 70, height: 66)).fill()
        cap(470, 330, 590, tipX: 380, tipY: 820, droop: 0, color: moss)
    }),
    ("J Hat and Light", {
        _ = tile(c(0.13, 0.16, 0.24), c(0.06, 0.07, 0.12))
        glow(NSPoint(x: 512, y: 330), 230)
        cap(360, 300, 724, tipX: 620, tipY: 830, droop: 0, color: moss)
        lamp.setFill(); NSBezierPath(ovalIn: NSRect(x: 482, y: 300, width: 60, height: 60)).fill()
    }),
]

let cell: CGFloat = 256, small: CGFloat = 32, cols = 3, padX: CGFloat = 30
let W = CGFloat(cols) * (cell + padX) + padX, H = CGFloat(CommandLine.arguments.contains("gnomes") ? 2 : 2) * (cell + 80) + 20
let sheet = NSImage(size: NSSize(width: W, height: H)); sheet.lockFocus()
NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
// --iconset <dir> <design prefix>: export that design to an .iconset and exit
if let i = CommandLine.arguments.firstIndex(of: "--iconset") {
    let out = CommandLine.arguments[i + 1], pick = CommandLine.arguments[i + 2]
    let painter = (variants + gnomeVariants).first { $0.0.hasPrefix(pick) }!.1
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for (n, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024); painter()
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(n).png"))
    }
    exit(0)
}
let shown = CommandLine.arguments.contains("gnomes") ? gnomeVariants : variants
for (i, v) in shown.enumerated() {
    let col = i % cols, row = i / cols
    let x = padX + CGFloat(col) * (cell + padX), y = H - CGFloat(row + 1) * (cell + 80)
    for (sz, ox, oy) in [(cell, x, y + 50), (small, x + cell - small, y + 8)] {
        let ctx = NSGraphicsContext.current!.cgContext; ctx.saveGState()
        ctx.translateBy(x: ox, y: oy); ctx.scaleBy(x: sz / 1024, y: sz / 1024); v.1(); ctx.restoreGState()
    }
    (v.0 as NSString).draw(at: NSPoint(x: x, y: y + 14), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1)])
}
sheet.unlockFocus()
try! NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
