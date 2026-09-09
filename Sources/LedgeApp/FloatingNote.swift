import AppKit
import LedgeCore
import LedgeIndex

/// A note pulled off the edge and left on the desk.
///
/// Drag a note away from the deck and it comes with you, the way you would peel
/// a sticky off a monitor and stick it somewhere you can see it. It stays there
/// until you push it back to the edge — the deck keeps its tab, dimmed, so
/// nothing reshuffles and you can see where it belongs.
///
/// Floating is a working state, not a stored one: the notes themselves are
/// unchanged on disk, and everything returns to the deck on relaunch.
@MainActor
final class FloatingNote: NSObject {

    let id: String
    private let panel: DeckPanel
    private let card: NoteCardView

    var onEdit: ((String) -> Void)?
    var onTitle: ((String) -> Void)?
    var onExpand: (() -> Void)?
    var onColor: ((NoteColor) -> Void)?
    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    /// Pushed back to a screen edge, or dismissed.
    var onRedock: (() -> Void)?
    /// The note was resized on the desk; the new size is worth remembering.
    var onResized: ((NSSize) -> Void)?
    /// Asked on mouse-up whether where it was *aimed* counts as an edge.
    var shouldRedock: ((NSPoint) -> Bool)?

    /// How close to the right edge counts as putting it back.
    static let snapDistance: CGFloat = 76
    /// Transparent margin around the card so its shadow is not clipped square by
    /// the window edge — which is what drew a hard black border under the note.
    static let shadowRoom: CGFloat = 28

    init(record: NoteRecord, title: String, body: String, size: NSSize) {
        self.id = record.id
        panel = DeckPanel()
        card = NoteCardView(record: record, body: body)
        card.title = title
        super.init()

        let room = FloatingNote.shadowRoom
        let outer = NSSize(width: size.width + room * 2, height: size.height + room * 2)
        panel.setFrame(NSRect(origin: .zero, size: outer), display: false)
        let host = FloatingRootView()
        host.frame = NSRect(origin: .zero, size: outer)
        card.frame = NSRect(x: room, y: room, width: size.width, height: size.height)
        card.autoresizingMask = [.width, .height]
        host.addSubview(card)
        panel.contentView = host
        // The card draws its own shadow; a window shadow on top of a transparent
        // panel would be a second, rectangular one.
        panel.hasShadow = false

        card.onEdit = { [weak self] text in self?.onEdit?(text) }
        card.onTitle = { [weak self] text in self?.onTitle?(text) }
        card.onExpand = { [weak self] in self?.onExpand?() }
        card.onClose = { [weak self] in self?.onRedock?() }
        card.onStripDrag = { [weak self] in self?.trackDrag() }
        card.onColor = { [weak self] color in self?.onColor?(color) }
        card.onArchive = { [weak self] in self?.onArchive?() }
        card.onDelete = { [weak self] in self?.onDelete?() }
        card.textView.onEscape = { [weak self] in self?.onRedock?() }
        card.resizeHandle.onResize = { [weak self] delta in self?.resize(by: delta) }
        card.resizeHandle.onFinished = { [weak self] in
            guard let self else { return }
            onResized?(card.frame.size)
        }
        card.setDetached(true)
    }

    var body: String { card.textView.string }
    var cardView: NoteCardView { card }

    func setColor(_ color: NoteColor) { card.color = color }

    func show(at origin: NSPoint) {
        let room = FloatingNote.shadowRoom
        panel.setFrameOrigin(NSPoint(x: origin.x - room, y: origin.y - room))
        panel.orderFrontRegardless()
    }

    func front() { panel.orderFrontRegardless() }

    /// Follows a change to the size settings without being rebuilt.
    func resizeToSettings(body: String) {
        card.applySizeSettings()
        // The chrome grew with it, so the window may now be too small to hold
        // the card at all.
        let room = FloatingNote.shadowRoom
        let needed = NSSize(width: card.minimumWidth + room * 2,
                            height: card.minimumHeight + room * 2)
        if panel.frame.width < needed.width || panel.frame.height < needed.height {
            panel.setFrame(NSRect(x: panel.frame.minX,
                                  y: panel.frame.maxY - max(panel.frame.height, needed.height),
                                  width: max(panel.frame.width, needed.width),
                                  height: max(panel.frame.height, needed.height)),
                           display: true)
        }
        card.frame = panel.contentView?.bounds.insetBy(dx: room, dy: room) ?? card.frame
        card.needsLayout = true
    }

