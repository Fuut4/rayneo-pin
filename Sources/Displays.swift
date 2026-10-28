// Display plumbing: finding the glasses, 120 Hz, the virtual monitor that gets pinned in space,
// arranging displays, and keeping the cursor off the glasses' own (physical) display.

import AppKit
import CoreGraphics
import QuartzCore

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

    /// Side screens sit level with the main pinned display, to its left and right, so the pointer
    /// moves between them the way it looks in the glasses.
    static func arrangeSides(of main: CGDirectDisplayID, left: CGDirectDisplayID?, right: CGDirectDisplayID?) {
        guard left != nil || right != nil else { return }
        let mb = CGDisplayBounds(main)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        if let left { CGConfigureDisplayOrigin(config, left, Int32(mb.minX - CGDisplayBounds(left).width), Int32(mb.minY)) }
        if let right { CGConfigureDisplayOrigin(config, right, Int32(mb.maxX), Int32(mb.minY)) }
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
        case crispRetina = "Crisp Retina 16:9 — macOS draws text at 2×, cleanest text"
        case crisp = "Crisp 16:9 — follows zoom, text stays sharp"
        case fhd = "1920 × 1080 (16:9)"
        case fhdHiDPI = "1920 × 1080 HiDPI (16:9)"
        case qhd = "2560 × 1440 (16:9)"
        case wuxga = "1920 × 1200 (16:10)"
        case wqxga = "2560 × 1600 (16:10)"
        case uw2560 = "2560 × 1080 (21:9)"
        case uw3440 = "3440 × 1440 (21:9)"
        case uw3840x1080 = "3840 × 1080 (32:9)"
        case uw3840x1200 = "3840 × 1200 (32:10)"
        case manual = "Manual — pick it in System Settings › Displays"

        var isUltrawide: Bool { self.rawValue.contains("21:9") || self.rawValue.contains("32:") }

        /// (logical width, height, HiDPI); nil when the user picks the mode in System Settings.
        func mode(coveredPixels: Double) -> (w: Int, h: Int, hiDPI: Bool)? {
            switch self {
            case .crisp:
                let w = VirtualMonitor.widths.min { abs(Double($0) - coveredPixels) < abs(Double($1) - coveredPixels) }!
                return (w, w * 9 / 16, false)
            case .crispRetina:
                // Same text size as Crisp, but rendered with twice the pixels and shrunk 2:1 in the
                // glasses, like a Retina Mac's scaled modes: no 1×-text resampling blur.
                let retina = VirtualMonitor.widths.filter { VirtualMonitor.widths.contains($0 * 2) }
                let w = retina.min { abs(Double($0) - coveredPixels) < abs(Double($1) - coveredPixels) }!
                return (w, w * 9 / 16, true)
            case .fhd: return (1920, 1080, false)
            case .fhdHiDPI: return (1920, 1080, true)
            case .qhd: return (2560, 1440, false)
            case .wuxga: return (1920, 1200, false)
            case .wqxga: return (2560, 1600, false)
            case .uw2560: return (2560, 1080, false)
            case .uw3440: return (3440, 1440, false)
            case .uw3840x1080: return (3840, 1080, false)
            case .uw3840x1200: return (3840, 1200, false)
            case .manual: return nil
            }
        }
    }

    static let widths = [960, 1120, 1280, 1440, 1600, 1760, 1920, 2240, 2560, 3200, 3840]
    /// Every mode the display offers, also listed in System Settings › Displays. With HiDPI on,
    /// macOS adds a half-size "looks like" variant of each.
    static let sizes: [(Int, Int)] = widths.map { ($0, $0 * 9 / 16) }
        + [(1920, 1200), (2560, 1600), (2560, 1080), (3440, 1440), (3840, 1080), (3840, 1200)]

    private let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    /// `index` 0 is the main pinned screen; 1 and 2 are side screens (left, right).
    init?(name: String = "RayNeoPin Display", index: UInt32 = 0) {
        let d = CGVirtualDisplayDescriptor()
        d.name = name
        d.maxPixelsWide = 3840
        d.maxPixelsHigh = 2160
        d.sizeInMillimeters = CGSize(width: 531, height: 299) // a 24" monitor, for macOS' default scaling
        d.vendorID = 0x524E // "RN"
        d.productID = 0x0001 + index
        d.serialNum = 0x50494E31 + index // "PIN1"
        d.setDispatchQueue(.main)
        d.terminationHandler = { _, _ in NSLog("RayNeoPin: virtual display terminated by WindowServer") }
        display = CGVirtualDisplay(descriptor: d)

        let s = CGVirtualDisplaySettings()
        s.hiDPI = 1
        s.modes = VirtualMonitor.sizes.map { CGVirtualDisplayMode(width: UInt($0.0), height: UInt($0.1), refreshRate: 120) }
        guard display.apply(s), display.displayID != 0 else { return nil }
    }

    func setMode(width: Int, height: Int, hiDPI: Bool) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let mode = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == (hiDPI ? 2 * width : width) })
        else { return }
        if let cur = CGDisplayCopyDisplayMode(displayID), cur.width == mode.width, cur.height == mode.height,
           cur.pixelWidth == mode.pixelWidth { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}

