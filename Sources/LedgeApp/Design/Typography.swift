import AppKit
import LedgeCore

/// Handwriting is the default note face. It is not decoration: with the jitter,
/// it is what stops a note reading as a rounded rectangle with text in it.
///
/// Its one real weakness — long lines, URLs, code — is fixed narrowly rather
/// than by abandoning the face: it is set larger than a UI face, anything that
/// must be read exactly falls back to a monospace, and the card levels out under
/// the caret.
@MainActor
enum Typography {

    /// The app's two hands. `NoteFace` in LedgeCore is the same pair, written
    /// into a note that asks for one of its own — one enum for the file, one
    /// for the drawing, and this maps between them.
    enum Face: String {
        case casual   // Caveat, bundled
        case legible  // New York, ships with macOS

        init(_ face: NoteFace) {
            self = face == .casual ? .casual : .legible
        }

        var asNoteFace: NoteFace { self == .casual ? .casual : .legible }
    }

    static var noteFace: Face { Settings.noteFace }

    /// The hand a particular note is written in: its own if it asked for one,
    /// otherwise whatever the app is set to.
    static func noteBody(size: CGFloat = 17, face: NoteFace?) -> NSFont {
        guard let face else { return noteBody(size: size) }
        return body(size: size, face: Face(face))
    }

    static func noteBody(size: CGFloat = 17) -> NSFont {
        body(size: size, face: effectiveFace)
    }

    private static func body(size: CGFloat, face: Face) -> NSFont {
        switch face {
        case .casual:
            return NSFont(name: "Caveat", size: size)
                ?? NSFont(name: "Bradley Hand", size: size * 0.94)
                ?? legibleBody(size: size)
        case .legible:
            // The serif needs less size than the handwriting to read as easily.
            return legibleBody(size: size * 0.82)
        }
    }

    private static func legibleBody(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Anyone who has asked the system for more contrast gets the legible face,
    /// whatever the preference says.
    static var effectiveFace: Face {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .legible : noteFace
    }

    static func noteTitle() -> NSFont { .systemFont(ofSize: 14, weight: .semibold) }
    static func chrome() -> NSFont { .systemFont(ofSize: 13) }
    static func metadata() -> NSFont { .systemFont(ofSize: 11) }

    /// Things you are going to paste into a terminal never get handwritten.
    static func exact() -> NSFont {
        .monospacedSystemFont(ofSize: 12, weight: .regular)
    }
}
