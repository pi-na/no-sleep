// Renders the app icon (wide-awake face on a night-sky squircle) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Squircle background (macOS icon grid: 824pt body inside 1024 canvas).
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.30, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.62, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.22, alpha: 1)])!
        .draw(in: body, angle: -90)

    // Stars.
    NSColor.white.withAlphaComponent(0.75).setFill()
    for (x, y, d) in [(230.0, 770.0, 14.0), (300, 840, 9), (790, 800, 12), (720, 860, 8), (835, 690, 9), (190, 640, 8)] {
        NSBezierPath(ovalIn: r(x, y, d, d)).fill()
    }

    // Face.
    let face = NSBezierPath(ovalIn: r(232, 192, 560, 560))
    NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.35, alpha: 1).setFill()
    face.fill()
    // Eyes: huge whites with tiny pupils.
    for cx in [402.0, 622.0] {
        NSColor.white.setFill()
        let eye = NSBezierPath(ovalIn: r(cx - 92, 430, 184, 200))
        eye.fill()
        NSColor(calibratedWhite: 0.12, alpha: 1).setStroke()
        eye.lineWidth = 14 * s
        eye.stroke()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(ovalIn: r(cx - 30, 505, 60, 60)).fill()
    }
    // Mouth.
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    NSBezierPath(ovalIn: r(472, 272, 80, 92)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
