import AppKit
import LedgeCore

/// Everything the deck lets you tune, backed by `UserDefaults`.
///
/// One master `zoom` scales the whole deck at once — the simple knob. `tabScale`
/// and `cardScale` sit on top of it for the case where the tabs feel right but
/// the note is cramped, or the other way round.
@MainActor
enum Settings {

    static let didChange = Notification.Name("LedgeSettingsDidChange")

    enum Key: String {
        case zoom = "ledge.zoom"
        case tabScale = "ledge.tabScale"
        case cardScale = "ledge.cardScale"
        case noteFace = "ledge.noteFace"
        case tabMaxLength = "ledge.tabMaxLength"
    }

    /// How long a tab is allowed to grow before its title starts truncating.
    static let lengthPresets: [Preset] = [
        Preset(name: "Short", value: 110),
        Preset(name: "Medium", value: 150),
        Preset(name: "Long", value: 200),
        Preset(name: "Longest", value: 280),
    ]

    /// Every step is a visible difference; there is no point offering 1.03.
    static let zoomSteps: [CGFloat] = [0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 1.75]

    struct Preset: Equatable {
        let name: String
        let value: CGFloat
    }
    static let sizePresets: [Preset] = [
        Preset(name: "Small", value: 0.85),
        Preset(name: "Medium", value: 1.0),
        Preset(name: "Large", value: 1.2),
        Preset(name: "Extra large", value: 1.45),
    ]

    private static func read(_ key: Key, default fallback: CGFloat) -> CGFloat {
        let value = UserDefaults.standard.double(forKey: key.rawValue)
        return value > 0 ? CGFloat(value) : fallback
    }

    private static func write(_ key: Key, _ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: key.rawValue)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static var zoom: CGFloat {
        get { min(2.0, max(0.7, read(.zoom, default: 1.0))) }
        set { write(.zoom, min(2.0, max(0.7, newValue))) }
    }

    static var tabScale: CGFloat {
        get { min(1.8, max(0.7, read(.tabScale, default: 1.0))) }
        set { write(.tabScale, newValue) }
    }

    static var cardScale: CGFloat {
        get { min(1.8, max(0.7, read(.cardScale, default: 1.0))) }
        set { write(.cardScale, newValue) }
    }

    static var tabMaxLength: CGFloat {
        get { min(320, max(80, read(.tabMaxLength, default: 150))) }
        set { write(.tabMaxLength, newValue) }
    }

    static var noteFace: Typography.Face {
        get { Typography.Face(rawValue: UserDefaults.standard.string(forKey: Key.noteFace.rawValue) ?? "") ?? .casual }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.noteFace.rawValue)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Moves `zoom` one notch along `zoomSteps`.
    static func stepZoom(_ direction: Int) {
        let current = zoom
        let index = zoomSteps.enumerated()
            .min { abs($0.element - current) < abs($1.element - current) }?.offset ?? 2
        zoom = zoomSteps[min(zoomSteps.count - 1, max(0, index + direction))]
    }

    // MARK: - what you have already looked at

    /// The last `updated` you saw, per note.
    ///
    /// This is the one piece of note state that is deliberately *not* in the
    /// file. "Seen" is about you at this machine: written to the note it would
    /// show the same dot on your other Mac, and clearing it would be a write,
    /// which would wake the folder watcher, which would refresh, which would
    /// clear it again. Per-device state in a watched file is a loop.
    private static let seenKey = "ledge.seen"

    static func lastSeen(_ id: String) -> Date? {
        guard let stamps = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double],
              let seconds = stamps[id] else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func markSeen(_ id: String, at date: Date) {
        var stamps = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double]) ?? [:]
        stamps[id] = date.timeIntervalSince1970
        UserDefaults.standard.set(stamps, forKey: seenKey)
    }

    /// True when something has written to this note since you last looked.
    ///
    /// Only for notes on a feed: an ordinary note is one you wrote yourself, and
    /// telling you that you have not read your own writing is noise.
    static func hasUnseen(feed: String, id: String, updated: Date) -> Bool {
        guard !feed.isEmpty else { return false }
        guard let seen = lastSeen(id) else { return true }
        return updated > seen
    }

    /// Drops what we remember about notes that no longer exist, so the map
    /// tracks the folder rather than growing forever.
    static func forgetSeen(keeping ids: Set<String>) {
        guard var stamps = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double],
              stamps.keys.contains(where: { !ids.contains($0) }) else { return }
        stamps = stamps.filter { ids.contains($0.key) }
        UserDefaults.standard.set(stamps, forKey: seenKey)
    }

    static func resetSizes() {
        UserDefaults.standard.removeObject(forKey: Key.zoom.rawValue)
        UserDefaults.standard.removeObject(forKey: Key.tabScale.rawValue)
        UserDefaults.standard.removeObject(forKey: Key.cardScale.rawValue)
        UserDefaults.standard.removeObject(forKey: Key.tabMaxLength.rawValue)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
