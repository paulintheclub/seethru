// Spike B: mirror overlay for a foreign window (SIP on).
//
// Usage (run from Terminal; needs Screen Recording + Accessibility for Terminal):
//   spike_b_mirror <owner name> [--alpha 0.5] [--hide] [--forward] [--seconds 20]
//
//   (no flags)  capture + overlay only, original stays where it is
//   --hide      also move the ORIGINAL window off-screen via Accessibility
//   --forward   overlay accepts mouse/keyboard and forwards them to the original via CGEvent.postToPid
//
// The original window is always moved back on exit (also on Ctrl-C / SIGTERM).
// Build: swiftc -O -swift-version 5 spikes/spike_b_mirror.swift -o .build/SpikeB
import AppKit
import ScreenCaptureKit
import ApplicationServices

// ---- args ----
var ownerName: String? = nil
var alphaValue: CGFloat = 0.5
var hide = false, forward = false
var seconds = 20.0
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--alpha": alphaValue = CGFloat(Double(it.next() ?? "") ?? 0.5)
        case "--hide": hide = true
        case "--forward": forward = true
        case "--seconds": seconds = Double(it.next() ?? "") ?? 20
        default: ownerName = a
        }
    }
}
guard let ownerName else { print("usage: spike_b_mirror <owner name> [--alpha 0.5] [--hide] [--forward] [--seconds 20]"); exit(1) }

func log(_ s: String) { print(s); fflush(stdout) }

log("screenRecording=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted())")
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess(); log("-> grant Screen Recording to your terminal, then re-run"); exit(4) }
if hide && !AXIsProcessTrusted() { log("-> grant Accessibility to your terminal, then re-run"); exit(4) }

// ---- private AX helper (isolated; the app keeps this in PrivateAPI/) ----
typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let axGetWindow: AXGetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: AXGetWindow.self) }

func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success, let wins = ref as? [AXUIElement] else { return nil }
    for w in wins {
        var id: CGWindowID = 0
        if let g = axGetWindow, g(w, &id) == .success, id == windowID { return w }
    }
    return nil
}
func axPosition(_ w: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &ref) == .success, let v = ref else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}
@discardableResult func axSetPosition(_ w: AXUIElement, _ p: CGPoint) -> AXError {
    var p = p
    return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}

// ---- find the window ----
let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerName as String] as? String) == ownerName }
guard let info = infos.first,
      let wid = info[kCGWindowNumber as String] as? CGWindowID,
      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
      let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { log("no window for '\(ownerName)'"); exit(3) }
let origin = CGPoint(x: b["X"]!, y: b["Y"]!)
let size = CGSize(width: b["Width"]!, height: b["Height"]!)
log("target wid=\(wid) pid=\(pid) frame=\(origin) \(size)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let primaryH = NSScreen.screens.first!.frame.height

// ---- overlay window ----
final class OverlayView: NSView {
    var targetPID: pid_t = 0, targetWID: CGWindowID = 0, targetOrigin = CGPoint.zero
    var forwardInput = false
    var eventsSent = 0
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func cgPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: targetOrigin.x + p.x, y: targetOrigin.y + (bounds.height - p.y))
    }
    func post(_ type: CGEventType, _ e: NSEvent, button: CGMouseButton = .left) {
        guard forwardInput, let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cgPoint(e), mouseButton: button) else { return }
        ev.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(targetWID)) // WindowUnderMousePointer
        ev.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(targetWID)) // ...ThatCanHandleThisEvent
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(e.clickCount))
        ev.postToPid(targetPID); eventsSent += 1
    }
    override func mouseDown(with e: NSEvent) { post(.leftMouseDown, e) }
    override func mouseUp(with e: NSEvent) { post(.leftMouseUp, e) }
    override func mouseDragged(with e: NSEvent) { post(.leftMouseDragged, e) }
    override func mouseMoved(with e: NSEvent) { post(.mouseMoved, e) }
    override func rightMouseDown(with e: NSEvent) { post(.rightMouseDown, e, button: .right) }
    override func rightMouseUp(with e: NSEvent) { post(.rightMouseUp, e, button: .right) }
    override func scrollWheel(with e: NSEvent) {
        guard forwardInput, let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                            wheel1: Int32(e.scrollingDeltaY), wheel2: Int32(e.scrollingDeltaX), wheel3: 0) else { return }
        ev.location = cgPoint(e)
        ev.postToPid(targetPID); eventsSent += 1
    }
    override func keyDown(with e: NSEvent) { key(e, down: true) }
    override func keyUp(with e: NSEvent) { key(e, down: false) }
    func key(_ e: NSEvent, down: Bool) {
        guard forwardInput, let ev = CGEvent(keyboardEventSource: nil, virtualKey: e.keyCode, keyDown: down) else { return }
        ev.flags = CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue))
        ev.postToPid(targetPID); eventsSent += 1
    }
}

