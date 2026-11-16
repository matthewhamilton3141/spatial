import AppKit

// Built by build.sh together with Sources/SpatialApp/Icon.swift.
//   make-icon iconset <dir>   writes the PNGs iconutil turns into Spatial.icns
//   make-icon preview <dir>   writes look-at-it renders (icon on light/dark, menu bar glyph)

extension NSBitmapImageRep {
    /// Draws composited over what's there (plain draw(in:) copies, alpha and all).
    func over(_ r: CGRect) {
        draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// Draws into a fresh bitmap of `w`x`h` pixels.
func canvas(_ w: Int, _ h: Int, _ draw: (CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make-icon iconset|preview <dir>"); exit(1) }
let dir = args[2]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

switch args[1] {
case "iconset":
    for points in [16, 32, 128, 256, 512] {
        save(SpatialIcon.appIcon(pixels: points), "\(dir)/icon_\(points)x\(points).png")
        save(SpatialIcon.appIcon(pixels: points * 2), "\(dir)/icon_\(points)x\(points)@2x.png")
    }
case "preview":
    // App icon on a light and a dark desktop, large and at Dock-ish size.
    for (name, bg) in [("light", NSColor(white: 0.93, alpha: 1)), ("dark", NSColor(white: 0.12, alpha: 1))] {
        let big = SpatialIcon.appIcon(pixels: 512), small = SpatialIcon.appIcon(pixels: 128)
        save(canvas(760, 560) { r in
            bg.setFill(); r.fill()
            big.over(CGRect(x: 20, y: 24, width: 512, height: 512))
            small.over(CGRect(x: 580, y: 216, width: 128, height: 128))
            SpatialIcon.appIcon(pixels: 32).over(CGRect(x: 628, y: 120, width: 32, height: 32))
        }, "\(dir)/appicon-\(name).png")
    }
    // Menu bar glyph at 1x and 2x on light and dark bars, live and dimmed,
    // each blown up 8x (nearest neighbour) so pixels are visible.
    let glyph = SpatialIcon.menuBarImage()
    for scale in [1, 2] {
        for (name, bar, ink) in [("light", NSColor(white: 0.96, alpha: 1), NSColor.black),
                                 ("dark", NSColor(white: 0.16, alpha: 1), NSColor.white)] {
            let px = 18 * scale
            func tinted(_ alpha: CGFloat) -> NSBitmapImageRep {
                // Tint the template the way the menu bar does, then put it on the bar.
                let ink = canvas(px, px) { r in
                    glyph.draw(in: r)
                    ink.withAlphaComponent(alpha).set()
                    r.fill(using: .sourceAtop)
                }
                return canvas(px + 8 * scale, px + 6 * scale) { r in
                    bar.setFill(); r.fill()
                    ink.over(CGRect(x: 4 * scale, y: 3 * scale, width: px, height: px))
                }
            }
            let live = tinted(0.85), dim = tinted(0.3)
            let zoom = 8 / scale
            save(canvas(live.pixelsWide * 2 * zoom + 8, live.pixelsHigh * zoom) { r in
                NSColor.gray.setFill(); r.fill()
                live.over(CGRect(x: 0, y: 0, width: live.pixelsWide * zoom, height: live.pixelsHigh * zoom))
                dim.over(CGRect(x: live.pixelsWide * zoom + 8, y: 0,
                                    width: dim.pixelsWide * zoom, height: dim.pixelsHigh * zoom))
            }, "\(dir)/menubar-\(name)@\(scale)x.png")
        }
    }
default:
    print("unknown mode \(args[1])"); exit(1)
}
