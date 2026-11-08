// Throwaway window for stress-testing Seethru without touching your own windows.
// Build: swiftc -O -swift-version 5 tools/test_window.swift -o .build/SpikeTarget
// Run it, then: Seethru --set-opacity SpikeTarget 0.5
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

var originX = 300.0
if let i = CommandLine.arguments.firstIndex(of: "--x"), CommandLine.arguments.count > i + 1, let x = Double(CommandLine.arguments[i + 1]) { originX = x }
let win = NSWindow(contentRect: NSRect(x: originX, y: 300, width: 420, height: 260),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
win.title = "SpikeTarget"
final class ClickView: NSView {
    override func mouseDown(with e: NSEvent) { print("CLICK at \(e.locationInWindow)"); fflush(stdout) }
    override func scrollWheel(with e: NSEvent) { print("SCROLL \(e.scrollingDeltaY)"); fflush(stdout) }
}
let v = ClickView(frame: win.contentView!.bounds)
v.wantsLayer = true
v.layer?.backgroundColor = NSColor.systemOrange.cgColor
v.autoresizingMask = [.width, .height]
win.contentView = v
if CommandLine.arguments.contains("--animate") {
    var phase = 0.0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        phase += 0.02
        v.layer?.backgroundColor = NSColor(hue: phase.truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.9, alpha: 1).cgColor
    }
}
if CommandLine.arguments.contains("--wander") {
    var t = 0.0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        t += 0.03
        let w = 420 + 120 * sin(t * 0.7), h = 260 + 80 * cos(t * 0.5)
        win.setFrame(NSRect(x: originX + 200 * sin(t), y: 300 + 100 * cos(t * 0.8), width: w, height: h), display: true)
    }
}
if CommandLine.arguments.contains("--blink") {
    var visible = true
    Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in
        visible.toggle()
        if visible { win.orderFront(nil) } else { win.orderOut(nil) }
    }
}
if CommandLine.arguments.contains("--blue") { v.layer?.backgroundColor = NSColor.systemBlue.cgColor }
if CommandLine.arguments.contains("--raise") {
    // like a click on the window: the app raises and activates its own window
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("pid=\(getpid()) window=\(win.windowNumber)")
fflush(stdout)
app.run()
