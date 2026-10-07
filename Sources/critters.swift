import Cocoa

/// Menu bar icons. Each has animation frames shown while something runs, an idle image and an off image,
/// drawn in code at 24x16pt and rasterized once as template images (black + alpha; macOS tints them).
struct Critter {
    let id: String
    let name: String
    let run: [NSImage]
    let idle: NSImage
    let off: NSImage

    static let all: [Critter] = [equalizer, ball, pulse, dots, orbit, breathe, stripes]
    static func named(_ id: String?) -> Critter { all.first { $0.id == id } ?? equalizer }

    private static func frames(_ n: Int, _ draw: @escaping (CGFloat) -> Void) -> [NSImage] {
        (0..<n).map { i in let t = CGFloat(i) / CGFloat(n); return Draw.image { draw(t) } }
    }
    private static func faint(_ a: CGFloat = 0.45) { NSColor.black.withAlphaComponent(a).set() }
    private static func solid() { NSColor.black.set() }

    // MARK: bouncing ball — squashes when it lands
    static let ball = Critter(
        id: "ball", name: T("跳ねるボール", "Bouncing Ball"),
        run: frames(14) { t in
            let h = abs(sin(t * .pi)), squash = h < 0.15 ? 1.25 - h : 1
            Draw.oval(12 - 2.6 * squash, 2 + 9 * h, 5.2 * squash, 5.2 / squash).fill()
            faint(0.25 + 0.3 * (1 - h)); Draw.oval(12 - 3 * (1 - 0.4 * h), 0.6, 6 * (1 - 0.4 * h), 1.2).fill(); solid()
        },
        idle: Draw.image { Draw.oval(9.4, 2.0, 5.2, 5.2).fill(); faint(0.4); Draw.oval(9, 0.6, 6, 1.2).fill() },
        off: Draw.image { faint(); Draw.oval(8.5, 1, 7, 3).fill(); solid(); Draw.slash() })

