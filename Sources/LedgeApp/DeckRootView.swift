import AppKit

/// The panel's content view. Two jobs, both load-bearing:
///
/// 1. **Click-through.** The panel is far wider than the deck paints, so every
///    transparent point must return `nil` from `hitTest` or the deck would
///    silently eat clicks meant for the app underneath.
/// 2. **Hover.** A tracking area over the panel reports the pointer against the
///    live region — the strip, the tabs, the open card. This is what replaces a
///    global mouse monitor, and with it the Accessibility permission prompt.
final class DeckRootView: NSView {

    var liveRegion: NSRect = .zero { didSet { needsLayout = true } }
    var onPointerInside: ((NSPoint) -> Void)?
    var onPointerOutside: (() -> Void)?
    /// A flick along the edge, for a stack longer than the strip.
    var onScroll: ((CGFloat) -> Void)?

    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit !== self { return hit }                 // a pill, tab, card or button
        let local = convert(point, from: superview)
        return liveRegion.contains(local) ? self : nil // transparent: fall through
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if liveRegion.contains(point) {
            onPointerInside?(point)
        } else {
            onPointerOutside?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Only over the deck itself. Everywhere else the panel is transparent
        // and the scroll belongs to whatever is underneath.
        guard liveRegion.contains(point) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        onScroll?(delta)
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent)   { report(event) }
    override func mouseExited(with event: NSEvent)  { onPointerOutside?() }
}
