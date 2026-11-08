@preconcurrency import ScreenCaptureKit
import AppKit

/// Default mode. The original window stays exactly where it is and keeps getting real clicks, scrolls and typing.
/// Two click-through panels sit above it:
///   1. backdrop: what the screen shows without this window (BackdropCover, fed by the shared display capture)
///   2. overlay: a live copy of the window at alpha < 1
/// Result: alpha * window + (1 - alpha) * backdrop, which is what a see-through window looks like.
///
/// The panels use the floating window level, so they stay above the original no matter what the app does to its own
/// stacking (a click raises the window, which used to make the transparency vanish for a moment). Windows that are
/// really above the original (another app's window, a popup) are cut out of the panels with a mask, so they show as usual.
/// No Accessibility permission, nothing is moved, nothing needs restoring if Seethru dies.
/// While the window is not on screen (minimized, other Space, hidden app) every capture of it is stopped.
@MainActor
final class InPlaceSession: OverlaySession {
    let isParked = false
    let window: WindowInfo
    private var alpha: Double
    var onEnded: (@MainActor (WindowID, BackendError?) -> Void)?

    private let hub: BackdropHub
    private let coordinator: StackCoordinator
    private var overlay: NSPanel!
    private var overlayView: NSView!
    private let sink = FrameSink()
    private var stream: SCStream?
    private var covers: [BackdropCover] = []
    private var frame = CGRect.zero
    private var shown = false
    private var suspended = false
    private var transitioning = false
    private var ended = false
    private var nextResumeAttempt = Date.distantPast
    private var tickCount = 0
    private var rebuilding = false
    private var syncing = false
    private var syncAgain = false
    private var configuring = false
    private var configAgain = false
    private var lastHoles: [CGRect]?
    private var streamFailures: [Date] = []

    init(window: WindowInfo, alpha: Double, hub: BackdropHub, coordinator: StackCoordinator) {
        self.window = window
        self.alpha = alpha
        self.hub = hub
        self.coordinator = coordinator
    }

    /// Window numbers of this session's panels (the coordinator uses them to tell our windows from other apps').
    var panelNumbers: [UInt32] {
        ([overlay?.windowNumber] + covers.map { Optional($0.windowNumber) }).compactMap { $0 }.map { UInt32($0) }
    }

