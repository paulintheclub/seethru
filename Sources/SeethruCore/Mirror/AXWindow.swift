import AppKit
import ApplicationServices
import CoreGraphics
import PrivateAPI

/// Thin wrapper over an Accessibility window element (main-thread use only).
struct AXWindow {
    let element: AXUIElement

    static func find(pid: pid_t, number: UInt32, resolver: any AXWindowIDResolving) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        for w in windows where resolver.windowNumber(of: w) == number { return AXWindow(element: w) }
        return nil
    }

    var position: CGPoint? {
        var p = CGPoint.zero
        return axValue(kAXPositionAttribute).map { AXValueGetValue($0, .cgPoint, &p) ? p : nil } ?? nil
    }

    var size: CGSize? {
        var s = CGSize.zero
        return axValue(kAXSizeAttribute).map { AXValueGetValue($0, .cgSize, &s) ? s : nil } ?? nil
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    func raise() { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }

    private func axValue(_ attr: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(ref as AnyObject, to: AXValue.self)
    }
}

enum ScreenGeometry {
    /// Screen frames in CG global coordinates (origin top-left of the primary display).
    static func cgScreenFrames() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { s in
            CGRect(x: s.frame.minX, y: primary.frame.height - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
    }

    static func isVisible(_ rect: CGRect) -> Bool {
        cgScreenFrames().contains { $0.intersects(rect) }
    }

    /// Area of `rect` that lies on any screen.
    static func visibleArea(_ rect: CGRect) -> CGFloat {
        cgScreenFrames().reduce(0) { $0 + $1.intersection(rect).width.clamped(min: 0) * $1.intersection(rect).height.clamped(min: 0) }
    }

    /// macOS (and apps such as Chrome) refuse to move a window completely off-screen and keep a strip of it
    /// reachable. A window counts as parked when no more than this share of it is still on a screen.
    static let parkedVisibleShare: CGFloat = 0.04

    /// The display a rectangle (CG coordinates) mostly belongs to.
    static func displayID(for rect: CGRect) -> CGDirectDisplayID? {
        let frames = cgScreenFrames()
        guard let i = frames.indices.max(by: { frames[$0].intersection(rect).area < frames[$1].intersection(rect).area }),
              frames[i].intersects(rect) else { return nil }
        return NSScreen.screens[i].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// AppKit frame (bottom-left origin) for a rect given in CG coordinates.
    static func appKitFrame(fromCG r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private extension CGFloat {
    func clamped(min lower: CGFloat) -> CGFloat { self < lower ? lower : self }
}
