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

    static func resetSizes() {
        UserDefaults.standard.removeObject(forKey: Key.zoom.rawValue)
        UserDefaults.standard.removeObject(forKey: Key.tabScale.rawValue)
        UserDefaults.standard.removeObject(forKey: Key.cardScale.rawValue)
        UserDefaults.standard.removeObject(forKey: Key.tabMaxLength.rawValue)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
