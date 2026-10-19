import AppKit
@preconcurrency import ScreenCaptureKit

/// Default mode. The original window stays exactly where it is and keeps getting real clicks, scrolls and typing.
/// Two click-through panels are stacked directly above it:
///   1. backdrop: what the screen shows without this window (BackdropCover)
///   2. overlay: a live copy of the window at alpha < 1
/// Result: alpha * window + (1 - alpha) * backdrop, which is what a see-through window looks like.
/// No Accessibility permission, nothing is moved, nothing needs restoring if Seethru dies.
@MainActor
final class InPlaceSession: OverlaySession {
    let isParked = false
    let window: WindowInfo
    private var alpha: Double
    var onEnded: (@MainActor (WindowID, BackendError?) -> Void)?

    private var overlay: NSPanel!
    private var overlayView: NSView!
    private let sink = FrameSink()
    private var stream: SCStream?
    private var covers: [BackdropCover] = []
    private var scWindow: SCWindow?
    private var frame = CGRect.zero
    private var shown = false
    private var ended = false
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var tick = 0
    private var rebuilding = false
    private var syncing = false
    private var syncAgain = false

    init(window: WindowInfo, alpha: Double) {
        self.window = window
        self.alpha = alpha
    }

    // MARK: lifecycle

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw BackendError.permissionMissing(.screenRecording) }
        guard let state = WindowGeometry.state(of: window.id.number) else { throw BackendError.windowNotFound }
        frame = state.bounds

        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw BackendError.captureFailed(error.localizedDescription) }
        guard let scw = content.windows.first(where: { $0.windowID == window.id.number }) else { throw BackendError.windowNotFound }
        scWindow = scw

        buildOverlay()
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: scw), configuration: windowConfiguration(), delegate: sink)
        sink.onStop = { [weak self] error in
            Task { @MainActor in self?.end(error.map { .captureFailed($0.localizedDescription) }) }
        }
        sink.view = overlayView
        do {
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "seethru.capture", qos: .userInteractive))
            try await s.startCapture()
        } catch {
            teardown()
            throw BackendError.captureFailed(error.localizedDescription)
        }
        stream = s

        await rebuildCovers()
        // Show the overlay only once both layers have pixels, so the window never flashes double.
        for _ in 0..<40 where !(sink.frameCount > 0 && covers.allSatisfy(\.hasFrames)) { try? await Task.sleep(nanoseconds: 25_000_000) }
        guard sink.frameCount > 0 else { stop(); throw BackendError.captureFailed("no frames received") }
        showGroup()

        // Common run-loop modes: the timer must keep running while a menu or slider is being tracked.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // A click makes the app raise the original above our panels. Re-stack immediately, and again a few times
        // while the app finishes raising (the event reaches us before or at the same moment as the raise).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.restackBurst() } }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restackBurst() }
        }
    }

    func update(alpha: Double, options: WindowOptions) {
        let animate = abs(alpha - self.alpha) > 0.001
        self.alpha = alpha
        guard let overlay else { return }
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                overlay.animator().alphaValue = alpha
            }
        } else {
            overlay.alphaValue = alpha
        }
    }

    func refreshFilters() async {
        for c in covers { await c.refreshFilter() }
    }

    func stop() {
        guard !ended else { return }
        ended = true
        timer?.invalidate()
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        covers.forEach { $0.stop() }
        covers.removeAll()
        teardown()
    }

    private func end(_ error: BackendError?) {
        guard !ended else { return }
        stop()
        onEnded?(window.id, error)
    }

    // MARK: tracking

    private func onTick() {
        guard !ended else { return }
        tick += 1
        guard let state = WindowGeometry.state(of: window.id.number) else { end(nil); return }
        if !state.onScreen { // minimized, other Space, hidden app
            if shown { hideGroup() }
            return
        }
        if !shown { showGroup() }
        if state.bounds != frame {
            frame = state.bounds
            overlay.setFrame(ScreenGeometry.appKitFrame(fromCG: frame), display: false)
            overlayView.frame = NSRect(origin: .zero, size: frame.size)
            if let stream { Task { try? await stream.updateConfiguration(windowConfiguration()) } }
            scheduleSync()
        }
        restackIfNeeded()
    }

    /// Stack, front to back: overlay, backdrops, original, with nothing in between. Anything else means the original
    /// was raised (or another window slipped in), so put our panels back directly above it.
    private func restackIfNeeded() {
        guard !ended, shown, let overlay else { return }
        let above = WindowGeometry.windowsAbove(window.id.number)
        let ours = Set(covers.map { UInt32($0.windowNumber) })
        let n = covers.count + 1
        if above.count >= n, above[0] == UInt32(overlay.windowNumber), Set(above[1..<n]) == ours { return }
        covers.forEach { $0.order(above: Int(window.id.number)) }
        overlay.order(.above, relativeTo: covers.last?.windowNumber ?? Int(window.id.number))
    }

    /// Checks now and at the next few frames.
    private func restackBurst() {
        restackIfNeeded()
        for ms in [4, 8, 16, 33, 66, 120] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                MainActor.assumeIsolated { self?.restackIfNeeded() }
            }
        }
    }

    // MARK: layers

    /// Keep one backdrop per screen the window touches.
    private func rebuildCovers() async {
        guard let scWindow, !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        covers.forEach { $0.stop() }
        covers.removeAll()
        for rect in BackdropCover.visibleRects(origin: frame.origin, size: frame.size) {
            let c = BackdropCover(rect: rect, original: scWindow)
            do { try await c.start(); covers.append(c) } catch { c.stop() }
        }
    }

    /// Coalesces backdrop updates while the window is being dragged or resized.
    private func scheduleSync() {
        if syncing { syncAgain = true; return }
        syncing = true
        Task { @MainActor in
            repeat {
                syncAgain = false
                await syncCovers()
            } while syncAgain && !ended
            syncing = false
        }
    }

    private func syncCovers() async {
        let rects = BackdropCover.visibleRects(origin: frame.origin, size: frame.size)
        var ok = rects.count == covers.count
        if ok { for (c, r) in zip(covers, rects) where !(await c.update(rect: r)) { ok = false } }
        if !ok {
            await rebuildCovers()
            if shown { showGroup() }
        }
    }

    private func showGroup() {
        guard !ended else { return }
        shown = true
        covers.forEach { $0.setVisible(true) }
        overlay.orderFrontRegardless()
        covers.forEach { $0.order(above: Int(window.id.number)) }
        overlay.order(.above, relativeTo: covers.last?.windowNumber ?? Int(window.id.number))
    }

    private func hideGroup() {
        shown = false
        covers.forEach { $0.setVisible(false) }
        overlay.orderOut(nil)
    }

    private func buildOverlay() {
        let p = NSPanel(contentRect: ScreenGeometry.appKitFrame(fromCG: frame), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true // real input goes to the original underneath
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        p.alphaValue = alpha
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.contentsGravity = .resize
        p.contentView = v
        overlay = p
        overlayView = v
    }

    private func teardown() {
        sink.view = nil
        overlay?.orderOut(nil)
        overlay?.close()
        overlay = nil
        overlayView = nil
    }

    private func windowConfiguration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let scale = overlay?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        c.width = max(1, Int(frame.width * scale))
        c.height = max(1, Int(frame.height * scale))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.ignoreShadowsSingleWindow = true
        return c
    }
}
