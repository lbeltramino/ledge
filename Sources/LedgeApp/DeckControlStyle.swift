import AppKit

/// How the deck's two controls are made — the plus and the pin.
///
/// They used to be white at 80% opacity with no shadow, which over a coloured
/// wallpaper is neither the app nor the desktop: the purple underneath tints
/// them and they read as glass sitting on paper. Everything else in the deck is
/// opaque and casts a shadow, so these do too.
///
/// One place, because there were two copies of the same four lines and copies
/// drift.
@MainActor
enum DeckControlStyle {
    /// Opaque, and neutral rather than white: sampled off the drawing the deck
    /// is designed after, which uses #E3E4EA.
    static let fill = NSColor.srgb(0xE7E8EC)
    static let fillHovering = NSColor.srgb(0xF2F3F6)
    /// The same slate the tabs are lettered in.
    static var ink: NSColor { Palette.labelInk(.butter) }

    /// A smaller relative of the card's shadow, so a control sits on the desk
    /// the way a note does.
    static func shadow() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.22)
        s.shadowBlurRadius = 7
        s.shadowOffset = NSSize(width: 0, height: -2)
        return s
    }

    /// The disc, drawn into the current context.
    static func disc(in bounds: NSRect, hovering: Bool) {
        (hovering ? fillHovering : fill).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
