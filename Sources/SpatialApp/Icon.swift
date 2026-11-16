import AppKit

/// Spatial's mark: two concentric circles.
/// Shared by the menu bar glyph and the app icon (scripts/make-icon builds
/// the .icns from this same file).
enum SpatialIcon {
    /// Draws the mark centred in `rect`. `weight` is the stroke and `inner`
    /// the inner circle's radius, both relative to the mark's size.
    static func drawMark(in rect: CGRect, color: NSColor, weight: CGFloat, inner: CGFloat = 0.5) {
        let size = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let stroke = size * weight
        color.setStroke()
        let outer = size / 2 - stroke / 2
        for r in [outer, outer * inner] {
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = stroke
            ring.stroke()
        }
    }

    /// The menu bar glyph: an 18 pt template image, drawn as vectors so it
    /// is crisp at any scale.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawMark(in: rect.insetBy(dx: 2.2, dy: 2.2), color: .black, weight: 0.11, inner: 0.48)
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

        drawMark(in: tile.insetBy(dx: 240.5 * s, dy: 240.5 * s), color: .white, weight: 0.07, inner: 0.5)
        return rep
    }
}
