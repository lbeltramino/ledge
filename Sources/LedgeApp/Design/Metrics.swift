import AppKit

/// Every number the deck is made of, in one place — and now every one of them
/// scales.
///
/// `zoom` moves the whole deck together. `tabScale` and `cardScale` are second
/// multipliers for the case where the edge feels right but the note does not.
/// Values are rounded to whole points so nothing lands on a half pixel.
@MainActor
enum Metrics {

    static var zoom: CGFloat { Settings.zoom }

    /// Scales with the deck as a whole.
    static func z(_ value: CGFloat) -> CGFloat { (value * zoom).rounded() }
    /// Scales with the deck, then with the tab size preference.
    static func t(_ value: CGFloat) -> CGFloat { (value * zoom * Settings.tabScale).rounded() }
    /// Scales with the deck, then with the card size preference.
    static func c(_ value: CGFloat) -> CGFloat { (value * zoom * Settings.cardScale).rounded() }

    @MainActor
    enum Pill {
        static var visibleWidth: CGFloat { t(16) }
        /// The panel is wider than it paints. The extra is transparent, and it
        /// is the whole reason the deck needs no Accessibility permission: a
        /// tracking area over this margin catches the pointer before it reaches
        /// the screen edge, where a global mouse monitor would be the only
        /// other option.
        static var hitMargin: CGFloat { z(14) }
        static var panelWidth: CGFloat { visibleWidth + hitMargin }

        static var cornerRadius: CGFloat { t(7) }
        static var dashSize: CGSize { CGSize(width: t(12), height: t(4)) }
        static var dashGap: CGFloat { t(6) }
        static var verticalPadding: CGFloat { t(8) }
    }

    @MainActor
    enum Tab {
        static var width: CGFloat { t(38) }
        /// A tab is as long as its title needs, between these. Uniform tabs read
        /// as a segmented control; tabs that fit their words read as paper.
        static var minHeight: CGFloat { t(62) }
        static var maxHeight: CGFloat { t(Settings.tabMaxLength) }
        /// Air beyond the text, so a label never touches the fold.
        static var labelSlack: CGFloat { t(26) }
        static var cornerRadius: CGFloat { t(11) }
        static var hitMargin: CGFloat { z(16) }
        static var panelWidth: CGFloat { width + hitMargin }
        static var labelSize: CGFloat { max(8, t(11)) }
        static var labelInset: CGFloat { t(13) }
        /// The perforation: a dashed fold line between the label and the edge.
        static var foldInset: CGFloat { t(9) }
    }

    /// The full editor. Bigger than a card because it is a window you opened
    /// on purpose, but it still follows the size setting — it was the one place
    /// that did not, and it is the place you read in.
    @MainActor
    enum Editor {
        static var bodySize: CGFloat { z(20) }
        static var titleSize: CGFloat { z(22) }
    }

    @MainActor
    enum Card {
        static var width: CGFloat { c(300) }
        static var height: CGFloat { c(340) }
        static var minWidth: CGFloat { c(240) }
        static var minHeight: CGFloat { c(170) }
        static var maxWidth: CGFloat { c(760) }
        static var maxHeight: CGFloat { c(900) }
        static var cornerRadius: CGFloat { c(10) }
        static var padding: CGFloat { c(16) }
        static var titleGap: CGFloat { c(10) }
        /// The card is the tab, grown. This strip is the part that was the tab:
        /// same colour, same vertical title, now on the card's leading edge.
        static var labelStrip: CGFloat { max(Tab.width * 0.9, c(30)) }
        /// The card runs past the screen edge so its lean never opens a corner
        /// gap. The overhang is clipped by the panel.
        static var overhang: CGFloat { z(5) }
        static var panelWidth: CGFloat { width + z(26) }
        static var bodySize: CGFloat { c(17) }
        static var titleSize: CGFloat { c(14) }
    }

    @MainActor
    enum Plus {
        static var size: CGFloat { t(26) }
        static var gap: CGFloat { t(12) }
    }

    /// Breathing room so a leaning tab and its shadow are never clipped.
    static var panelPadding: CGFloat { z(18) }
}
