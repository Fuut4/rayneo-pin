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

    /// The newest frame and a counter that changes whenever a new frame arrives.
    func latestFrame() -> (CVPixelBuffer, Int)? {
        lock.lock(); defer { lock.unlock() }
        return latest.map { ($0, serial) }
    }

    func start(_ source: Source) async {
        await stop()
        self.source = source
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let filter: SCContentFilter
            var size: CGSize
            switch source {
            case .display(let id):
                guard let display = content.displays.first(where: { $0.displayID == id })
                else { onError?("Display \(id) is not available for capture"); return }
                // Never capture our own windows: when the source is the glasses' own display, our
                // rendering sits on top of exactly what we capture. ScreenCaptureKit doesn't tie a
                // menu-bar app's windows to the app, so match them by window number.
                let ours = Set(ownWindowIDs())
                filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { ours.contains($0.windowID) })
                let mode = CGDisplayCopyDisplayMode(id)
                size = CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
            case .window(let id):
                guard let window = content.windows.first(where: { $0.windowID == id })
                else { onError?("That window no longer exists"); return }
                filter = SCContentFilter(desktopIndependentWindow: window)
                size = CGSize(width: window.frame.width * 2, height: window.frame.height * 2)
            }
            let cap = 3840.0
            if size.width > cap { size = CGSize(width: cap, height: (size.height * cap / size.width).rounded()) }

            let config = SCStreamConfiguration()
            config.width = Int(size.width)
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
            DispatchQueue.main.async { self.onStarted?() }
        } catch {
            onError?("Capture: \(error.localizedDescription)")
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
        lock.lock()
        latest = pb
        serial &+= 1
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onError?("Capture stopped: \(error.localizedDescription)") }
    }
}
