@preconcurrency import ScreenCaptureKit
import AppKit
import os

/// One display capture per display, shared by every `BackdropCover` on it, instead of one capture per window.
/// The capture covers the union of its covers' rectangles and excludes every Seethru window plus every original window
/// that currently has a cover. (Two overlapping transparent windows therefore see through each other's original; that
/// is the price of sharing.) A display with no covers has no capture running.
@MainActor
final class BackdropHub {
    private var displays: [CGDirectDisplayID: DisplayBackdrop] = [:]

    func attach(_ cover: BackdropCover) async throws {
        guard let id = cover.displayID else { throw BackendError.captureFailed("no display for the backdrop") }
        let d = displays[id] ?? DisplayBackdrop(displayID: id, hub: self)
        displays[id] = d
        d.covers.append(cover)
        do { try await d.sync() } catch {
            detach(cover)
            throw error
        }
        Task { await refreshFilters() } // other displays must now exclude this cover's original too
    }

    func detach(_ cover: BackdropCover) {
        for (id, d) in displays {
            guard let i = d.covers.firstIndex(where: { $0 === cover }) else { continue }
            d.covers.remove(at: i)
            if d.covers.isEmpty {
                d.stop()
                displays[id] = nil
            } else {
                Task { try? await d.sync() }
            }
        }
        Task { await refreshFilters() } // the set of excluded originals changed
    }

    func coverMoved(_ cover: BackdropCover) async {
        guard let d = displays.values.first(where: { $0.covers.contains { $0 === cover } }) else { return }
        try? await d.sync()
    }

    func refreshFilters() async {
        for d in Array(displays.values) { await d.refreshFilter() }
    }

    /// Window numbers whose originals must be excluded from every capture.
    var excludedOriginals: Set<UInt32> { Set(displays.values.flatMap(\.covers).map(\.originalID)) }
}

@MainActor
private final class DisplayBackdrop {
    let displayID: CGDirectDisplayID
    unowned let hub: BackdropHub
    var covers: [BackdropCover] = []
    private var stream: SCStream?
    private let sink = BackdropSink()
    private var captureRect = CGRect.zero // CG coordinates of what the stream currently captures
    private var syncing = false
    private var syncAgain = false

    init(displayID: CGDirectDisplayID, hub: BackdropHub) {
        self.displayID = displayID
        self.hub = hub
        sink.onFrame = { [weak self] surface in
            nonisolated(unsafe) let s = surface
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(s) } }
        }
    }

    private func deliver(_ surface: IOSurface) {
        for c in covers { c.deliver(surface, captureRect: captureRect) }
    }

    /// Starts the capture, or re-aims it at the union of the covers' rectangles.
    func sync() async throws {
        if syncing { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            let union = covers.map(\.rect).reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull else { return }
            if stream == nil {
                captureRect = union
                let (filter, _) = try await makeFilter()
                let s = SCStream(filter: filter, configuration: configuration(), delegate: sink)
                try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "seethru.backdrop", qos: .userInteractive))
                try await s.startCapture()
                stream = s
            } else if union != captureRect {
                captureRect = union
                try? await stream?.updateConfiguration(configuration())
            }
        } while syncAgain
    }

    func refreshFilter() async {
        guard stream != nil, let (filter, _) = try? await makeFilter() else { return }
        try? await stream?.updateContentFilter(filter)
    }

    func stop() {
        sink.onFrame = nil
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
    }

    private func makeFilter() async throws -> (SCContentFilter, SCShareableContent) {
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // Every cover panel must be known to ScreenCaptureKit before it can be excluded.
        let panels = Set(covers.map { CGWindowID($0.windowNumber) })
        for _ in 0..<10 where !panels.isSubset(of: Set(content.windows.map(\.windowID))) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw BackendError.captureFailed("display not found")
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let originals = hub.excludedOriginals
        let excluded = content.windows.filter { originals.contains($0.windowID) || $0.owningApplication?.processID == me }
        return (SCContentFilter(display: display, excludingWindows: excluded), content)
    }

    private func configuration() -> SCStreamConfiguration {
        let frames = ScreenGeometry.cgScreenFrames()
        let index = NSScreen.screens.firstIndex { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID } ?? 0
        let origin = index < frames.count ? frames[index].origin : .zero
        let scale = index < NSScreen.screens.count ? NSScreen.screens[index].backingScaleFactor : 2
        let c = SCStreamConfiguration()
        c.sourceRect = CGRect(x: captureRect.minX - origin.x, y: captureRect.minY - origin.y,
                              width: captureRect.width, height: captureRect.height)
        c.width = max(1, Int(captureRect.width * scale))
        c.height = max(1, Int(captureRect.height * scale))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        return c
    }
}

private final class BackdropSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (IOSurface) -> Void)?>(initialState: nil)
    var onFrame: (@Sendable (IOSurface) -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        onFrame?(surface)
    }
}
