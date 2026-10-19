// Throwaway "foreign" window used as a control target for the spikes.
// Build: swiftc -O spikes/target_window.swift -o .build/SpikeTarget
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let win = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 420, height: 260),
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
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("pid=\(getpid()) window=\(win.windowNumber)")
fflush(stdout)
app.run()
