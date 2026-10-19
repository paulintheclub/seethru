// Control: same SkyLight call on a window owned by the calling process.
// Build: swiftc -O spikes/control_own_window.swift -o .build/SpikeControl
import AppKit
typealias SetAlpha = @convention(c) (Int32, UInt32, Float) -> Int32
typealias MainConn = @convention(c) () -> Int32
let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let setA = unsafeBitCast(dlsym(sky, "SLSSetWindowAlpha"), to: SetAlpha.self)
let conn = unsafeBitCast(dlsym(sky, "SLSMainConnectionID"), to: MainConn.self)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 420, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.title = "SpikeControl"
win.backgroundColor = .systemOrange
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
func cgAlpha() -> Double {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.first { ($0[kCGWindowNumber as String] as? Int) == win.windowNumber }?[kCGWindowAlpha as String] as? Double ?? -1
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    let rc = setA(conn(), UInt32(win.windowNumber), 0.4)
    print("own window SLSSetWindowAlpha(0.4) rc=\(rc) CGWindowList alpha=\(cgAlpha())"); fflush(stdout)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
app.run()
