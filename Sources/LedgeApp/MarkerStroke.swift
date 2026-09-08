import AppKit
import LedgeCore

/// A highlighter swipe, drawn behind the words.
///
/// A flat rectangle behind text is what every editor does and it looks like a
/// selection, not like a pen. This is the shape a marker actually leaves: it
/// overshoots at the start, thins as it goes, wobbles along both edges, and
/// stops short of square at the end.
///
/// The wobble is derived from the note's id, like every other irregularity in
/// Ledge, so a highlight looks the same on every redraw instead of shimmering.
enum MarkerStroke {

    /// Text carrying this is drawn over a marker swipe of that colour.
    static let attribute = NSAttributedString.Key("ledge.highlight")

    /// Highlighter yellow, on paper that is not yellow.
    ///
    /// The first version derived this from the note's own colour, which sounded
    /// tidy and meant a green note was highlighted in green — a marker that
    /// disappears into the page is not a marker. A highlight exists to contrast
    /// with the paper, so it is a fixed pen, swapped for pink on the one paper
    /// yellow cannot survive.
    ///
    /// Still no colour in the file: `==text==` stays portable, and the pen is
    /// chosen from the note rather than written into it.
    static func pen(for note: NoteColor) -> NoteColor {
        note == .butter ? .coral : .butter
    }

    /// A second pen, for search results, that is neither the paper nor the
    /// highlighter — so a `==highlight==` and a match you are stepping through
    /// never look like the same thing.
    static func findPen(for note: NoteColor) -> NoteColor {
        let highlight = pen(for: note)
        for candidate in [NoteColor.blue, .lavender, .green] where candidate != note && candidate != highlight {
            return candidate
        }
        return .lavender
    }

    static func findColour(for note: NoteColor, dark: Bool, current: Bool) -> NSColor {
        let base = Palette.tab(findPen(for: note))
        let alpha: CGFloat = current ? (dark ? 0.52 : 0.62) : (dark ? 0.24 : 0.30)
        return base.blended(withFraction: 0.10, of: .white)?.withAlphaComponent(alpha)
            ?? base.withAlphaComponent(alpha)
    }

    static func colour(for note: NoteColor, dark: Bool) -> NSColor {
        let base = Palette.tab(pen(for: note))
        return dark
            ? base.withAlphaComponent(0.40)
            : base.blended(withFraction: 0.10, of: .white)?.withAlphaComponent(0.62)
                ?? base.withAlphaComponent(0.55)
    }

    /// Draws one run of highlighted text.
    ///
    /// `seed` keeps the wobble stable; `index` varies it between separate runs
    /// so two highlights in the same note are not identical strokes.
    static func draw(in rect: NSRect, colour: NSColor, seed: String, index: Int) {
        var rng = SeededWobble(seed: seed, salt: index)

        // A pen is wider than the glyphs and sits low, the way a real one does.
        let height = rect.height * 0.72
        let body = NSRect(x: rect.minX - rng.between(1.5, 4.5),
                          y: rect.minY + rect.height * 0.10,
                          width: rect.width + rng.between(2, 6),
                          height: height)

        let path = NSBezierPath()
        let lean = rng.between(-0.6, 0.6)
        let steps = max(3, Int(body.width / 26))

        // along the top, wobbling
        path.move(to: NSPoint(x: body.minX, y: body.minY + rng.between(0, 2)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            path.line(to: NSPoint(x: body.minX + body.width * t,
                                  y: body.minY + rng.between(-1.2, 1.6) + lean * t))
        }
        // the far end: a marker lifts, it does not stop square
        path.line(to: NSPoint(x: body.maxX + rng.between(0, 3),
                              y: body.midY + rng.between(-1, 1)))
        // and back along the bottom
        for step in stride(from: steps, through: 1, by: -1) {
            let t = CGFloat(step) / CGFloat(steps)
            path.line(to: NSPoint(x: body.minX + body.width * t,
                                  y: body.maxY + rng.between(-1.6, 1.2) + lean * t))
        }
        path.line(to: NSPoint(x: body.minX - rng.between(0, 2), y: body.midY))
        path.close()

        colour.setFill()
        path.fill()

        // Where a marker starts and stops it presses harder.
        colour.withAlphaComponent(min(1, colour.alphaComponent * 1.5)).setFill()
        NSBezierPath(ovalIn: NSRect(x: body.minX - 2, y: body.minY + 1,
                                    width: 6, height: body.height - 2)).fill()
    }
}

/// The same trick as `Jitter`: irregular, but always the same irregularity.
private struct SeededWobble {
    private var state: UInt64

    init(seed: String, salt: Int) {
        var h: UInt64 = 0xcbf29ce484222325 &+ UInt64(bitPattern: Int64(salt))
        for byte in seed.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        state = h
    }

    mutating func between(_ low: CGFloat, _ high: CGFloat) -> CGFloat {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        let unit = CGFloat(Double(z >> 11) * (1.0 / 9007199254740992.0))
        return low + unit * (high - low)
    }
}
