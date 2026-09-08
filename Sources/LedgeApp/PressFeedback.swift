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

        // Scale about the middle *without* touching anchorPoint. A layer-backed
        // AppKit view anchors at (0, 0) with its position at the frame origin,
        // so moving the anchor shifts the view by half its size and leaves it
        // there — which looked like every control jumping when one was pressed.
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        func about(_ scale: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(centre.x, centre.y, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            return CATransform3DTranslate(t, -centre.x, -centre.y, 0)
        }

        let dip = CAKeyframeAnimation(keyPath: "transform")
        dip.values = [about(1), about(0.985), about(1)]
        dip.keyTimes = [0, 0.45, 1]
        dip.duration = 0.09
        dip.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        layer.add(dip, forKey: "press")
    }
}
