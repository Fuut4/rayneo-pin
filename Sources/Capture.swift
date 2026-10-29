// ScreenCaptureKit capture of a display or window into a single "latest frame" slot.

import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum Source: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onError: ((String) -> Void)?
    var onStarted: (() -> Void)?
    /// Window numbers of our own windows, excluded from display captures.
    var ownWindowIDs: () -> [CGWindowID] = { [] }
    private(set) var source: Source?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)

    private let lock = NSLock()
    // Holding the pixel buffer keeps ScreenCaptureKit from recycling its IOSurface while we draw it.
    private var latest: CVPixelBuffer?
    private var serial = 0
    /// Union of the areas that changed since the renderer last took a frame, in buffer pixels;
    /// nil means "everything" (first frame, or ScreenCaptureKit didn't say).
    private var dirty: CGRect?
    /// Buffer pixels per point of the source, to convert ScreenCaptureKit's dirty rects (points).
    private var pointScale = 1.0

    /// Changes whenever a new frame arrives (cheap check for "anything new to draw?").
    func latestSerial() -> Int {
        lock.lock(); defer { lock.unlock() }
        return serial
    }

    /// The newest frame and a counter that changes whenever a new frame arrives.
    func latestFrame() -> (CVPixelBuffer, Int)? {
        lock.lock(); defer { lock.unlock() }
        return latest.map { ($0, serial) }
    }

    /// The newest frame plus what changed since the previous call (nil: assume everything).
    func takeFrame() -> (buffer: CVPixelBuffer, serial: Int, dirty: CGRect?)? {
        lock.lock(); defer { lock.unlock() }
        guard let latest else { return nil }
        let d = dirty
        dirty = .null
        return (latest, serial, d)
    }

    /// Filter and pixel size for a source, from the current window list.
    private func makeFilter(_ source: Source) async throws -> (SCContentFilter, CGSize, points: CGFloat)? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        switch source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id })
            else { onError?("Display \(id) is not available for capture"); return nil }
            // Never capture our own windows: when the source is the glasses' own display, our
            // rendering sits on top of exactly what we capture. ScreenCaptureKit doesn't tie a
            // menu-bar app's windows to the app, so match them by window number.
            let ours = Set(ownWindowIDs())
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { ours.contains($0.windowID) })
            let mode = CGDisplayCopyDisplayMode(id)
            return (filter, CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height), CGFloat(display.width))
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id })
            else { onError?("That window no longer exists"); return nil }
            return (SCContentFilter(desktopIndependentWindow: window), CGSize(width: window.frame.width * 2, height: window.frame.height * 2), window.frame.width)
        }
    }

    func start(_ source: Source) async {
        await stop()
        self.source = source
        // Resting: remember what to capture, start it on resume. Nothing else may restart it,
        // or macOS keeps showing "Currently Sharing" with the glasses off.
        if resting { paused = true; return }
        do {
            guard let (filter, captured, points) = try await makeFilter(source) else { return }
            var size = captured
            let cap = 3840.0
            if size.width > cap { size = CGSize(width: cap, height: (size.height * cap / size.width).rounded()) }

            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            lock.lock()
            pointScale = size.width / max(points, 1)
            dirty = nil
            lock.unlock()
            config.height = Int(size.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.queueDepth = 4
            // For displays we draw the cursor ourselves (smoother, and it works while the hardware
            // cursor is hidden over the glasses); a single window keeps the captured one.
            if case .window = source { config.showsCursor = true } else { config.showsCursor = false }
            config.scalesToFit = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            paused = false
            DispatchQueue.main.async { self.onStarted?() }
        } catch {
            onError?("Capture: \(error.localizedDescription)")
        }
    }

    /// A fullscreen app on another Space can leave the stream "frozen": frames keep arriving as
    /// complete but show a stale image. Re-applying the filter in place fixes it without the
    /// black flash of a restart (rokid-spatial's finding). Called on Space changes.
    func refreshFilter() async {
        guard let stream, let source, !paused, let (filter, _, _) = try? await makeFilter(source) else { return }
        try? await stream.updateContentFilter(filter)
        refreshes += 1
    }

    private(set) var refreshes = 0
    private(set) var paused = false

    /// True while the glasses aren't worn or aren't plugged in: no capture at all.
    private(set) var resting = false

    func setResting(_ on: Bool) async {
        guard on != resting else { return }
        resting = on
        if on {
            paused = true
            await stop()
        } else if paused, let source {
            await start(source)
        }
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb)
        else { return }
        // Changed areas, in points; scaled up (and padded), so a wrong guess only copies more.
        let rects = (attachments.first?[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0) }
        lock.lock()
        latest = pb
        serial &+= 1
        if let rects, let d = dirty {
            dirty = rects.reduce(d) { $0.union(CGRect(x: $1.minX * pointScale, y: $1.minY * pointScale, width: $1.width * pointScale,
                                                      height: $1.height * pointScale).insetBy(dx: -4, dy: -4)) }
        } else {
            dirty = nil
        }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onError?("Capture stopped: \(error.localizedDescription)") }
    }
}
