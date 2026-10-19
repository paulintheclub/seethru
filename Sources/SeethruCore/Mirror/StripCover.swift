import AppKit
import ScreenCaptureKit

/// A panel that shows what the screen looks like WITHOUT a given window: a display capture of its own rectangle that
/// excludes that window and every Seethru window. Placed directly above the window it hides it completely, and
/// because the panel is flagged non-opaque the window server still treats the original as visible (so apps such as
/// Chrome keep rendering). Used (a) as the backdrop in in-place mode and (b) to cover the strip macOS leaves of a
/// parked window. Clicks pass through.
@MainActor
final class BackdropCover {
    private(set) var rect: CGRect // CG global coordinates
    private let original: SCWindow
    private let panel: NSPanel
    private let sink = FrameSink()
    private var stream: SCStream?
    private var displayIndex = 0

    init(rect: CGRect, original: SCWindow) {
        self.rect = rect
        self.original = original
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

    var windowNumber: Int { panel.windowNumber }
    var hasFrames: Bool { sink.frameCount > 0 }

    func start() async throws {
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: Int(original.windowID))
        let frames = ScreenGeometry.cgScreenFrames()
        guard let index = frames.firstIndex(where: { $0.intersects(rect) }) else { throw BackendError.captureFailed("no display for the backdrop") }
        displayIndex = index
        let (filter, _) = try await makeFilter()
        let s = SCStream(filter: filter, configuration: configuration(), delegate: sink)
        try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "seethru.cover", qos: .userInteractive))
        try await s.startCapture()
        stream = s
    }

    /// Moves/resizes to follow the window. Returns false when the rect moved to another display (caller rebuilds).
    func update(rect new: CGRect) async -> Bool {
        let frames = ScreenGeometry.cgScreenFrames()
        guard let index = frames.firstIndex(where: { $0.intersects(new) }), index == displayIndex else { return false }
        rect = new
        panel.setFrame(ScreenGeometry.appKitFrame(fromCG: new), display: false)
        try? await stream?.updateConfiguration(configuration())
        return true
    }

    func refreshFilter() async {
        guard let (filter, _) = try? await makeFilter() else { return }
        try? await stream?.updateContentFilter(filter)
    }

    func order(above windowNumber: Int) { panel.order(.above, relativeTo: windowNumber) }
    func setVisible(_ visible: Bool) { visible ? panel.orderFrontRegardless() : panel.orderOut(nil) }

    func stop() {
        sink.view = nil
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: -

    private func makeFilter() async throws -> (SCContentFilter, SCShareableContent) {
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // The panel must be known to ScreenCaptureKit before it can be excluded.
        for _ in 0..<10 where !content.windows.contains(where: { $0.windowID == CGWindowID(panel.windowNumber) }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        let frames = ScreenGeometry.cgScreenFrames()
        guard displayIndex < frames.count,
              let displayID = NSScreen.screens[displayIndex].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw BackendError.captureFailed("display not found")
        }
        let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        return (SCContentFilter(display: display, excludingWindows: [original] + own), content)
    }

    private func configuration() -> SCStreamConfiguration {
        let frames = ScreenGeometry.cgScreenFrames()
        let origin = displayIndex < frames.count ? frames[displayIndex].origin : .zero
        let scale = displayIndex < NSScreen.screens.count ? NSScreen.screens[displayIndex].backingScaleFactor : 2
        let c = SCStreamConfiguration()
        c.sourceRect = CGRect(x: rect.minX - origin.x, y: rect.minY - origin.y, width: rect.width, height: rect.height)
        c.width = max(1, Int(rect.width * scale))
        c.height = max(1, Int(rect.height * scale))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        return c
    }

    /// The parts of a window at `origin` that are on a screen.
    static func visibleRects(origin: CGPoint, size: CGSize) -> [CGRect] {
        let r = CGRect(origin: origin, size: size)
        return ScreenGeometry.cgScreenFrames().map { $0.intersection(r) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }
}