let overlayFrame = NSRect(x: origin.x, y: primaryH - origin.y - size.height, width: size.width, height: size.height)
let overlay = NSWindow(contentRect: overlayFrame, styleMask: [.borderless], backing: .buffered, defer: false)
overlay.level = .floating
overlay.isOpaque = false
overlay.backgroundColor = .clear
overlay.hasShadow = false
overlay.alphaValue = alphaValue
overlay.ignoresMouseEvents = !forward
overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
let view = OverlayView(frame: NSRect(origin: .zero, size: size))
view.wantsLayer = true
view.layer?.contentsGravity = .resize
view.targetPID = pid; view.targetWID = wid; view.targetOrigin = origin; view.forwardInput = forward
overlay.contentView = view
overlay.acceptsMouseMovedEvents = forward
overlay.orderFrontRegardless()

// ---- capture ----
final class Sink: NSObject, SCStreamOutput, SCStreamDelegate {
    nonisolated(unsafe) var frames = 0
    nonisolated(unsafe) var lastSurfaceSize = CGSize.zero
    nonisolated(unsafe) var firstFrameAt: CFTimeInterval = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = arr.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb), let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        if frames == 0 { firstFrameAt = CACurrentMediaTime() }
        frames += 1
        lastSurfaceSize = CGSize(width: IOSurfaceGetWidth(surf), height: IOSurfaceGetHeight(surf))
        DispatchQueue.main.async { view.layer?.contents = surf }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { log("stream stopped: \(error)") }
}
let sink = Sink()
nonisolated(unsafe) var stream: SCStream?
nonisolated(unsafe) var axWin: AXUIElement?
nonisolated(unsafe) var movedAway = false

func restoreAndExit(_ code: Int32) -> Never {
    if movedAway, let w = axWin { let r = axSetPosition(w, origin); log("restored original window rc=\(r.rawValue)") }
    exit(code)
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main); sigInt.setEventHandler { restoreAndExit(130) }; sigInt.resume()
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main); sigTerm.setEventHandler { restoreAndExit(143) }; sigTerm.resume()

func fps(over s: Double) async -> Double {
    let f0 = sink.frames; try? await Task.sleep(nanoseconds: UInt64(s * 1e9)); return Double(sink.frames - f0) / s
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scw = content.windows.first(where: { $0.windowID == wid }) else { log("SCK cannot see window \(wid)"); restoreAndExit(5) }
        let filter = SCContentFilter(desktopIndependentWindow: scw)
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        cfg.width = Int(size.width * scale); cfg.height = Int(size.height * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.queueDepth = 3
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let s = SCStream(filter: filter, configuration: cfg, delegate: sink)
        try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
        try await s.startCapture()
        stream = s
        log("capture started")
        try? await Task.sleep(nanoseconds: 800_000_000)
        log(String(format: "RESULT frames visible window: first frame ok=%@ surface=%@ fps(2s)=%.1f", sink.frames > 0 ? "yes" : "NO", "\(sink.lastSurfaceSize)", await fps(over: 2)))

        if hide {
            if let w = axWindow(pid: pid, windowID: wid) {
                axWin = w
                let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: primaryH - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
                func visibleShare(_ r: CGRect) -> Double {
                    let a = screens.reduce(0.0) { $0 + Double(max(0, $1.intersection(r).width) * max(0, $1.intersection(r).height)) }
                    return a / Double(r.width * r.height)
                }
                var bestShare = 2.0
                var bestReq = CGPoint.zero
                for c in [CGPoint(x: -20000, y: -20000), CGPoint(x: -20000, y: 20000), CGPoint(x: 20000, y: -20000), CGPoint(x: 20000, y: 20000)] {
                    axSetPosition(w, c)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let now = axPosition(w) ?? .zero
                    let share = visibleShare(CGRect(origin: now, size: size))
                    log(String(format: "RESULT candidate %@ -> actual %@ visible share of window on screen = %.1f%%", "\(c)", "\(now)", share * 100))
                    if share < bestShare { bestShare = share; bestReq = c }
                }
                axSetPosition(w, bestReq)
                movedAway = true
                try? await Task.sleep(nanoseconds: 400_000_000)
                log(String(format: "RESULT chosen %@ visible share %.1f%% (0%% = fully hidden; app keeps its own clamp otherwise)", "\(bestReq)", bestShare * 100))
                let f = await fps(over: 3)
                log(String(format: "RESULT SCK fps after hide=%.1f (0 => frames stop when window is off-screen) frames total=%d", f, sink.frames))
            } else { log("RESULT could not resolve AX window (check _AXUIElementGetWindow / Accessibility)") }
        }
        log("overlay up for \(Int(seconds))s. Try: look, drag, type. alpha=\(alphaValue) hide=\(hide) forward=\(forward)")
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        log("RESULT forwarded events: \(view.eventsSent), total frames: \(sink.frames)")
        try? await s.stopCapture()
        restoreAndExit(0)
    } catch {
        log("capture error: \(error)"); restoreAndExit(6)
    }
}
app.run()
