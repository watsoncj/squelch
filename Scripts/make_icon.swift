// Renders the RadioFun app icon at all required sizes.
// Usage: swift Scripts/make_icon.swift <output-dir>
// Design: blue→teal gradient squircle, faint Maidenhead-grid texture,
// concentric radio-wave arcs from a station dot, one amber "heard" cell.
import AppKit
import CoreGraphics

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    let s = canvas / 1024.0 // design in 1024-space
    func pt(_ v: CGFloat) -> CGFloat { v * s }

    // macOS icon grid: 824×824 squircle centered in 1024
    let inset = pt(100)
    let squircle = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let path = CGPath(roundedRect: squircle, cornerWidth: pt(185), cornerHeight: pt(185), transform: nil)

    // Soft shadow like the system template
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -pt(10)), blur: pt(24),
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.22, blue: 0.55, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Diagonal gradient: deep blue (top-left) → teal (bottom-right)
    let colors = [
        CGColor(red: 0.135, green: 0.26, blue: 0.80, alpha: 1),
        CGColor(red: 0.10, green: 0.46, blue: 0.86, alpha: 1),
        CGColor(red: 0.05, green: 0.66, blue: 0.79, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: inset, y: canvas - inset),
                           end: CGPoint(x: canvas - inset, y: inset),
                           options: [])

    // Faint Maidenhead grid texture (Zed's blueprint, our meaning)
    let cell = squircle.width / 8
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
    ctx.setLineWidth(pt(3))
    for i in 1..<8 {
        let x = squircle.minX + CGFloat(i) * cell
        ctx.move(to: CGPoint(x: x, y: squircle.minY))
        ctx.addLine(to: CGPoint(x: x, y: squircle.maxY))
        let y = squircle.minY + CGFloat(i) * cell
        ctx.move(to: CGPoint(x: squircle.minX, y: y))
        ctx.addLine(to: CGPoint(x: squircle.maxX, y: y))
    }
    ctx.strokePath()

    // The app's signature scene: my station (dot, lower-left), a heard
    // station's amber grid cell (upper-right), and the great-circle arc
    // between them — with two staggered signal arcs at the dot.
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let origin = CGPoint(x: pt(320), y: pt(320))

    // Amber "heard" cell, snapped to the grid
    let cellRect = CGRect(x: squircle.minX + 6 * cell, y: squircle.minY + 6 * cell,
                          width: cell, height: cell).insetBy(dx: pt(6), dy: pt(6))
    ctx.setFillColor(CGColor(red: 1.0, green: 0.72, blue: 0.20, alpha: 0.95))
    ctx.addPath(CGPath(roundedRect: cellRect, cornerWidth: pt(18), cornerHeight: pt(18), transform: nil))
    ctx.fillPath()

    // Great-circle arc: dot → cell, a single pronounced bow (up-left),
    // stopping short of each endpoint
    let target = CGPoint(x: cellRect.midX, y: cellRect.midY)
    let mid = CGPoint(x: (origin.x + target.x) / 2, y: (origin.y + target.y) / 2)
    let control = CGPoint(x: mid.x - pt(150), y: mid.y + pt(230))
    ctx.setStrokeColor(white)
    ctx.setLineWidth(pt(44))
    ctx.setLineCap(.round)
    ctx.move(to: origin)
    ctx.addQuadCurve(to: target, control: control)
    ctx.strokePath()

    // Station dot with halo ring — the map's "me" marker
    ctx.setFillColor(white)
    ctx.fillEllipse(in: CGRect(x: origin.x - pt(62), y: origin.y - pt(62),
                               width: pt(124), height: pt(124)))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
    ctx.setLineWidth(pt(30))
    ctx.strokeEllipse(in: CGRect(x: origin.x - pt(118), y: origin.y - pt(118),
                                 width: pt(236), height: pt(236)))

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    let image = drawIcon(canvas: CGFloat(pixels))
    writePNG(image, to: iconset.appendingPathComponent("\(name).png"), pixels: pixels)
}
print("iconset written to \(iconset.path)")
