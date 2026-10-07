// Runawake app icon (polished version). Draws gnome designs with depth from light, shadow and gradients.
//   swiftc assets/icon-pro.swift -o /tmp/p && /tmp/p sheet out.png      … comparison sheet
//   /tmp/p --iconset out.iconset P1                                    … export to an iconset
import Cocoa

func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
func hex(_ h: UInt32, _ a: Double = 1) -> NSColor { c(Double((h >> 16) & 0xff) / 255, Double((h >> 8) & 0xff) / 255, Double(h & 0xff) / 255, a) }
var ctx: CGContext { NSGraphicsContext.current!.cgContext }

let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
func tilePath() -> NSBezierPath { NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185) }

func linear(_ path: NSBezierPath, _ colors: [NSColor], angle: CGFloat) { NSGradient(colors: colors)!.draw(in: path, angle: angle) }
func radial(_ center: NSPoint, _ r: CGFloat, _ inner: NSColor, _ outer: NSColor) {
    let g = NSGradient(starting: inner, ending: outer)!
    g.draw(fromCenter: center, radius: 0, toCenter: center, radius: r, options: [])
}
func withShadow(_ color: NSColor, blur: CGFloat, dy: CGFloat, _ body: () -> Void) {
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: color.cgColor); body(); ctx.restoreGState()
}
func clipped(_ path: NSBezierPath, _ body: () -> Void) { ctx.saveGState(); path.addClip(); body(); ctx.restoreGState() }

/// Stars (varied size and brightness)
func stars(seed: Int, count: Int, area: NSRect, color: NSColor) {
    srand48(seed)
    for _ in 0..<count {
        let x = area.minX + drand48() * area.width, y = area.minY + drand48() * area.height
        let r = 2 + drand48() * drand48() * 9, a = 0.25 + drand48() * 0.6
        color.withAlphaComponent(a).setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
    }
}

