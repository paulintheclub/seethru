@preconcurrency import ScreenCaptureKit
import AppKit

/// A click-through panel that shows what the screen looks like WITHOUT a given window. Placed directly above that
/// window it hides it completely. The pixels come from a display capture shared by every cover on the same display
/// (`BackdropHub`); each cover shows only its own rectangle of it. The panel is flagged non-opaque on purpose so the window
/// server still treats the original as visible (apps such as Chrome keep rendering).
/// Used (a) as the backdrop in in-place mode and (b) to cover the strip macOS leaves of a parked window.
@MainActor
final class BackdropCover {
    private(set) var rect: CGRect // CG global coordinates
    let originalID: UInt32
    private let panel: NSPanel
    private let view: NSView
    private unowned let hub: BackdropHub
    private(set) var hasFrames = false

    init(rect: CGRect, originalID: UInt32, hub: BackdropHub) {
        self.rect = rect
        self.originalID = originalID
        self.hub = hub
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
        panel = p
        view = v
    }

    var windowNumber: Int { panel.windowNumber }
    var displayID: CGDirectDisplayID? { ScreenGeometry.displayID(for: rect) }

    func start() async throws {
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: Int(originalID))
        do { try await hub.attach(self) } catch {
            panel.orderOut(nil)
            panel.close()
            throw error
        }
    }

    /// Moves/resizes to follow the window. Returns false when the rect moved to another display (caller rebuilds).
    func update(rect new: CGRect) async -> Bool {
        guard ScreenGeometry.displayID(for: new) == displayID else { return false }
        rect = new
        panel.setFrame(ScreenGeometry.appKitFrame(fromCG: new), display: false)
        await hub.coverMoved(self)
        return true
    }

    func order(above windowNumber: Int) { panel.order(.above, relativeTo: windowNumber) }
    func setVisible(_ visible: Bool) { visible ? panel.orderFrontRegardless() : panel.orderOut(nil) }

    func stop() {
        hub.detach(self)
        panel.orderOut(nil)
        panel.close()
    }

    /// A new frame of the shared display capture, which covers `captureRect` (CG coordinates).
    func deliver(_ surface: IOSurface, captureRect: CGRect) {
        guard captureRect.width > 0, captureRect.height > 0 else { return }
        hasFrames = true
        let r = CGRect(x: (rect.minX - captureRect.minX) / captureRect.width,
                       y: 1 - (rect.maxY - captureRect.minY) / captureRect.height, // contentsRect has a bottom-left origin
                       width: rect.width / captureRect.width,
                       height: rect.height / captureRect.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contentsRect = r
        view.layer?.contents = surface
        CATransaction.commit()
    }

    /// The parts of a window at `origin` that are on a screen.
    static func visibleRects(origin: CGPoint, size: CGSize) -> [CGRect] {
        let r = CGRect(origin: origin, size: size)
        return ScreenGeometry.cgScreenFrames().map { $0.intersection(r) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }
}
