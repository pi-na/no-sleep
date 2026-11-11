import AppKit
import SwiftUI

/// Monochrome template images for the status item.
enum MenuBarIcon {
    /// Mac may sleep: "z z z".
    static let sleepy: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: "zzz", accessibilityDescription: "No Sleep: off")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// Mac kept awake: a face with very wide-open eyes.
    static let awake: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()

            let face = NSBezierPath(ovalIn: NSRect(x: 0.9, y: 0.9, width: 16.2, height: 16.2))
            face.lineWidth = 1.5
            face.stroke()

            // Big round eyes with small pupils — staring wide awake.
            for centerX in [6.0, 12.0] {
                let eye = NSBezierPath(ovalIn: NSRect(x: centerX - 2.65, y: 8.3, width: 5.3, height: 5.6))
                eye.lineWidth = 1.2
                eye.stroke()
                NSBezierPath(ovalIn: NSRect(x: centerX - 1.05, y: 10.05, width: 2.1, height: 2.1)).fill()
            }

            // Small surprised "o" mouth.
            let mouth = NSBezierPath(ovalIn: NSRect(x: 7.6, y: 3.4, width: 2.8, height: 2.6))
            mouth.lineWidth = 1.2
            mouth.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "No Sleep: on"
        return image
    }()
}

struct MenuBarLabel: View {
    let controller: SleepController

    var body: some View {
        Image(nsImage: controller.isActive ? MenuBarIcon.awake : MenuBarIcon.sleepy)
            .accessibilityLabel(controller.isActive ? "No Sleep is on" : "No Sleep is off")
    }
}
