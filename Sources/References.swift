// Extra drift references that don't come from the glasses: the Mac's camera (which way your face
// points, from Vision) and the text caret (while typing you look at it).

import AppKit
import AVFoundation
import QuartzCore
import Vision

/// Face yaw/pitch from the Mac's camera at ~15 Hz. The camera never moves, so the face's yaw
/// relative to it is an absolute heading: comparing it with the glasses' heading measures drift,
/// and the error never accumulates.
final class FaceTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Sample { var time: Double; var yaw: Double; var pitch: Double }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "face", qos: .userInitiated)
    private let request = VNDetectFaceRectanglesRequest()
    private let lock = NSLock()
    private var pending: [Sample] = []
    private var lastRun = 0.0
    private var configured = false
    private var statusText = "starting"

    var status: String {
        lock.lock(); defer { lock.unlock() }
        return statusText
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                if ok { self?.run() } else { self?.setStatus("camera access denied") }
            }
        default:
            setStatus("camera access denied (System Settings › Privacy & Security › Camera)")
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func drain() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        let s = pending
        pending.removeAll(keepingCapacity: true)
        return s
    }

    private func setStatus(_ s: String) {
        lock.lock(); statusText = s; lock.unlock()
    }

    private func run() {
        queue.async { [self] in
            if !configured {
                guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera) else {
                    setStatus("no camera")
                    return
                }
                session.beginConfiguration()
                if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 } // plenty for a face, cheap
                if session.canAddInput(input) { session.addInput(input) }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                request.revision = VNDetectFaceRectanglesRequestRevision3 // continuous yaw and pitch
                configured = true
            }
            session.startRunning()
            setStatus("looking for your face")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let arrival = CACurrentMediaTime()
        guard arrival - lastRun > 1.0 / 15, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastRun = arrival
        // Capture timestamps are on the host clock; fall back to arrival minus a typical delay.
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        let time = pts.isFinite && abs(arrival - pts) < 0.5 ? pts : arrival - 0.05
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up)
        try? handler.perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              face.confidence > 0.6, let yaw = face.yaw?.doubleValue else {
            setStatus("no face in view")
            return
        }
        let sample = Sample(time: time, yaw: yaw, pitch: face.pitch?.doubleValue ?? 0)
        lock.lock()
        pending.append(sample)
        if pending.count > 60 { pending.removeFirst(pending.count - 60) }
        statusText = "tracking"
        lock.unlock()
    }
}

/// The text caret of the focused app, through the Accessibility API (same permission as moving
/// windows off the fenced display).
enum Caret {
    /// Global rect (top-left origin) of the caret or selection, nil when there is none.
    static func rect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1) // a hung app must not stall us
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &r), r.width < 4000, r.height > 0 else { return nil }
        return r
    }
}
