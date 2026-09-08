import AppKit
import QuartzCore

/// The fan itself: each tab slides out from behind the screen edge, 45 ms after
/// the one above it. Collapsing runs the other way and faster.
extension NoteTabView {

    /// `hidden` is where the tab sits when the deck is folded away, as an offset
    /// in the root view's own coordinates. It comes from the strip's edge, so a
    /// bottom strip fans upward out of the bottom of the screen rather than
    /// sideways out of the right of it.
    func slide(hiddenBy hidden: CGVector, alpha: CGFloat, animated: Bool,
               delay: TimeInterval, fanningOut: Bool) {
        wantsLayer = true
        guard let layer else { return }

        let lean = CATransform3DMakeRotation(CGFloat(jitter.tabRotation) * .pi / 180, 0, 0, 1)
        let offset = fanningOut ? CGVector.zero : hidden
        let target = CATransform3DTranslate(lean, offset.dx, offset.dy, 0)

        guard animated else {
            layer.removeAllAnimations()
            layer.transform = target
            layer.opacity = Float(alpha)
            return
        }

        let from = layer.presentation()?.transform ?? layer.transform
        let move: CABasicAnimation = fanningOut
            ? Motion.animation("transform", spring: .fanOut, delay: delay)
            : Motion.ease("transform", duration: Motion.fanInDuration, delay: delay)
        move.fromValue = from
        move.toValue = target
        layer.add(move, forKey: "slide")
        layer.transform = target

        let fade = Motion.ease("opacity",
                               duration: fanningOut ? 0.18 : Motion.fanInDuration,
                               delay: delay)
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = alpha
        layer.add(fade, forKey: "fade")
        layer.opacity = Float(alpha)
    }
}

extension NoteCardView {

    /// The note extends outward from where its tab was: it starts with only the
    /// coloured strip showing, exactly covering the tab, and slides clear to
    /// reveal the paper. One object growing, not two objects swapping — in
    /// whichever direction its strip grows.
    func slideIn(from entry: CGVector) {
        wantsLayer = true
        guard let layer else { return }
        let lean = CATransform3DMakeRotation(CGFloat(jitter.cardRotation(focused: false)) * .pi / 180, 0, 0, 1)

        let move = Motion.animation("transform", spring: .card)
        move.fromValue = CATransform3DTranslate(lean, entry.dx, entry.dy, 0)
        move.toValue = lean
        layer.add(move, forKey: "slideIn")
        layer.transform = lean

        let fade = Motion.ease("opacity", duration: 0.12)
        fade.fromValue = 0.35
        fade.toValue = 1
        layer.add(fade, forKey: "fadeIn")
        layer.opacity = 1
    }
}
