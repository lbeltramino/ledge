import AppKit

/// Recognising ⌘+, ⌘- and ⌘0 whatever keyboard they are typed on.
///
/// Declaring them as menu key equivalents looked right and left one user unable
/// to make anything bigger: on a US layout `+` is ⇧=, on a Spanish one it is a
/// key of its own and ⇧ gives `*`, and a menu item can only be told about one
/// of those. Worse, synthesised events matched the declaration in a self test
/// while a real keypress did not — so the check agreed with the code and both
/// were wrong about the keyboard.
///
/// Reading the event settles it. Both `characters` and
/// `charactersIgnoringModifiers` are consulted, because which of the two
/// carries the `+` depends on the layout, and the physical keys are taken as a
/// last resort for a layout that reports neither.
@MainActor
enum ZoomKeys {

    enum Command: Equatable {
        case bigger, smaller, actualSize
    }

    /// US positions of `=`, `-` and `0`, and their keypad twins. A fallback:
    /// on a layout where these are somewhere else, the characters above will
    /// already have matched.
    private static let codes: [UInt16: Command] = [
        24: .bigger, 69: .bigger,       // =/+  and keypad +
        27: .smaller, 78: .smaller,     // -/_  and keypad -
        29: .actualSize, 82: .actualSize,
    ]

    static func command(for event: NSEvent) -> Command? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Command, and nothing else that changes what a key means. Shift is
        // allowed because on most keyboards it is how you reach the `+`.
        guard flags.contains(.command),
              !flags.contains(.control), !flags.contains(.option), !flags.contains(.function)
        else { return nil }

        let typed = Set([event.characters, event.charactersIgnoringModifiers].compactMap { $0 })
        if typed.contains("+") { return .bigger }
        if typed.contains("=") { return .bigger }
        if typed.contains("-") || typed.contains("_") { return .smaller }
        if typed.contains("0") { return .actualSize }

        return codes[event.keyCode]
    }

    /// Applies it. Returns false when the event was not one of ours.
    @discardableResult
    static func handle(_ event: NSEvent) -> Bool {
        switch command(for: event) {
        case .bigger:     Settings.stepZoom(1)
        case .smaller:    Settings.stepZoom(-1)
        case .actualSize: Settings.resetSizes()
        case nil:         return false
        }
        return true
    }
}
