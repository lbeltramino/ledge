import AppKit

/// The window the tab stack is seen through.
///
/// Tabs are its subviews, so a stack longer than the strip is cut off at the
/// edges of this rather than at the edge of the screen — which is what turns
/// "the rest of your notes are somewhere below the display" into "there is more
/// here, scroll". The tab straddling the boundary is the whole announcement:
/// half a tab is a thing you reach for.
final class StackClip: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Transparent except where a tab is. The panel is mostly empty space that
    /// clicks must fall through, and this view covers a good deal of it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
