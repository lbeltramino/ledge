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
    /// Text or a file let go over the deck.
    var onDrop: ((String) -> Void)?
    /// The pointer is dragging something over it — worth showing.
    var onDragHover: ((Bool) -> Void)?

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

    // MARK: - dropping things on the edge

    /// What the strip will take. Plain text and a file that is text, which
    /// between them cover a selection dragged out of any app and a note
    /// dragged out of the Finder.
    static let droppable: [NSPasteboard.PasteboardType] = [.string, .fileURL]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropText(from: sender) != nil else { return [] }
        onDragHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropText(from: sender) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragHover?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragHover?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHover?(false)
        guard let text = dropText(from: sender) else { return false }
        onDrop?(text)
        return true
    }

    private func dropText(from sender: NSDraggingInfo) -> String? {
        let board = sender.draggingPasteboard
        if let text = board.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        // A file, if it is one we can read as text. A dropped image would make
        // a note of mojibake, so it is refused rather than mangled.
        guard let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first,
              let contents = try? String(contentsOf: url, encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return contents
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent)   { report(event) }
    override func mouseExited(with event: NSEvent)  { onPointerOutside?() }
}
