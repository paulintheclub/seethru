import AppKit
import ScreenCaptureKit

/// macOS keeps a thin strip of a parked window on screen. This panel sits exactly on that strip and shows what the
/// screen looks like WITHOUT the original window (display capture that excludes the original and the panel itself),
/// so the strip disappears. Clicks pass through.
@MainActor
final class StripCover {
    let rect: CGRect // CG global coordinates
    private let panel: NSPanel
    private let sink = FrameSink()
    private var stream: SCStream?

    init(rect: CGRect) {
        self.rect = rect
        let p = NSPanel(contentRect: ScreenGeometry.appKitFrame(fromCG: rect), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
        v.wantsLayer = true
        v.layer?.contentsGravity = .resize
        p.contentView = v
        sink.view = v
        panel = p
    }

    func start(excluding original: SCWindow) async throws {
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: Int(original.windowID))
        let cgFrames = ScreenGeometry.cgScreenFrames()
        guard let index = cgFrames.firstIndex(where: { $0.intersects(rect) }),
              let displayID = NSScreen.screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw BackendError.captureFailed("no display for the strip") }

        // The panel must be known to ScreenCaptureKit before it can be excluded.
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        for _ in 0..<10 where !content.windows.contains(where: { $0.windowID == CGWindowID(panel.windowNumber) }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw BackendError.captureFailed("display not found")
        }
        let excluded = [original] + content.windows.filter { $0.windowID == CGWindowID(panel.windowNumber) }
        let scale = NSScreen.screens[index].backingScaleFactor
        let c = SCStreamConfiguration()
        c.sourceRect = CGRect(x: rect.minX - cgFrames[index].minX, y: rect.minY - cgFrames[index].minY,
                              width: rect.width, height: rect.height)
        c.width = max(1, Int(rect.width * scale))
        c.height = max(1, Int(rect.height * scale))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: excluded), configuration: c, delegate: sink)
        try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "seethru.cover", qos: .userInteractive))
        try await s.startCapture()
        stream = s
    }

    func keepAbove(_ windowNumber: UInt32) { panel.order(.above, relativeTo: Int(windowNumber)) }

    func stop() {
        sink.view = nil
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        panel.orderOut(nil)
        panel.close()
    }

    /// The parts of a window at `origin` that are still on a screen.
    static func visibleRects(origin: CGPoint, size: CGSize) -> [CGRect] {
        let r = CGRect(origin: origin, size: size)
        return ScreenGeometry.cgScreenFrames().map { $0.intersection(r) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }
}