    // MARK: heartbeat — a trace scrolling by
    static let pulse = Critter(
        id: "pulse", name: T("心拍", "Heartbeat"),
        run: frames(16) { t in
            let pts: [(CGFloat, CGFloat)] = [(0, 8), (6, 8), (8, 11), (10, 3), (12, 14), (14, 6), (16, 8), (24, 8)]
            let ctx = NSGraphicsContext.current!.cgContext
            for offset in [-24.0, 0.0] as [CGFloat] {
                ctx.saveGState(); ctx.translateBy(x: offset + t * 24, y: 0)
                Draw.stroke(1.5) { p in p.move(to: NSPoint(x: pts[0].0, y: pts[0].1)); for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) } }
                ctx.restoreGState()
            }
        },
        idle: Draw.image { flatLine() },
        off: Draw.image { faint(); flatLine(); solid(); Draw.slash() })
    private static func flatLine() { Draw.stroke(1.5) { p in p.move(to: NSPoint(x: 2, y: 8)); p.line(to: NSPoint(x: 22, y: 8)) } }

    // MARK: spinning dots — a loading ring
    static let dots = Critter(
        id: "dots", name: T("回る点", "Spinning Dots"),
        run: frames(8) { t in
            for k in 0..<8 {
                let lag = (CGFloat(k) / 8 - t + 1).truncatingRemainder(dividingBy: 1)
                faint(0.2 + 0.8 * (1 - lag)); ringDot(k, 1.35).fill()
            }
            solid()
        },
        idle: Draw.image { faint(0.7); for k in 0..<8 { ringDot(k, 1.35).fill() } },
        off: Draw.image { faint(0.35); for k in 0..<8 { ringDot(k, 1.1).fill() }; solid(); Draw.slash() })
    private static func ringDot(_ k: Int, _ r: CGFloat) -> NSBezierPath {
        let a = CGFloat(k) / 8 * 2 * .pi
        return Draw.oval(12 + 5.6 * sin(a) - r, 8 + 5.6 * cos(a) - r, r * 2, r * 2)
    }

    // MARK: equalizer — bars rising and falling
    static let equalizer = Critter(
        id: "equalizer", name: T("イコライザー", "Equalizer"),
        run: frames(16) { t in
            for k in 0..<4 { bar(k, 3 + 9 * abs(sin((t + CGFloat(k) * 0.23) * 2 * .pi))) }
        },
        idle: Draw.image { for k in 0..<4 { bar(k, 3) } },
        off: Draw.image { faint(); for k in 0..<4 { bar(k, 2.2) }; solid(); Draw.slash() })
    private static func bar(_ k: Int, _ h: CGFloat) {
        NSBezierPath(roundedRect: NSRect(x: 6 + CGFloat(k) * 3.4, y: 2, width: 2.2, height: h), xRadius: 1.1, yRadius: 1.1).fill()
    }

    // MARK: orbit — a dot circling a planet
    static let orbit = Critter(
        id: "orbit", name: T("周回する衛星", "Orbit"),
        run: frames(16) { t in
            planet()
            let a = t * 2 * .pi
            Draw.oval(12 + 6 * sin(a) - 1.6, 8 + 6 * cos(a) - 1.6, 3.2, 3.2).fill()
        },
        idle: Draw.image { planet(); Draw.oval(10.4, 12.4, 3.2, 3.2).fill() },
        off: Draw.image { faint(0.35); planet(); solid(); Draw.slash() })
    private static func planet() {
        faint(); Draw.stroke(1.0) { p in p.appendOval(in: NSRect(x: 6, y: 2, width: 12, height: 12)) }
        solid(); Draw.oval(9.6, 5.6, 4.8, 4.8).fill()
    }

    // MARK: breathing circle — slowly swells
    static let breathe = Critter(
        id: "breathe", name: T("呼吸する円", "Breathing Circle"),
        run: frames(20) { t in
            let k = 0.5 - 0.5 * cos(t * 2 * .pi)
            faint(0.25 * (1 - k)); let r1 = 4 + 3.5 * k; Draw.oval(12 - r1, 8 - r1, r1 * 2, r1 * 2).fill()
            solid(); let r2 = 3.2 + 1.2 * k; Draw.oval(12 - r2, 8 - r2, r2 * 2, r2 * 2).fill()
        },
        idle: Draw.image { Draw.oval(8.6, 4.6, 6.8, 6.8).fill() },
        off: Draw.image { faint(); Draw.stroke(1.2) { p in p.appendOval(in: NSRect(x: 8.6, y: 4.6, width: 6.8, height: 6.8)) }; solid(); Draw.slash() })

    // MARK: stripes — a progress bar with moving stripes
    static let stripes = Critter(
        id: "stripes", name: T("流れる縞", "Progress Stripes"),
        run: frames(8) { t in
            let capsule = progressBar(); capsule.stroke()
            NSGraphicsContext.current!.cgContext.saveGState(); capsule.addClip()
            for k in -2..<8 {
                let x = 3 + CGFloat(k) * 4 + t * 4
                let s = NSBezierPath(); s.move(to: NSPoint(x: x, y: 5)); s.line(to: NSPoint(x: x + 2, y: 5)); s.line(to: NSPoint(x: x + 4, y: 11)); s.line(to: NSPoint(x: x + 2, y: 11)); s.close(); s.fill()
            }
            NSGraphicsContext.current!.cgContext.restoreGState()
        },
        idle: Draw.image { progressBar().stroke() },
        off: Draw.image { faint(); progressBar().stroke(); solid(); Draw.slash() })
    private static func progressBar() -> NSBezierPath {
        let p = NSBezierPath(roundedRect: NSRect(x: 3, y: 5, width: 18, height: 6), xRadius: 3, yRadius: 3); p.lineWidth = 1.2; return p
    }
}

/// Drawing helpers shared by the icons.
enum Draw {
    static let size = NSSize(width: 24, height: 16)
    /// Empty image the size of an icon (keeps the status item's width while a layer draws the animation).
    static let blank: NSImage = { let i = NSImage(size: size); i.isTemplate = true; return i }()

    /// Rasterized once at 2x so the menu bar does not redraw paths on every animation frame.
    static func image(_ draw: () -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size); img.addRepresentation(rep); img.isTemplate = true
        return img
    }
    /// The icon as a 2x bitmap in one solid color, keeping its alpha (layers cannot apply template tinting).
    static func tinted(_ img: NSImage, _ color: NSColor) -> CGImage? {
        let w = Int(size.width * 2), h = Int(size.height * 2)
        guard let mask = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clip(to: r, mask: mask)
        ctx.setFillColor(color.cgColor); ctx.fill(r)
        return ctx.makeImage()
    }
    static func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: w, height: h)) }
    static func stroke(_ w: CGFloat, _ build: (NSBezierPath) -> Void) {
        let p = NSBezierPath(); p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; build(p); p.stroke()
    }
    static func slash() { stroke(1.4) { p in p.move(to: NSPoint(x: 5, y: 1.5)); p.line(to: NSPoint(x: 19, y: 14.5)) } }
}
