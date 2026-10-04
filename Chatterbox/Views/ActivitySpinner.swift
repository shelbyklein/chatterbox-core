import AppKit
import SwiftUI

/// A small spinning arc in any color. Core Animation turns it, so SwiftUI does no work per
/// frame; with Reduce Motion on it holds still.
struct ActivitySpinner: NSViewRepresentable {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.arc.strokeColor = NSColor(color).cgColor
        view.setSpinning(!reduceMotion)
    }

    final class SpinnerView: NSView {
        let arc = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineWidth = 1.6
            arc.lineCap = .round
            arc.strokeEnd = 0.72
            layer?.addSublayer(arc)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let side = min(bounds.width, bounds.height)
            arc.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            arc.path = CGPath(ellipseIn: arc.bounds.insetBy(dx: arc.lineWidth / 2, dy: arc.lineWidth / 2), transform: nil)
        }

        func setSpinning(_ spinning: Bool) {
            let running = arc.animation(forKey: "spin") != nil
            guard spinning != running else { return }
            if spinning {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 0.9
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                arc.add(spin, forKey: "spin")
            } else {
                arc.removeAnimation(forKey: "spin")
            }
        }
    }
}
