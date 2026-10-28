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

    /// `above`: the display you work on in the glasses, centered above the main display.
    /// `right`: a display that only shows our rendering, parked to the right (and fenced off).
    static func arrange(above vid: CGDirectDisplayID?, right gid: CGDirectDisplayID?) {
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
///
/// The display offers every 16:9 size below both at 1x and HiDPI, so the resolution can follow
/// the zoom without recreating the display (which would throw its windows onto another screen).
final class VirtualMonitor {
    enum Resolution: String, CaseIterable {
        case crisp = "Crisp — follows zoom, text stays sharp (recommended)"
        case fhd = "Fixed 1920 × 1080 — zoom scales text"
        case fhdHiDPI = "Fixed 1920 × 1080 HiDPI"
        case qhd = "Fixed 2560 × 1440"
    }

    static let widths = [960, 1120, 1280, 1440, 1600, 1760, 1920, 2240, 2560, 3200, 3840]

    private let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    init?() {
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
        s.hiDPI = 1
        s.modes = VirtualMonitor.widths.map { CGVirtualDisplayMode(width: UInt($0), height: UInt($0 * 9 / 16), refreshRate: 120) }
        guard display.apply(s), display.displayID != 0 else { return nil }
    }

    /// Logical width of the mode to use: for `.crisp`, the one closest to how many glasses pixels
    /// the screen covers, so one desktop pixel lands on one glasses pixel.
    static func logicalWidth(for r: Resolution, coveredPixels: Double) -> (width: Int, hiDPI: Bool) {
        switch r {
        case .crisp: return (widths.min { abs(Double($0) - coveredPixels) < abs(Double($1) - coveredPixels) }!, false)
        case .fhd: return (1920, false)
        case .fhdHiDPI: return (1920, true)
        case .qhd: return (2560, false)
        }
    }

    func setMode(width: Int, hiDPI: Bool) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let mode = modes.first(where: { $0.width == width && $0.height == width * 9 / 16 && $0.pixelWidth == (hiDPI ? 2 * width : width) })
        else { return }
        if let cur = CGDisplayCopyDisplayMode(displayID), cur.width == mode.width, cur.pixelWidth == mode.pixelWidth { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}

/// Cursor handling for the glasses' physical display:
///  - `blocked`: with a virtual monitor, the glasses' display only shows our rendering, so the
///    pointer (and dragged windows) are kept off it;
///  - `hideOn`: when the glasses' own desktop is the pinned screen, the hardware cursor would be
///    drawn over our rendering at its unpinned position, so it is hidden while it's on that display
///    (the pinned image still shows it, captured with the desktop).
final class CursorFence {
    var blocked: CGDirectDisplayID?
    var hideOn: CGDirectDisplayID? { didSet { if hideOn == nil { setHidden(false) } } }
    private var timer: Timer?
    private var hidden = false

    func start() {
        // Background apps may only hide the cursor with this WindowServer property.
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() { setHidden(false) }

    private func setHidden(_ hide: Bool) {
        guard hide != hidden else { return }
        hidden = hide
        if hide { CGDisplayHideCursor(kCGNullDirectDisplay) } else { CGDisplayShowCursor(kCGNullDirectDisplay) }
    }

    private func check() {
        guard let loc = CGEvent(source: nil)?.location else { return }
        if let hideOn { setHidden(CGDisplayBounds(hideOn).contains(loc)) }
        guard let blocked else { return }
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