    // MARK: lifecycle

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw BackendError.permissionMissing(.screenRecording) }
        guard let state = WindowGeometry.state(of: window.id.number) else { throw BackendError.windowNotFound }
        frame = state.bounds
        buildOverlay()
        sink.onStop = { [weak self] error in
            Task { @MainActor in await self?.streamDied(error) }
        }
        sink.view = overlayView
        do { try await startWindowStream() } catch {
            teardown()
            throw error
        }

        await rebuildCovers()
        // Show the overlay only once both layers have pixels, so the window never flashes double.
        for _ in 0..<40 where !(sink.frameCount > 0 && covers.allSatisfy(\.hasFrames)) { try? await Task.sleep(nanoseconds: 25_000_000) }
        guard sink.frameCount > 0 else { stop(); throw BackendError.captureFailed("no frames received") }
        showGroup()
        coordinator.register(self)
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

    func stop() {
        guard !ended else { return }
        ended = true
        coordinator.unregister(self)
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

    // MARK: per-frame work (called by the coordinator)

    func tick(_ snap: WindowGeometry.Snapshot, ours: Set<UInt32>) {
        guard !ended, !transitioning else { return }
        tickCount += 1
        guard let i = snap.index[window.id.number] else {
            // Not on screen: minimized, hidden app, another Space, or closed. The full-list lookup is slower, so
            // while suspended it runs at 6 Hz.
            if !suspended {
                if WindowGeometry.state(of: window.id.number) == nil { end(nil) } else { Task { await suspend() } }
            } else if tickCount % 10 == 0, WindowGeometry.state(of: window.id.number) == nil {
                end(nil)
            }
            return
        }
        let entry = snap.entries[i]
        if suspended {
            frame = entry.bounds
            Task { await resume() }
            return
        }
        if entry.bounds != frame {
            frame = entry.bounds
            overlay.setFrame(ScreenGeometry.appKitFrame(fromCG: frame), display: false)
            overlayView.frame = NSRect(origin: .zero, size: frame.size)
            lastHoles = nil
            scheduleWindowConfig()
            scheduleSync()
        }
        updateHoles(snap, index: i, ours: ours)
        if shown, !overlay.isVisible { showGroup() } // something hid the panels: put them back
    }

    /// Windows stacked above the original must stay visible, so cut them out of the panels.
    private func updateHoles(_ snap: WindowGeometry.Snapshot, index: Int, ours: Set<UInt32>) {
        var holes: [CGRect] = []
        for e in snap.entries[0..<index] {
            // Floating level is 3: anything above that already sits above our panels by itself.
            guard e.layer <= 3, e.alpha > 0.01, !ours.contains(e.number), e.bounds.intersects(frame) else { continue }
            // Tiny windows of the app itself are its own chrome (e.g. the traffic lights), not something to cut out.
            if e.pid == window.id.pid, e.bounds.width * e.bounds.height < 4000 || e.bounds.height < 30 { continue }
            holes.append(e.bounds.intersection(frame))
        }
        guard holes != lastHoles else { return }
        lastHoles = holes
        HoleMask.apply(to: overlayView.layer, rect: frame, holes: holes)
        covers.forEach { $0.setHoles(holes) }
    }

    // MARK: suspend / resume / recovery

    private func suspend() async {
        guard !suspended, !transitioning, !ended else { return }
        transitioning = true
        suspended = true
        hideGroup()
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        covers.forEach { $0.stop() }
        covers.removeAll()
        transitioning = false
    }

    /// ScreenCaptureKit may not know a window yet in the first moments after it reappears, so retry for a while.
    /// If it still fails, stay suspended and try again later; the session ends only when the window is really gone.
    private func resume() async {
        guard suspended, !transitioning, !ended, Date() >= nextResumeAttempt else { return }
        transitioning = true
        defer { transitioning = false }
        overlay.setFrame(ScreenGeometry.appKitFrame(fromCG: frame), display: false)
        overlayView.frame = NSRect(origin: .zero, size: frame.size)
        var started = false
        for _ in 0..<15 where !started && !ended {
            do { try await startWindowStream(); started = true } catch { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard started, !ended else { nextResumeAttempt = Date().addingTimeInterval(1); return }
        await rebuildCovers()
        for _ in 0..<20 where !(sink.frameCount > 0 && covers.allSatisfy(\.hasFrames)) { try? await Task.sleep(nanoseconds: 25_000_000) }
        lastHoles = nil
        suspended = false
        showGroup()
    }

    /// The capture stopped on its own (display change, sleep, window server reset). Restart it instead of giving up,
    /// and give up only if it keeps dying.
    private func streamDied(_ error: Error?) async {
        guard !ended, !suspended, !transitioning else { return }
        let now = Date()
        streamFailures = streamFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        if streamFailures.count > 6 {
            end(.captureFailed(error?.localizedDescription ?? "capture keeps stopping"))
            return
        }
        stream = nil
        await suspend()
        nextResumeAttempt = Date().addingTimeInterval(0.5)
    }

    // MARK: layers

    private func startWindowStream() async throws {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw BackendError.captureFailed(error.localizedDescription) }
        guard let scw = content.windows.first(where: { $0.windowID == window.id.number }) else { throw BackendError.windowNotFound }
        sink.resetFrameCount()
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: scw), configuration: windowConfiguration(), delegate: sink)
        do {
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "seethru.capture", qos: .userInteractive))
            try await s.startCapture()
        } catch { throw BackendError.captureFailed(error.localizedDescription) }
        stream = s
    }

    /// Keep one backdrop per screen the window touches.
    private func rebuildCovers() async {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        covers.forEach { $0.stop() }
        covers.removeAll()
        for rect in BackdropCover.visibleRects(origin: frame.origin, size: frame.size) {
            let c = BackdropCover(rect: rect, originalID: window.id.number, hub: hub, floating: true)
            do { try await c.start(); covers.append(c) } catch { c.stop() }
        }
        lastHoles = nil
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
        lastHoles = nil
    }

    /// Same for the window capture's size.
    private func scheduleWindowConfig() {
        if configuring { configAgain = true; return }
        configuring = true
        Task { @MainActor in
            repeat {
                configAgain = false
                try? await stream?.updateConfiguration(windowConfiguration())
            } while configAgain && !ended
            configuring = false
        }
    }

    /// Orders the panels in: backdrops first, overlay on top (both at the floating level).
    private func showGroup() {
        guard !ended, let overlay else { return }
        shown = true
        covers.forEach { $0.setVisible(true) }
        overlay.orderFrontRegardless()
    }

    private func hideGroup() {
        shown = false
        covers.forEach { $0.setVisible(false) }
        overlay?.orderOut(nil)
    }

    private func buildOverlay() {
        let p = NSPanel(contentRect: ScreenGeometry.appKitFrame(fromCG: frame), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true // real input goes to the original underneath
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.canHide = false
        p.level = .floating
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