/// Gnome with a long hat (face hidden under the hat; only a round nose and beard show). cx, base = center of the hat brim
func gnome(cx: CGFloat, base: CGFloat, scale s: CGFloat, capColors: [NSColor], beard: [NSColor], tipLeft: Bool = false) {
    let w = 400 * s, capH = 470 * s
    let L = cx - w / 2, R = cx + w / 2
    let dir: CGFloat = tipLeft ? -1 : 1
    // Hat: rises from the brim, tip folds sideways and droops
    let cap = NSBezierPath()
    // Left hem -> bulges up to the peak, tip folds sideways to a downward point -> back along the inside to the right hem
    let apex = NSPoint(x: cx + dir * 40 * s, y: base + capH)
    let tip = NSPoint(x: cx + dir * 250 * s, y: base + capH * 0.50)
    cap.move(to: NSPoint(x: L, y: base))
    cap.curve(to: apex, controlPoint1: NSPoint(x: L + 10 * s, y: base + capH * 0.60), controlPoint2: NSPoint(x: cx - dir * 70 * s, y: base + capH * 0.98))
    cap.curve(to: tip, controlPoint1: NSPoint(x: cx + dir * 150 * s, y: base + capH * 1.02), controlPoint2: NSPoint(x: cx + dir * 245 * s, y: base + capH * 0.80))
    cap.curve(to: NSPoint(x: cx + dir * 120 * s, y: base + capH * 0.70), controlPoint1: NSPoint(x: cx + dir * 215 * s, y: base + capH * 0.66), controlPoint2: NSPoint(x: cx + dir * 165 * s, y: base + capH * 0.70))
    cap.curve(to: NSPoint(x: R, y: base), controlPoint1: NSPoint(x: cx + dir * 150 * s, y: base + capH * 0.45), controlPoint2: NSPoint(x: R, y: base + capH * 0.25))
    // Brim is a bulging curve (sagging fabric)
    cap.curve(to: NSPoint(x: L, y: base), controlPoint1: NSPoint(x: R - 60 * s, y: base - 34 * s), controlPoint2: NSPoint(x: L + 60 * s, y: base - 34 * s))
    cap.close()

    // Beard (behind the hat): plump teardrop
    let beardP = NSBezierPath()
    beardP.move(to: NSPoint(x: L + 26 * s, y: base - 6 * s))
    beardP.curve(to: NSPoint(x: cx, y: base - 300 * s), controlPoint1: NSPoint(x: L + 10 * s, y: base - 170 * s), controlPoint2: NSPoint(x: cx - 120 * s, y: base - 290 * s))
    beardP.curve(to: NSPoint(x: R - 26 * s, y: base - 6 * s), controlPoint1: NSPoint(x: cx + 120 * s, y: base - 290 * s), controlPoint2: NSPoint(x: R - 10 * s, y: base - 170 * s))
    beardP.close()
    withShadow(NSColor(white: 0, alpha: 0.35), blur: 40 * s, dy: -18 * s) { linear(beardP, beard, angle: -90) }
    // Beard strands (very faint lines)
    clipped(beardP) {
        beard.last!.blended(withFraction: 0.35, of: .black)!.withAlphaComponent(0.14).setStroke()
        for k in -2...2 {
            let p = NSBezierPath(); p.lineWidth = 6 * s; p.lineCapStyle = .round
            let x0 = cx + CGFloat(k) * 52 * s
            p.move(to: NSPoint(x: x0, y: base - 60 * s)); p.curve(to: NSPoint(x: x0 + CGFloat(k) * 8 * s, y: base - 230 * s), controlPoint1: NSPoint(x: x0 - 14 * s, y: base - 120 * s), controlPoint2: NSPoint(x: x0 + 14 * s, y: base - 180 * s))
            p.stroke()
        }
    }
    // Nose: round, lit from above
    let noseR = NSRect(x: cx - 62 * s, y: base - 92 * s, width: 124 * s, height: 112 * s)
    let nose = NSBezierPath(ovalIn: noseR)
    withShadow(NSColor(white: 0, alpha: 0.30), blur: 22 * s, dy: -10 * s) { linear(nose, [hex(0xF6C9A8), hex(0xE39B78)], angle: -90) }
    hex(0xFFFFFF, 0.55).setFill(); NSBezierPath(ovalIn: NSRect(x: noseR.minX + 30 * s, y: noseR.maxY - 40 * s, width: 32 * s, height: 20 * s)).fill()
    // Hat: drop shadow, gradient + left highlight + brim shading
    withShadow(NSColor(white: 0, alpha: 0.40), blur: 36 * s, dy: -16 * s) { linear(cap, capColors, angle: -70) }
    clipped(cap) {
        radial(NSPoint(x: L + 70 * s, y: base + capH * 0.45), 260 * s, NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0))
        linear(NSBezierPath(rect: NSRect(x: L - 20 * s, y: base - 40 * s, width: w + 40 * s, height: 90 * s)), [NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 0.22)], angle: -90)
        // Fold line
        let fold = NSBezierPath(); fold.lineWidth = 7 * s; fold.lineCapStyle = .round
        fold.move(to: NSPoint(x: cx + dir * 30 * s, y: base + capH * 0.86)); fold.curve(to: NSPoint(x: cx + dir * 120 * s, y: base + capH * 0.72), controlPoint1: NSPoint(x: cx + dir * 70 * s, y: base + capH * 0.80), controlPoint2: NSPoint(x: cx + dir * 100 * s, y: base + capH * 0.74))
        NSColor(white: 0, alpha: 0.18).setStroke(); fold.stroke()
    }
}

/// Tile finish: top-edge light, inner border line
func tileFinish() {
    let t = tilePath()
    clipped(t) { linear(NSBezierPath(rect: NSRect(x: 100, y: 700, width: 824, height: 224)), [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)], angle: -90) }
    let inner = NSBezierPath(roundedRect: tileRect.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183); inner.lineWidth = 3
    NSColor(white: 1, alpha: 0.10).setStroke(); inner.stroke()
}

