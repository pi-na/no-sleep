// Composes README artwork from UI snapshots.
// Usage: swift scripts/make-readme-art.swift <snapshots dir> <app icon png> <output dir>
import AppKit

let args = CommandLine.arguments
let shots = URL(fileURLWithPath: args[1])
let iconImage = NSImage(contentsOfFile: args[2])!
let output = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let scale: CGFloat = 2

func image(_ name: String) -> NSImage {
    let image = NSImage(contentsOf: shots.appendingPathComponent(name))!
    // Snapshots are @2x bitmaps: use point size.
    let rep = image.representations[0]
    image.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
    return image
}

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

func render(width: CGFloat, height: CGFloat, to name: String, draw: (NSRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

/// Draws a panel screenshot as a floating macOS window: rounded, hairline border, soft shadow.
func drawPanel(_ panel: NSImage, at origin: NSPoint, dark: Bool) {
    let rect = NSRect(origin: origin, size: panel.size)
    let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.22)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    panel.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setStroke()
    path.lineWidth = 1
    path.stroke()
}

func drawStars(in rect: NSRect, count: Int) {
    var seed: UInt64 = 42
    func next() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
    }
    for _ in 0..<count {
        let d = 1 + next() * 2.2
        NSColor.white.withAlphaComponent(0.25 + next() * 0.5).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + next() * rect.width, y: rect.minY + next() * rect.height,
                                    width: d, height: d)).fill()
    }
}

func awakeFace(size: CGFloat, color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let k = size / 18
        color.set()
        let face = NSBezierPath(ovalIn: NSRect(x: 0.9 * k, y: 0.9 * k, width: 16.2 * k, height: 16.2 * k))
        face.lineWidth = 1.5 * k
        face.stroke()
        for cx in [6.0, 12.0] {
            let eye = NSBezierPath(ovalIn: NSRect(x: (cx - 2.65) * k, y: 8.3 * k, width: 5.3 * k, height: 5.6 * k))
            eye.lineWidth = 1.2 * k
            eye.stroke()
            NSBezierPath(ovalIn: NSRect(x: (cx - 1.05) * k, y: 10.05 * k, width: 2.1 * k, height: 2.1 * k)).fill()
        }
        let mouth = NSBezierPath(ovalIn: NSRect(x: 7.6 * k, y: 3.4 * k, width: 2.8 * k, height: 2.6 * k))
        mouth.lineWidth = 1.2 * k
        mouth.stroke()
        return true
    }
}

func symbol(_ name: String, size: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

// MARK: Hero

let panel = image("menu-agents-dark.png")
let heroWidth: CGFloat = 1200
let heroHeight: CGFloat = 28 + 8 + panel.size.height + 56
render(width: heroWidth, height: heroHeight, to: "hero.png") { canvas in
    NSGradient(colors: [NSColor(calibratedRed: 0.22, green: 0.26, blue: 0.64, alpha: 1),
                        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.20, alpha: 1)])!
        .draw(in: canvas, angle: -70)
    drawStars(in: canvas, count: 140)

    // Menu bar strip.
    let bar = NSRect(x: 0, y: canvas.maxY - 28, width: canvas.width, height: 28)
    NSColor.black.withAlphaComponent(0.35).setFill()
    bar.fill()
    let clock = "Wed Nov 11  11:42 PM" as NSString
    let clockAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                           .foregroundColor: NSColor.white]
    let clockSize = clock.size(withAttributes: clockAttributes)
    clock.draw(at: NSPoint(x: bar.maxX - 18 - clockSize.width, y: bar.midY - clockSize.height / 2), withAttributes: clockAttributes)
    var x = bar.maxX - 18 - clockSize.width - 30
    for name in ["switch.2", "wifi", "battery.75percent"] {
        let icon = symbol(name, size: 14)
        x -= icon.size.width
        icon.draw(in: NSRect(x: x, y: bar.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
        x -= 22
    }
    // Our status item, highlighted (menu open).
    let faceX = x - 22
    let highlight = NSRect(x: faceX - 7, y: bar.minY + 3, width: 32, height: 22)
    NSColor.white.withAlphaComponent(0.25).setFill()
    NSBezierPath(roundedRect: highlight, xRadius: 5, yRadius: 5).fill()
    awakeFace(size: 18, color: .white).draw(in: NSRect(x: faceX, y: bar.midY - 9, width: 18, height: 18))

    // Panel hanging from the status item.
    let panelOrigin = NSPoint(x: min(highlight.midX - 40, canvas.maxX - panel.size.width - 24),
                              y: bar.minY - 8 - panel.size.height)
    drawPanel(panel, at: panelOrigin, dark: true)

    // Title block.
    let left: CGFloat = 80
    let iconSize: CGFloat = 150
    let iconY = canvas.midY + 30
    iconImage.draw(in: NSRect(x: left - 14, y: iconY, width: iconSize, height: iconSize))
    let title = NSAttributedString(string: "No Sleep", attributes: [
        .font: rounded(76, .heavy), .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: left, y: iconY - 96))
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 6
    let tagline = NSAttributedString(
        string: "Your Mac stays awake — lid closed,\nagents cooking, builds building.\nFlip it off and it naps again.",
        attributes: [.font: rounded(25, .medium),
                     .foregroundColor: NSColor.white.withAlphaComponent(0.82),
                     .paragraphStyle: paragraph]
    )
    tagline.draw(in: NSRect(x: left, y: iconY - 96 - 130, width: 520, height: 120))
}

// MARK: Gallery

let gallery: [(String, String)] = [
    ("menu-off-light.png", "Chill: Mac naps normally"),
    ("menu-timer-light.png", "Timer: awake for 1h 23m"),
    ("menu-hot-light.png", "Thermal failsafe watching"),
]
let panels = gallery.map { image($0.0) }
let gap: CGFloat = 44
let galleryWidth = panels.reduce(0) { $0 + $1.size.width } + gap * CGFloat(panels.count + 1)
let tallest = panels.map(\.size.height).max()!
let galleryHeight = tallest + 60 + 70
render(width: galleryWidth, height: galleryHeight, to: "gallery.png") { canvas in
    NSGradient(colors: [NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.99, alpha: 1),
                        NSColor(calibratedRed: 0.86, green: 0.87, blue: 0.96, alpha: 1)])!
        .draw(in: canvas, angle: -90)
    var x = gap
    for (index, panel) in panels.enumerated() {
        let top = canvas.maxY - 44
        drawPanel(panel, at: NSPoint(x: x, y: top - panel.size.height), dark: false)
        let caption = NSAttributedString(string: gallery[index].1, attributes: [
            .font: rounded(17, .bold), .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.32, alpha: 1),
        ])
        let size = caption.size()
        caption.draw(at: NSPoint(x: x + (panel.size.width - size.width) / 2, y: 30))
        x += panel.size.width + gap
    }
}
print("ok")
