import AppKit

/// The deck's window.
///
/// A `.nonactivatingPanel` is the entire reason hovering the deck does not
/// disturb what you were doing: it can show, fan and preview without ever
/// taking key status away from the app you are typing in. It only becomes key
/// when you deliberately click into a note to write.
final class DeckPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 24, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // the cards draw their own
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        worksWhenModal = false
    }

    /// The Dock draws above `.floating`, so a strip living in the Dock's band
    /// needs to sit one level above it — while staying below the menu bar.
    static let aboveDock = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    /// Only when we ask for it — see `DeckController.beginEditing`.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
