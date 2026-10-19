// Spike A: can we change alpha of a FOREIGN window via SkyLight with SIP on?
// Usage: spike_a_skylight <owner name | pid> [alpha] [seconds]
// Build: swiftc -O spikes/spike_a_skylight.swift -o .build/SpikeA
import AppKit
import CoreGraphics

typealias CID = Int32

func sym<T>(_ handles: [UnsafeMutableRawPointer?], _ name: String, as _: T.Type) -> T? {
    for h in handles {
        if let p = dlsym(h, name) { return unsafeBitCast(p, to: T.self) }
    }
    return nil
}

let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let handles: [UnsafeMutableRawPointer?] = [sky, UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */]
print("SkyLight handle: \(sky != nil ? "ok" : "FAILED")")

let candidates = ["SLSMainConnectionID", "CGSMainConnectionID", "SLSSetWindowAlpha", "CGSSetWindowAlpha",
                  "SLSSetWindowListAlpha", "SLSSetWindowLevel", "CGSSetWindowLevel", "SLSGetWindowAlpha",
                  "SLSSetWindowTags", "SLSClearWindowTags", "SLSSetWindowShape", "SLSGetWindowOwner",
                  "SLSOrderWindow", "SLSSetWindowOpacity", "CGSSetWindowOpacity"]
for n in candidates {
    print(String(format: "  %-24@ %@", n as NSString, sym(handles, n, as: UnsafeRawPointer.self) != nil ? "present" : "missing"))
}

typealias MainConn = @convention(c) () -> CID
typealias SetAlpha = @convention(c) (CID, UInt32, Float) -> Int32
typealias GetAlpha = @convention(c) (CID, UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias SetListAlpha = @convention(c) (CID, UnsafePointer<UInt32>, Int32, Float) -> Int32

guard let mainConn = sym(handles, "SLSMainConnectionID", as: MainConn.self) else { print("no SLSMainConnectionID"); exit(2) }
let cid = mainConn()
print("connection id: \(cid)")

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: spike_a <owner|pid> [alpha] [seconds]"); exit(1) }
let target = args[1]
let alpha = args.count > 2 ? Float(args[2]) ?? 0.5 : 0.5
let wait = args.count > 3 ? Double(args[3]) ?? 5 : 5

func listWindows() -> [[String: Any]] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
}
func match(_ w: [String: Any]) -> Bool {
    if let pid = Int32(target) { return (w[kCGWindowOwnerPID as String] as? Int32) == pid }
    return (w[kCGWindowOwnerName as String] as? String) == target
}
func currentAlpha(_ id: UInt32) -> Double? {
    listWindows().first { ($0[kCGWindowNumber as String] as? UInt32) == id }?[kCGWindowAlpha as String] as? Double
}

let wins = listWindows().filter(match)
guard let first = wins.first, let wid = first[kCGWindowNumber as String] as? UInt32 else {
    print("no on-screen layer-0 window for '\(target)'"); exit(3)
}
print("target window \(wid) owner=\(first[kCGWindowOwnerName as String] ?? "?") name=\(first[kCGWindowName as String] ?? "-") alpha(before)=\(currentAlpha(wid) ?? -1)")

for name in ["SLSSetWindowAlpha", "CGSSetWindowAlpha"] {
    guard let f = sym(handles, name, as: SetAlpha.self) else { print("\(name): missing"); continue }
    let rc = f(cid, wid, alpha)
    usleep(300_000)
    print("\(name)(\(alpha)) rc=\(rc)  CGWindowList alpha now=\(currentAlpha(wid) ?? -1)")
    if rc == 0 { break }
}
if let g = sym(handles, "SLSGetWindowAlpha", as: GetAlpha.self) {
    var out: Float = -1
    let rc = g(cid, wid, &out)
    print("SLSGetWindowAlpha rc=\(rc) value=\(out)")
}
if let f = sym(handles, "SLSSetWindowListAlpha", as: SetListAlpha.self) {
    var id = wid
    let rc = f(cid, &id, 1, alpha)
    print("SLSSetWindowListAlpha(\(alpha)) rc=\(rc) CGWindowList alpha now=\(currentAlpha(wid) ?? -1)")
}

print("holding \(wait)s — LOOK at the window now")
sleep(UInt32(wait))
if let f = sym(handles, "SLSSetWindowAlpha", as: SetAlpha.self) {
    let rc = f(cid, wid, 1.0)
    print("restore rc=\(rc) alpha now=\(currentAlpha(wid) ?? -1)")
}
