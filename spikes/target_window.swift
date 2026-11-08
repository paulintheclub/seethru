// Throwaway "foreign" window used as a control target for the spikes.
// Build: swiftc -O spikes/target_window.swift -o .build/SpikeTarget
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
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("pid=\(getpid()) window=\(win.windowNumber)")
fflush(stdout)
app.run()
