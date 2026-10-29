// The one card every message uses, in the glasses and on the Mac: calibrations (AirPods, gyro,
// turn sensitivity), updates, notices and short confirmations share the same layout, wording
// style and progress bars.

import AppKit
import SwiftUI

struct OverlayState: Equatable {
    enum Tone: Equatable { case info, progress, success, warning }
    enum Bar: Equatable {
        case none
        case linear(Double)
        /// Fills outward from the center: the left half toward the left, the right half toward the right.
        case centered(left: Double, right: Double, leftLabel: String, rightLabel: String)
    }

    var tone = Tone.info
    var icon = "info.circle.fill" // SF Symbol
    var title: String
    var step: String? // "Step 1 of 2"
    var message: String?
    var bar = Bar.none
    var detail: String? // small trailing text, e.g. "34%" or "12 s"

    static func toast(_ title: String, icon: String = "checkmark.circle.fill", tone: Tone = .success) -> OverlayState {
        OverlayState(tone: tone, icon: icon, title: title)
    }

    /// Progress values rounded so the card only redraws on visible changes.
    func quantized() -> OverlayState {
        var s = self
        func q(_ x: Double) -> Double { (min(max(x, 0), 1) * 50).rounded() / 50 }
        switch bar {
        case .linear(let x): s.bar = .linear(q(x))
        case .centered(let l, let r, let a, let b): s.bar = .centered(left: q(l), right: q(r), leftLabel: a, rightLabel: b)
        case .none: break
        }
        return s
    }
}

final class OverlayModel: ObservableObject {
    @Published var state: OverlayState?
}

/// The card. In the glasses black is transparent, so it sits on a dark, opaque-looking panel.
struct OverlayCard: View {
    let state: OverlayState
    var compact = false

    private var accent: Color {
        switch state.tone {
        case .info: return Color(white: 0.85)
        case .progress: return Color(red: 0.35, green: 0.62, blue: 1)
        case .success: return Color(red: 0.3, green: 0.85, blue: 0.45)
        case .warning: return Color(red: 1, green: 0.7, blue: 0.25)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: state.icon)
                .font(.system(size: compact ? 20 : 26, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: compact ? 26 : 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.title).font(.system(size: compact ? 15 : 19, weight: .semibold))
                    if let step = state.step {
                        Text(step.uppercased())
                            .font(.system(size: compact ? 10 : 11, weight: .bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(accent.opacity(0.15), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    if let detail = state.detail {
                        Text(detail).font(.system(size: compact ? 12 : 14, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let message = state.message {
                    Text(message).font(.system(size: compact ? 13 : 16)).foregroundStyle(Color(white: 0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch state.bar {
                case .none: EmptyView()
                case .linear(let x): LinearBar(value: x, color: accent).padding(.top, 2)
                case .centered(let l, let r, let a, let b):
                    CenteredBar(left: l, right: r, leftLabel: a, rightLabel: b, color: accent).padding(.top, 2)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.vertical, compact ? 12 : 16)
        .frame(width: compact ? 400 : 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 14 : 20, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 14 : 20, style: .continuous).strokeBorder(Color(white: 0.25), lineWidth: 1))
    }
}

struct LinearBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.25))
                Capsule().fill(color).frame(width: max(g.size.width * min(max(value, 0), 1), value > 0 ? 8 : 0))
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.15), value: value)
    }
}

/// Empty at the center; each half fills outward. A finished half turns green.
struct CenteredBar: View {
    let left: Double, right: Double
    let leftLabel: String, rightLabel: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(leftLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(left >= 1 ? .green : .secondary)
                .frame(width: 44, alignment: .trailing)
            GeometryReader { g in
                let half = g.size.width / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.25))
                    Capsule().fill(left >= 1 ? Color.green : color)
                        .frame(width: half * min(max(left, 0), 1))
                        .offset(x: half * (1 - min(max(left, 0), 1)))
                    Capsule().fill(right >= 1 ? Color.green : color)
                        .frame(width: half * min(max(right, 0), 1))
                        .offset(x: half)
                    Rectangle().fill(Color.white.opacity(0.8)).frame(width: 2, height: 14).offset(x: half - 1)
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            Text(rightLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(right >= 1 ? .green : .secondary)
                .frame(width: 44, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.15), value: left)
        .animation(.easeOut(duration: 0.15), value: right)
    }
}

/// The card, centered at the bottom of an eye in the glasses.
struct GlassesOverlay: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack {
            Spacer()
            if let state = model.state {
                OverlayCard(state: state)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: model.state?.title)
        .environment(\.colorScheme, .dark)
    }
}

/// The same card on the Mac's own screen, top center, for things done with the glasses off
/// (gyro calibration on a table, updates).
final class MacCard {
    private let model = OverlayModel()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(_ state: OverlayState, hideAfter seconds: Double? = nil) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: MacCardView(model: model))
            host.frame = p.contentView!.bounds
            host.autoresizingMask = [.width, .height]
            p.contentView!.addSubview(host)
            panel = p
        }
        model.state = state
        guard let panel else { return }
        if let screen = Displays.builtin().flatMap(Displays.screen) ?? NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 220, y: f.maxY - 12))
        }
        panel.orderFrontRegardless()
        hide?.cancel()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            hide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func dismiss() {
        hide?.cancel()
        panel?.orderOut(nil)
    }
}

private struct MacCardView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        if let state = model.state {
            OverlayCard(state: state, compact: true)
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
