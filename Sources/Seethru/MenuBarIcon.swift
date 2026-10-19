import AppKit
import SeethruCore
import SwiftUI

/// Template image: two windows. Outlined while nothing is managed; the front one is tinted while something is.
enum MenuBarImage {
    static func make(active: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let back = NSBezierPath(roundedRect: NSRect(x: 2, y: 6.5, width: 9.5, height: 9), xRadius: 2, yRadius: 2)
            let front = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 2.5, width: 9.5, height: 9), xRadius: 2, yRadius: 2)
            NSColor.black.setStroke()
            back.lineWidth = 1.4
            back.stroke()
            if active {
                NSColor.black.withAlphaComponent(0.5).setFill()
                front.fill()
            }
            front.lineWidth = 1.4
            front.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("onboardingShown") private var onboardingShown = false

    var body: some View {
        Image(nsImage: MenuBarImage.make(active: model.activeCount > 0))
            .accessibilityLabel(model.activeCount > 0 ? "Seethru, \(model.activeCount) windows transparent" : "Seethru")
            .task {
                if CommandLine.arguments.contains("--show-window") { bringToFront(openWindow, WindowID.main) }
                guard !onboardingShown else { return }
                onboardingShown = true
                bringToFront(openWindow, WindowID.onboarding)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
                bringToFront(openWindow, WindowID.main)
            }
    }
}
