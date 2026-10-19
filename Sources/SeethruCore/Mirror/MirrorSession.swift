import AppKit
import ApplicationServices
import ScreenCaptureKit
import PrivateAPI
import os

/// Draws a captured frame stream of ONE foreign window into a borderless overlay with reduced alpha,
/// while the original window is parked off-screen via Accessibility.
@MainActor
final class MirrorSession {
    let window: WindowInfo
    private(set) var alpha: Double
    private(set) var options: WindowOptions
    var onEnded: (@MainActor (WindowID, BackendError?) -> Void)?

    private let resolver: any AXWindowIDResolving
    private let journal: HiddenWindowJournal

    private var panel: MirrorPanel!
    private var view: MirrorView!
    private var stream: SCStream?
    private let sink = FrameSink()
    private var ax: AXWindow?
    private var home = CGPoint.zero      // where the window appears on screen (CG coords)
    private var anchor = CGPoint.zero    // where the original actually is while hidden
    private var size = CGSize.zero
    private var hidden = false
    private var timer: Timer?
    private var tickCount = 0
    private var ended = false

    init(window: WindowInfo, alpha: Double, options: WindowOptions, resolver: any AXWindowIDResolving, journal: HiddenWindowJournal) {
        self.window = window
        self.alpha = alpha
        self.options = options
        self.resolver = resolver
        self.journal = journal
    }

    // MARK: lifecycle

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw BackendError.permissionMissing(.screenRecording) }
        guard AXIsProcessTrusted() else { throw BackendError.permissionMissing(.accessibility) }
        guard let axw = AXWindow.find(pid: window.id.pid, number: window.id.number, resolver: resolver) else {
            throw BackendError.windowNotFound
        }
        ax = axw
        home = axw.position ?? window.bounds.origin
        size = axw.size ?? window.bounds.size

        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw BackendError.captureFailed(error.localizedDescription) }
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id.number }) else { throw BackendError.windowNotFound }

        buildPanel()
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: configuration(), delegate: sink)
        sink.onStop = { [weak self] error in
            Task { @MainActor in self?.end(error.map { .captureFailed($0.localizedDescription) }) }
        }
        sink.view = view
        do {
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "seethru.capture", qos: .userInteractive))
            try await s.startCapture()
        } catch {
            teardownPanel()
            throw BackendError.captureFailed(error.localizedDescription)
        }
        stream = s

        // Do not hide the original until we are actually showing its pixels.
        for _ in 0..<30 where sink.frameCount == 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard sink.frameCount > 0 else { await abort(); throw BackendError.captureFailed("no frames received") }

        do { try hideOriginal() } catch { await abort(); throw error }

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func update(alpha: Double, options: WindowOptions) {
        let animate = abs(alpha - self.alpha) > 0.001
        self.alpha = alpha
        self.options = options
        applyPanelState(animated: animate)
    }

    /// Stops mirroring and puts the original window back where it was.
    func stop() {
        guard !ended else { return }
        ended = true
        timer?.invalidate()
        revealOriginal()
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        teardownPanel()
    }

    private func abort() async {
        ended = true
        revealOriginal()
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        teardownPanel()
    }

    private func end(_ error: BackendError?) {
        guard !ended else { return }
        stop()
        onEnded?(window.id, error)
    }

    // MARK: original window

    /// Tries the four far corners and keeps the one that leaves the least of the window on a screen.
    private func hideOriginal() throws {
        guard let ax else { throw BackendError.windowNotFound }
        journal.add(HiddenWindowEntry(pid: window.id.pid, windowNumber: window.id.number, originX: home.x, originY: home.y))
        let corners = [CGPoint(x: -20000, y: -20000), CGPoint(x: -20000, y: 20000),
                       CGPoint(x: 20000, y: -20000), CGPoint(x: 20000, y: 20000)]
        let total = size.width * size.height
        var best: (requested: CGPoint, actual: CGPoint, area: CGFloat)?
        for c in corners {
            ax.setPosition(c)
            usleep(40_000)
            guard let actual = ax.position else { continue }
            let area = ScreenGeometry.visibleArea(CGRect(origin: actual, size: size))
            if best == nil || area < best!.area { best = (c, actual, area) }
            if area == 0 { break }
        }
        guard let best, best.area / max(total, 1) <= ScreenGeometry.parkedVisibleShare else {
            ax.setPosition(home)
            journal.remove(pid: window.id.pid, windowNumber: window.id.number)
            throw BackendError.cannotHideOriginal
        }
        ax.setPosition(best.requested)
        usleep(40_000)
        anchor = ax.position ?? best.actual
        hidden = true
    }

    private func revealOriginal() {
        guard hidden, let ax else { return }
        ax.setPosition(home)
        hidden = false
        journal.remove(pid: window.id.pid, windowNumber: window.id.number)
    }

    // MARK: per-tick tracking

    private func tick() {
        guard !ended, let ax else { return }
        tickCount += 1
        guard let pos = ax.position else {
            if !CGWindowListContains(window.id.number) { end(nil) }
            return
        }
        if ScreenGeometry.visibleArea(CGRect(origin: pos, size: size)) > size.width * size.height * 0.5 {
            // Something pulled the original back on-screen (display change, app logic). Park it again.
            ax.setPosition(anchor)
        } else if abs(pos.x - anchor.x) > 0.5 || abs(pos.y - anchor.y) > 0.5 {
            // The hidden window was moved (forwarded title-bar drag, app-driven move): follow it.
            home.x += pos.x - anchor.x
            home.y += pos.y - anchor.y
            anchor = pos
            panel.setFrame(ScreenGeometry.appKitFrame(fromCG: CGRect(origin: home, size: size)), display: false)
        }
        if let s = ax.size, abs(s.width - size.width) > 0.5 || abs(s.height - size.height) > 0.5 {
            size = s
            panel.setFrame(ScreenGeometry.appKitFrame(fromCG: CGRect(origin: home, size: size)), display: true)
            view.frame = NSRect(origin: .zero, size: size)
            view.targetOrigin = anchor
            if let stream { Task { try? await stream.updateConfiguration(configuration()) } }
        }
        view.targetOrigin = anchor
        if tickCount % 3 == 0 { keepZOrder() }
        if tickCount % 10 == 0, !CGWindowListContains(window.id.number) { end(nil) }
    }

    /// Keep the overlay directly above the (hidden) original so it stacks like the real window did.
    private func keepZOrder() {
        guard !options.alwaysOnTop else { return }
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let numbers = rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        guard let own = numbers.firstIndex(of: UInt32(panel.windowNumber)),
              let orig = numbers.firstIndex(of: window.id.number) else { return }
        if own != orig - 1 { panel.order(.above, relativeTo: Int(window.id.number)) }
    }

    // MARK: panel + stream config

    private func buildPanel() {
        let frame = ScreenGeometry.appKitFrame(fromCG: CGRect(origin: home, size: size))
        let p = MirrorPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        let v = MirrorView(frame: NSRect(origin: .zero, size: size))
        v.wantsLayer = true
        v.layer?.contentsGravity = .resize
        v.targetPID = window.id.pid
        v.targetWID = window.id.number
        v.targetOrigin = home
        v.onActivate = { [weak self] in
            guard let self else { return }
            NSRunningApplication(processIdentifier: self.window.id.pid)?.activate()
            self.ax?.raise()
        }
        p.contentView = v
        panel = p
        view = v
        applyPanelState(animated: false)
        p.orderFrontRegardless()
        p.order(.above, relativeTo: Int(window.id.number))
    }

    private func applyPanelState(animated: Bool) {
        panel.level = options.alwaysOnTop ? .floating : .normal
        panel.ignoresMouseEvents = options.clickThrough
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = alpha
            }
        } else {
            panel.alphaValue = alpha
        }
    }

    private func teardownPanel() {
        sink.view = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        view = nil
    }

    private func configuration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let scale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        c.width = max(1, Int(size.width * scale))
        c.height = max(1, Int(size.height * scale))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.ignoreShadowsSingleWindow = true
        return c
    }
}

