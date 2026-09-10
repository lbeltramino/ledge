import Foundation

/// Real sticky notes are never square to the edge, and a stack of them never
/// aligns. The deck reproduces that: every note gets a small rotation, offset
/// and overlap of its own.
///
/// The values are *derived from the note's id*, not random. A note leans the
/// same way on every launch, on every redraw, forever — the deck looks handled,
/// not glitchy. Nothing here is ever re-rolled.
///
/// The one exception is deliberate: a card straightens as you begin writing in
/// it (see `cardRotation(focused:)`). Crooked while you read, level while you
/// write, which is also what you do with paper.
///
/// Note what is *not* here: a vertical offset for tabs. In a vertical stack a
/// Y offset and `tabOverlap` are the same knob, and jittering both makes them
/// fight — the visible overlap drifts outside its range. Protrusion is the axis
/// that is genuinely free.
public struct Jitter: Sendable, Equatable {

    /// How far a tab may poke out past its neighbours, in points.
    ///
    /// This is what makes a stack read as paper rather than as a segmented
    /// control, so it is deliberately large. Named here because the geometry
    /// checks assert against it: it used to be a literal in this file and a
    /// second literal in the check, and the second one does not move when you
    /// change the first.
    public static let maxProtrusion: Double = 12

    public let tabRotation: Double     // degrees, tab against the edge
    public let tabProtrusion: Double   // points this tab pokes out past its neighbours
    public let tabOverlap: Double      // points this tab bites into the one above
    public let cardRotation: Double    // degrees, note at full size
    public let cardOffsetX: Double
    public let cardOffsetY: Double
    public let shadowScale: Double     // 0.85…1.15, so no two shadows match
    public let paperTint: Double       // -1…1, a hair lighter or darker than the swatch

    public init(id: String) {
        var rng = SplitMix64(seed: Jitter.seed(id))
        tabRotation   = rng.symmetric(0.6)
        tabProtrusion = rng.range(0, Jitter.maxProtrusion)
        tabOverlap    = rng.range(2.0, 5.0)
        cardRotation  = rng.symmetric(1.4)
        cardOffsetX   = rng.symmetric(2.0)
        cardOffsetY   = rng.symmetric(3.0)
        shadowScale   = rng.range(0.85, 1.15)
        paperTint     = rng.symmetric(1.0)
    }

    /// Cards level out under the caret. 0 while writing, full lean otherwise.
    public func cardRotation(focused: Bool) -> Double {
        focused ? 0 : cardRotation
    }

    static func seed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// 0…1
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + unit() * (hi - lo)
    }
    /// -magnitude…+magnitude, biased away from dead centre so nothing lands square
    mutating func symmetric(_ magnitude: Double) -> Double {
        let u = unit() * 2 - 1
        let sign: Double = u < 0 ? -1 : 1
        return sign * (0.35 + 0.65 * abs(u)) * magnitude
    }
}
