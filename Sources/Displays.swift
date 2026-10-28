// Display plumbing: finding the glasses, 120 Hz, the virtual monitor that gets pinned in space,
// arranging displays, and keeping the cursor off the glasses' own (physical) display.

import AppKit
import CoreGraphics

enum Displays {
    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func id(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.id(of: $0) == id }
    }

    /// The glasses' physical display (EDID name "SmartGlasses").
    static func glasses() -> NSScreen? {
        NSScreen.screens.first {
            let n = $0.localizedName.lowercased()
            return n.contains("smartglasses") || n.contains("rayneo")
        }
    }

    static func builtin() -> CGDirectDisplayID? {
        online().first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func name(of id: CGDirectDisplayID) -> String {
        screen(for: id)?.localizedName ?? "Display \(id)"
    }

    /// Switches the glasses to 1920×1080 at `hz` if such a mode exists. After the panel command
    /// 0x21 the glasses start advertising 120 Hz modes.
    @discardableResult
    static func setRefresh(_ hz: Double, glasses id: CGDirectDisplayID) -> Bool {
        if let cur = CGDisplayCopyDisplayMode(id), abs(cur.refreshRate - hz) < 1, cur.pixelWidth == 1920 { return true }
        guard let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode],
              let mode = modes.first(where: { $0.width == 1920 && $0.pixelWidth == 1920 && $0.pixelHeight == 1080 && abs($0.refreshRate - hz) < 1 })
        else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// Virtual monitor centered above the main display; the glasses' physical display to the right
    /// of the main display, where the cursor fence keeps the pointer out.
    static func arrange(virtual vid: CGDirectDisplayID?, glasses gid: CGDirectDisplayID?) {
        let main = CGMainDisplayID()
        guard main != vid, main != gid else { return }
        let mb = CGDisplayBounds(main)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        if let vid {
            let vb = CGDisplayBounds(vid)
            CGConfigureDisplayOrigin(config, vid, Int32(mb.midX - vb.width / 2), Int32(mb.minY - vb.height))
        }
        if let gid {
            let gb = CGDisplayBounds(gid)
            CGConfigureDisplayOrigin(config, gid, Int32(mb.maxX), Int32(mb.maxY - gb.height))
        }
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}

/// An extra monitor that only exists in software (private CGVirtualDisplay API, as used by
/// DeskPad, BetterDisplay and AirAnchor). It disappears when this object is released.
final class VirtualMonitor {
    enum Resolution: String, CaseIterable {
        case fhd = "1920 × 1080"
        case fhdHiDPI = "1920 × 1080 HiDPI (sharper)"
        case qhd = "2560 × 1440"

        var mode: (w: Int, h: Int, hiDPI: Bool) {
            switch self {
            case .fhd: return (1920, 1080, false)
            case .fhdHiDPI: return (3840, 2160, true)
            case .qhd: return (2560, 1440, false)
            }
        }
    }

    private let display: CGVirtualDisplay
    let resolution: Resolution
    var displayID: CGDirectDisplayID { display.displayID }

    init?(resolution: Resolution) {
        self.resolution = resolution
        let d = CGVirtualDisplayDescriptor()
        d.name = "RayNeoPin Display"
        d.maxPixelsWide = 3840
        d.maxPixelsHigh = 2160
        d.sizeInMillimeters = CGSize(width: 531, height: 299) // a 24" monitor, for macOS' default scaling
        d.vendorID = 0x524E // "RN"
        d.productID = 0x0001
        d.serialNum = 0x50494E31 // "PIN1"
        d.setDispatchQueue(.main)
        d.terminationHandler = { _, _ in NSLog("RayNeoPin: virtual display terminated by WindowServer") }
        display = CGVirtualDisplay(descriptor: d)

        let s = CGVirtualDisplaySettings()
        let m = resolution.mode
        s.hiDPI = m.hiDPI ? 1 : 0
        s.modes = [CGVirtualDisplayMode(width: UInt(m.w), height: UInt(m.h), refreshRate: 120)]
        guard display.apply(s), display.displayID != 0 else { return nil }
    }
}

/// Keeps the pointer (and so dragged windows) off the glasses' physical display: that display only
/// exists to show our rendering, so for the user there are just two screens.
final class CursorFence {
    var blocked: CGDirectDisplayID?
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func check() {
        guard let blocked, let loc = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(blocked)
        guard b.contains(loc) else { return }
        var best: CGPoint?
        var bestDistance = Double.infinity
        for id in Displays.online() where id != blocked && CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay {
            let r = CGDisplayBounds(id).insetBy(dx: 1, dy: 1)
            let p = CGPoint(x: min(max(loc.x, r.minX), r.maxX), y: min(max(loc.y, r.minY), r.maxY))
            let d = hypot(p.x - loc.x, p.y - loc.y)
            if d < bestDistance { bestDistance = d; best = p }
        }
        guard let best else { return }
        CGWarpMouseCursorPosition(best)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