    /// Where the pointer was when it was let go.
    private(set) var dropPoint: NSPoint = .zero

    /// The card's own rectangle in screen coordinates, without the transparent
    /// margin the shadow lives in.
    var frameOnScreen: NSRect {
        panel.frame.insetBy(dx: FloatingNote.shadowRoom, dy: FloatingNote.shadowRoom)
    }

    /// Grows from the free corner — the card's bottom-left — keeping the
    /// opposite corner exactly where it is, so the note does not walk across the
    /// desk while you resize it.
    private func resize(by delta: CGSize) {
        let room = FloatingNote.shadowRoom
        let current = card.frame.size
        let width = max(card.minimumWidth,
                        min(current.width - delta.width, Metrics.Card.maxWidth))
        let height = max(card.minimumHeight,
                         min(current.height - delta.height, Metrics.Card.maxHeight))

        let anchor = NSPoint(x: panel.frame.maxX - room, y: panel.frame.maxY - room)
        panel.setFrame(NSRect(x: anchor.x - width - room, y: anchor.y - height - room,
                              width: width + room * 2, height: height + room * 2),
                       display: true)
        card.frame = NSRect(x: room, y: room, width: width, height: height)
        card.needsLayout = true
        card.needsDisplay = true
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Follows the pointer until the button comes up, then either stays where it
    /// was dropped or slides back onto the edge.
    /// Keeps a dragged note out of the menu bar, and *only* the menu bar.
    ///
    /// This used to clamp to `visibleFrame`, whose bottom edge is the top of the
    /// Dock's band — an invisible floor that made a bottom strip literally
    /// unreachable by dragging. The full `frame` is the right bound: the screen
    /// is the desk.
    static func clamped(origin: NSPoint, panelSize: NSSize, screen: NSScreen) -> NSPoint {
        var origin = origin
        origin.y = min(origin.y, screen.visibleFrame.maxY - panelSize.height)
        origin.y = max(origin.y, screen.frame.minY - shadowRoom)
        origin.x = min(origin.x, screen.frame.maxX - panelSize.width + shadowRoom)
        origin.x = max(origin.x, screen.frame.minX - shadowRoom)
        return origin
    }

    func trackDrag() {
        let startMouse = NSEvent.mouseLocation
        let startOrigin = panel.frame.origin

        // Above the Dock while it is in the air, so it is never dragged behind
        // it, and back down to the desk when it lands.
        let restingLevel = panel.level
        panel.level = .popUpMenu

        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if event.type == .leftMouseUp { dropPoint = NSEvent.mouseLocation; break }
            let now = NSEvent.mouseLocation
            let origin = NSPoint(x: startOrigin.x + (now.x - startMouse.x),
                                 y: startOrigin.y + (now.y - startMouse.y))
            // Clamp against whichever screen the pointer is over, so a drag can
            // cross displays.
            let screen = NSScreen.screens.first { $0.frame.contains(now) }
                ?? panel.screen ?? NSScreen.main
            guard let screen else { continue }
            panel.setFrameOrigin(FloatingNote.clamped(origin: origin,
                                                      panelSize: panel.frame.size,
                                                      screen: screen))
        }

        panel.level = restingLevel

        // Judged by the pointer, not by the note's rectangle. A card is 300 pt
        // wide; dragged to a bottom strip it can still overlap the right one it
        // came from, and the nearest-rectangle rule would send it straight back.
        // You aim with the pointer, so the pointer decides.
        if shouldRedock?(NSEvent.mouseLocation) == true { onRedock?() }
    }
}

/// Transparent host so the card's shadow and lean are not clipped.
final class FloatingRootView: NSView {
    override var isFlipped: Bool { true }
}