/// Moves other apps' windows off a display (the fenced glasses display, which only shows our
/// rendering), keeping their relative position. Needs Accessibility permission.
enum WindowRescue {
    /// Returns how many windows were moved, and whether permission is missing.
    static func move(from source: CGRect, to target: CGRect, askPermission: Bool) -> (moved: Int, needsPermission: Bool) {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids = Set<pid_t>()
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), source.contains(CGPoint(x: r.midX, y: r.midY))
            else { continue }
            pids.insert(pid)
        }
        guard !pids.isEmpty else { return (0, false) }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: askPermission] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return (0, true) }

        var moved = 0
        for pid in pids {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
            for window in value as? [AXUIElement] ?? [] {
                var p = CGPoint.zero, s = CGSize.zero
                var pv: CFTypeRef?, sv: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pv)
                AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sv)
                guard let pv, let sv else { continue }
                AXValueGetValue(pv as! AXValue, .cgPoint, &p)
                AXValueGetValue(sv as! AXValue, .cgSize, &s)
                guard source.contains(CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)) else { continue }
                // Same relative spot on the target, kept fully inside it.
                var np = CGPoint(x: target.minX + (p.x - source.minX) / source.width * target.width,
                                 y: target.minY + (p.y - source.minY) / source.height * target.height)
                np.x = min(max(np.x, target.minX), max(target.maxX - s.width, target.minX))
                np.y = min(max(np.y, target.minY), max(target.maxY - s.height, target.minY))
                if let nv = AXValueCreate(.cgPoint, &np),
                   AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, nv) == .success { moved += 1 }
            }
        }
        return (moved, false)
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
    private var hides = 0 // outstanding CGDisplayHideCursor calls
    private var lastHide = 0.0

    func start() {
        // Background apps may only hide the cursor with this WindowServer property.
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    func stop() { setHidden(false) }

    /// The active app re-shows the cursor whenever it changes its shape (I-beam, hand…), so while
    /// it's over the glasses the hide is re-asserted every 100 ms; leaving balances every call.
    private func setHidden(_ hide: Bool) {
        if hide {
            let now = CACurrentMediaTime()
            guard hides == 0 || now - lastHide > 0.1 else { return }
            lastHide = now
            CGDisplayHideCursor(kCGNullDirectDisplay)
            hides += 1
        } else {
            while hides > 0 { CGDisplayShowCursor(kCGNullDirectDisplay); hides -= 1 }
        }
    }

    /// Called by the app at display rate (one timer for this and the drawn cursor).
    func check() {
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
