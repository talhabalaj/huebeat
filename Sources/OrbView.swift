import AppKit
import QuartzCore
import SwiftUI

/// The live orb. SwiftUI animations re-render the view graph on the main thread every display frame, which made
/// the beat pop most of the app's CPU; Core Animation runs the same spring in the render server instead.
struct ColorVisualizer: View {
    let update: ColorUpdate?
    let isRunning: Bool

    var body: some View {
        ZStack {
            OrbLayers(update: update, isRunning: isRunning)
            Image(systemName: isRunning ? "waveform" : "power")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct OrbLayers: NSViewRepresentable {
    let update: ColorUpdate?
    let isRunning: Bool

    func makeNSView(context: Context) -> OrbView { OrbView() }

    func updateNSView(_ view: OrbView, context: Context) {
        view.apply(update: update, isRunning: isRunning)
    }
}

final class OrbView: NSView {
    private let glow = CAGradientLayer()
    private let orb = CALayer()
    private let fill = CAGradientLayer()
    private let highlight = CAGradientLayer()
    private let ring = CAShapeLayer()
    private var isBeat = false

    private static let brandColors = [Brand.pink, Brand.orange, Brand.cyan].map { NSColor($0).cgColor }
    // Same feel as the old SwiftUI `.spring(response: 0.16, dampingFraction: 0.68)`.
    private static func spring() -> CASpringAnimation {
        CASpringAnimation(perceptualDuration: 0.16, bounce: 0.32)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        // A radial falloff in place of a blurred circle: same soft halo, nothing to re-blur.
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 0.45, 1]
        glow.setValue(1.08, forKeyPath: "transform.scale")

        orb.masksToBounds = true
        fill.startPoint = CGPoint(x: 0, y: 1)
        fill.endPoint = CGPoint(x: 1, y: 0)

        // Glassy highlight so the orb reads as a lit bulb, not a flat dot. Layer y runs bottom-up on macOS.
        highlight.type = .radial
        highlight.colors = [NSColor.white.withAlphaComponent(0.5).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        highlight.startPoint = CGPoint(x: 0.34, y: 0.72)
        highlight.endPoint = CGPoint(x: 0.34 + 130 / 240, y: 0.72 + 130 / 240)

        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 1
        ring.opacity = 0.16

        orb.addSublayer(fill)
        orb.addSublayer(highlight)
        layer?.addSublayer(glow)
        layer?.addSublayer(orb)
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let circle = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        // The old blur spread the glow about 50 pt past the orb's edge.
        glow.frame = circle.insetBy(dx: -60, dy: -60)
        orb.frame = circle
        orb.cornerRadius = side / 2
        fill.frame = orb.bounds
        highlight.frame = orb.bounds
        ring.frame = circle
        updateRingPath()
        CATransaction.commit()
    }

    func apply(update: ColorUpdate?, isRunning: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Colors snap, like the bulbs; only the beat pop animates.
        let colors = update.map { [NSColor($0.color).cgColor, NSColor($0.color).cgColor] } ?? Self.brandColors
        fill.colors = colors
        let glowColor = colors[0]
        glow.colors = [glowColor, glowColor, glowColor.copy(alpha: 0) ?? glowColor]
        glow.opacity = update == nil ? (isRunning ? 0.5 : 0.28) : 0.85
        orb.opacity = update == nil && !isRunning ? 0.55 : 1

        let beat = update?.beat == true
        if beat != isBeat {
            isBeat = beat
            animate(glow, "transform.scale", to: beat ? 1.3 : 1.08)
            animate(orb, "transform.scale", to: beat ? 1.05 : 1)
            animate(ring, "transform.scale", to: beat ? 1.05 : 1)
            animate(ring, "opacity", to: beat ? 0.85 : 0.16)
            animate(ring, "lineWidth", to: beat ? 3 : 1)
            updateRingPath()
        }
        CATransaction.commit()
    }

    /// Springs from wherever the layer is on screen right now, so a beat that lands mid-pop doesn't jump.
    private func animate(_ target: CALayer, _ keyPath: String, to value: CGFloat) {
        let from = target.presentation()?.value(forKeyPath: keyPath) ?? target.value(forKeyPath: keyPath)
        target.setValue(value, forKeyPath: keyPath)
        let spring = Self.spring()
        spring.keyPath = keyPath
        spring.fromValue = from
        spring.toValue = value
        spring.duration = spring.settlingDuration
        target.add(spring, forKey: keyPath)
    }

    /// Stroke inside the edge, like SwiftUI's `strokeBorder`, at the inset of the thicker beat line.
    private func updateRingPath() {
        let inset = ring.lineWidth / 2
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: inset, dy: inset), transform: nil)
    }
}