typealias Painter = () -> Void
let designs: [(String, Painter)] = [
    ("P1 Dusk Gnome", {
        let t = tilePath()
        withShadow(NSColor(white: 0, alpha: 0.35), blur: 30, dy: -12) { linear(t, [hex(0x2C3A6E), hex(0x1A1D3F), hex(0x140F26)], angle: -90) }
        clipped(t) {
            radial(NSPoint(x: 512, y: 300), 520, hex(0x7A5A9A, 0.45), hex(0x7A5A9A, 0))     // Violet at the horizon
            stars(seed: 3, count: 34, area: NSRect(x: 130, y: 560, width: 760, height: 340), color: .white)
            radial(NSPoint(x: 512, y: 210), 300, hex(0x000000, 0.35), hex(0x000000, 0))       // Shadow at the feet
        }
        clipped(t) { gnome(cx: 490, base: 450, scale: 0.80, capColors: [hex(0x8FB59A), hex(0x4E7A62), hex(0x2F5244)], beard: [hex(0xF2E6D3), hex(0xC9B49A)]) }
        tileFinish()
    }),
    ("P2 Natural Gnome", {
        let t = tilePath()
        withShadow(NSColor(white: 0, alpha: 0.25), blur: 30, dy: -12) { linear(t, [hex(0xF7F1E6), hex(0xE9DFCE)], angle: -90) }
        clipped(t) { radial(NSPoint(x: 512, y: 200), 260, hex(0x000000, 0.12), hex(0x000000, 0)) }
        clipped(t) { gnome(cx: 490, base: 450, scale: 0.80, capColors: [hex(0x7FA48C), hex(0x46705A), hex(0x2B4B3E)], beard: [hex(0xFFFFFF), hex(0xD9CDBB)]) }
        tileFinish()
    }),
    ("P3 Moonlit Gnome", {
        let t = tilePath()
        withShadow(NSColor(white: 0, alpha: 0.35), blur: 30, dy: -12) { linear(t, [hex(0x1E2A4F), hex(0x0D1226)], angle: -90) }
        clipped(t) {
            radial(NSPoint(x: 285, y: 735), 300, hex(0xFFE7B0, 0.30), hex(0xFFE7B0, 0))
            hex(0xFFF1CC).setFill(); NSBezierPath(ovalIn: NSRect(x: 230, y: 680, width: 110, height: 110)).fill()   // Full moon
            stars(seed: 9, count: 24, area: NSRect(x: 400, y: 600, width: 480, height: 300), color: .white)
            radial(NSPoint(x: 540, y: 200), 280, hex(0x000000, 0.35), hex(0x000000, 0))
        }
        clipped(t) { gnome(cx: 540, base: 430, scale: 0.76, capColors: [hex(0xC97A5A), hex(0x9E4E3A), hex(0x6E3226)], beard: [hex(0xEDE3D4), hex(0xBFAE97)], tipLeft: true) }
        tileFinish()
    }),
]

func render(_ p: Painter, px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024); p()
    NSGraphicsContext.restoreGraphicsState(); return rep
}

let a = CommandLine.arguments
if a.count > 3, a[1] == "--iconset" {
    let p = designs.first { $0.0.hasPrefix(a[3]) }!.1
    try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
    for (n, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
        try! render(p, px: px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(a[2])/\(n).png"))
    }
} else if a.count > 2, a[1] == "sheet" {
    let cell: CGFloat = 340, gap: CGFloat = 40
    let W = CGFloat(designs.count) * (cell + gap) + gap, H = cell + 140
    for (bgName, bg) in [("", NSColor(white: 0.94, alpha: 1))] {
        _ = bgName
        let img = NSImage(size: NSSize(width: W, height: H)); img.lockFocus()
        bg.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        for (i, d) in designs.enumerated() {
            let x = gap + CGFloat(i) * (cell + gap)
            NSImage(cgImage: render(d.1, px: 1024).cgImage!, size: .zero).draw(in: NSRect(x: x, y: 90, width: cell, height: cell))
            for (k, sz) in [32, 64].enumerated() {
                NSImage(cgImage: render(d.1, px: sz * 2).cgImage!, size: .zero).draw(in: NSRect(x: x + cell - CGFloat(sz) - CGFloat(k == 0 ? 76 : 0), y: 20, width: CGFloat(sz), height: CGFloat(sz)))
            }
            (d.0 as NSString).draw(at: NSPoint(x: x + 8, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1)])
        }
        img.unlockFocus()
        try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
    }
}