private func CGWindowListContains(_ number: UInt32) -> Bool {
    let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]] ?? []
    return rows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number }
}

// MARK: - overlay window

final class MirrorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows frames and forwards mouse input to the hidden original via CGEvent.postToPid.
/// Keyboard input needs no forwarding: clicking activates the owning app, whose key window is the hidden original.
final class MirrorView: NSView {
    var targetPID: pid_t = 0
    var targetWID: UInt32 = 0
    var targetOrigin = CGPoint.zero // CG coords of the hidden original's top-left
    var onActivate: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func cgPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: targetOrigin.x + p.x, y: targetOrigin.y + (bounds.height - p.y))
    }

    private func post(_ type: CGEventType, _ e: NSEvent, button: CGMouseButton = .left) {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cgPoint(e), mouseButton: button) else { return }
        ev.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(targetWID)) // window under pointer
        ev.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(targetWID)) // ...that can handle this event
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, e.clickCount)))
        ev.flags = CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue) & 0xFFFF0000)
        ev.postToPid(targetPID)
    }

    override func mouseDown(with e: NSEvent) { onActivate?(); post(.leftMouseDown, e) }
    override func mouseUp(with e: NSEvent) { post(.leftMouseUp, e) }
    override func mouseDragged(with e: NSEvent) { post(.leftMouseDragged, e) }
    override func mouseMoved(with e: NSEvent) { post(.mouseMoved, e) }
    override func rightMouseDown(with e: NSEvent) { onActivate?(); post(.rightMouseDown, e, button: .right) }
    override func rightMouseUp(with e: NSEvent) { post(.rightMouseUp, e, button: .right) }

    override func scrollWheel(with e: NSEvent) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(e.scrollingDeltaY), wheel2: Int32(e.scrollingDeltaX), wheel3: 0) else { return }
        ev.location = cgPoint(e)
        ev.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(targetWID))
        ev.postToPid(targetPID)
    }
}

// MARK: - capture sink

final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let frames = OSAllocatedUnfairLock(initialState: 0)
    private let viewLock = OSAllocatedUnfairLock<NSView?>(initialState: nil)
    var onStop: (@Sendable (Error?) -> Void)?

    var frameCount: Int { frames.withLock { $0 } }
    var view: NSView? {
        get { viewLock.withLock { $0 } }
        set { viewLock.withLock { $0 = newValue } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        frames.withLock { $0 += 1 }
        // Zero-copy: the IOSurface goes straight into the layer.
        nonisolated(unsafe) let s = surface
        DispatchQueue.main.async { [weak self] in self?.view?.layer?.contents = s }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}
