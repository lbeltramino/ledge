import AppKit
import LedgeCore

/// The five papers. Colour is how you recognise a note across the room — never
/// how you read it, which is why a tab always carries its title too.
enum Palette {

    static func paper(_ color: NoteColor, dark: Bool) -> NSColor {
        switch (color, dark) {
        case (.blue, false):     return .srgb(0xB6D8F2)
        case (.blue, true):      return .srgb(0x1E3448)
        case (.green, false):    return .srgb(0xB4E3C4)
        case (.green, true):     return .srgb(0x1D3F2C)
        case (.lavender, false): return .srgb(0xD3C3EE)
        case (.lavender, true):  return .srgb(0x302748)
        case (.butter, false):   return .srgb(0xFBDF7E)
        case (.butter, true):    return .srgb(0x453516)
        case (.coral, false):    return .srgb(0xF4B3AA)
        case (.coral, true):     return .srgb(0x4A2622)
        }
    }

    /// The saturated edge colour: dashes in the pill, and the tabs themselves.
    static func tab(_ color: NoteColor) -> NSColor {
        switch color {
        case .blue:     return .srgb(0x4F9BD4)
        case .green:    return .srgb(0x4FAE72)
        case .lavender: return .srgb(0x8B6FCB)
        case .butter:   return .srgb(0xD5A521)
        case .coral:    return .srgb(0xD4695C)
        }
    }

    /// A tab's label is written in a deep version of the note's own hue, not in
    /// neutral ink. It is what stops the deck reading as coloured plastic with
    /// black type on it.
    static func labelInk(_ color: NoteColor) -> NSColor {
        switch color {
        case .blue:     return .srgb(0x1B4B78)
        case .green:    return .srgb(0x1C5836)
        case .lavender: return .srgb(0x46326F)
        case .butter:   return .srgb(0x6A4C10)
        case .coral:    return .srgb(0x78302A)
        }
    }

    /// The strip down a card's leading edge: the paper, a shade deeper, so the
    /// card reads as one sheet rather than a panel bolted to a tab.
    static func stripe(_ color: NoteColor, dark: Bool) -> NSColor {
        paper(color, dark: dark).blended(withFraction: dark ? 0.14 : 0.13, of: labelInk(color))
            ?? paper(color, dark: dark)
    }

    static func ink(dark: Bool) -> NSColor {
        dark ? .srgb(0xF0EBE3) : .srgb(0x1C1917)
    }

    /// Applies a note's `paperTint` — a hair off the swatch, so no two sheets
    /// of paper are quite the same colour.
    static func paper(_ color: NoteColor, dark: Bool, tint: Double) -> NSColor {
        let base = paper(color, dark: dark)
        let delta = CGFloat(tint) * 0.016
        guard let c = base.usingColorSpace(.sRGB) else { return base }
        return NSColor(srgbRed: min(1, max(0, c.redComponent + delta)),
                       green: min(1, max(0, c.greenComponent + delta)),
                       blue: min(1, max(0, c.blueComponent + delta)),
                       alpha: c.alphaComponent)
    }

    static let pillBacking = NSColor(white: 0.11, alpha: 0.34)
}

extension NSColor {
    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
