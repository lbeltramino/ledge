import AppKit
import QuartzCore

/// The small dip under a press.
///
/// It is the one motion token the spec named and nothing used. Ninety
/// milliseconds and 1.5% — far too small to notice, and immediately obvious by
/// its absence once you have felt it.
extension NSView {
    func flashPress() {
        guard !Motion.reduceMotion else { return }
        wantsLayer = true
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1.0, 0.985, 1.0]
        dip.keyTimes = [0, 0.45, 1]
        dip.duration = 0.09
        dip.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        layer.add(dip, forKey: "press")
    }
}
