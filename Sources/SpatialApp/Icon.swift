import AppKit

/// Spatial's mark: a 5 × 5 grid of dots turned 45° into a diamond, each dot
/// smaller the farther it sits from the middle, like sound fading out.
/// Shared by the menu bar glyph and the app icon (scripts/make-icon builds
/// the .icns from this same file).
enum SpatialIcon {
    /// Draws the mark centred in `rect`, tip to tip across its shorter side.
    /// `center` and `edge` are the radii of the middle dot and the four tip
    /// dots, as fractions of the spacing between neighbouring dots.
    static func drawMark(in rect: CGRect, color: NSColor, center: CGFloat, edge: CGFloat) {
        let size = min(rect.width, rect.height)
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        // Grid point (i, j) sits at ((i - j)h, (i + j)h): the tips are 4h
        // out from the middle and neighbours are h√2 apart.
        let root2 = CGFloat(2).squareRoot()
        let h = size / (8 + 2 * edge * root2)
        let spacing = h * root2
        let farthest = 2 * root2                     // the tips, at grid (±2, ±2)
        color.setFill()
        for i in -2...2 {
            for j in -2...2 {
                let t = CGFloat(i * i + j * j).squareRoot() / farthest   // 0 middle ... 1 tips
                let r = spacing * (center + (edge - center) * t)
                let p = CGPoint(x: mid.x + CGFloat(i - j) * h, y: mid.y + CGFloat(i + j) * h)
                NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
            }
        }
    }

    /// The menu bar glyph: an 18 pt template image, drawn as vectors so it
    /// is crisp at any scale. The tips stay a little bigger than on the app
    /// icon so they survive at menu bar size.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawMark(in: rect.insetBy(dx: 1, dy: 1), color: .black, center: 0.40, edge: 0.17)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Spatial"
        return image
    }

    /// The app icon at `pixels` square, on the macOS icon grid: an 824/1024
    /// rounded square with a soft shadow, black with a faint top light,
    /// the mark in white.
    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let s = CGFloat(pixels) / 1024
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

        // Drop shadow, as on Apple's own icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 24 * s
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Body: near-black with a faint light from the top.
        NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))!
            .draw(in: shape, angle: -90)
        // Hairline rim so it reads on a black Dock.
        NSColor(white: 1, alpha: 0.12).setStroke()
        let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s),
                               xRadius: 184 * s, yRadius: 184 * s)
        rim.lineWidth = max(1, 3 * s)
        rim.stroke()

        drawMark(in: tile.insetBy(dx: 150 * s, dy: 150 * s), color: .white, center: 0.42, edge: 0.12)
        return rep
    }
}
