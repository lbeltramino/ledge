import AppKit
import QuartzCore

/// The motion tokens from the spec, as real numbers.
///
/// Retreat is faster than approach throughout: something that leaves as slowly
/// as it arrives feels reluctant.
enum Motion {

    static let hoverDwell: TimeInterval = 0.080
    static let tabDwell: TimeInterval = 0.060
    static let leaveGrace: TimeInterval = 0.250
    /// How long after the wheel stops before a tab under the pointer counts as
    /// hovered again. Without it, a flick down a long deck opens every note it
    /// drags past a stationary pointer.
    static let scrollQuiet: TimeInterval = 0.300

    static let fanOutStagger: TimeInterval = 0.045
    static let fanInStagger: TimeInterval = 0.024
    static let fanInDuration: TimeInterval = 0.200

    struct Spring {
        var response: TimeInterval
        var damping: Double

        static let fanOut = Spring(response: 0.32, damping: 0.80)
        static let card   = Spring(response: 0.28, damping: 0.85)

        var omega: Double { 2 * .pi / response }
        var stiffness: Double { omega * omega }
        var dampingCoefficient: Double { 2 * damping * omega }
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A spring on `keyPath`, or — under Reduce Motion — a short cross-fade,
    /// with every stagger collapsed to zero.
    static func animation(_ keyPath: String, spring: Spring, delay: TimeInterval = 0) -> CABasicAnimation {
        if reduceMotion {
            let a = CABasicAnimation(keyPath: keyPath)
            a.duration = 0.120
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            return a
        }
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = spring.stiffness
        a.damping = spring.dampingCoefficient
        a.initialVelocity = 0
        a.duration = a.settlingDuration
        if delay > 0 {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
        }
        return a
    }

    static func ease(_ keyPath: String, duration: TimeInterval, delay: TimeInterval = 0) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.duration = reduceMotion ? 0.120 : duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if delay > 0 && !reduceMotion {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
        }
        return a
    }

    static func stagger(_ index: Int, of count: Int, fanningOut: Bool) -> TimeInterval {
        guard !reduceMotion else { return 0 }
        return fanningOut
            ? Double(index) * fanOutStagger
            : Double(count - 1 - index) * fanInStagger
    }
}
