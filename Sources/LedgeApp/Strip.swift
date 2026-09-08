import AppKit

/// Which edge a strip of the deck lives on.
public enum StripEdge: String, Codable, Sendable {
    case left, right, bottom

    /// Side strips run down the screen; a bottom strip runs across it, and every
    /// piece of the layout swaps its two axes accordingly.
    var isHorizontal: Bool { self == .bottom }
    /// True where the deck grows away from the *low* coordinate edge.
    var mirrored: Bool { self == .left }

    var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .bottom: return "Bottom"
        }
    }
}

/// One strip of the deck: an edge of one screen.
///
/// On a laptop there is exactly one and you never think about it. On a 49-inch
/// display there is room for several — beside the Dock, on both sides, on a
/// second screen — and a note belongs to whichever one you put it on.
struct StripConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var edge: StripEdge
    /// The display this strip is pinned to, by its `CGDirectDisplayID`.
    var screenID: UInt32
    /// Where along the edge it sits, from -0.5 (start) through 0 (middle) to
    /// 0.5 (end). On a bottom strip that is left-to-right — which is how you put
    /// one to either side of the Dock.
    var offset: Double
    /// Bundle identifiers of apps that bring this strip out.
    ///
    /// Empty means the strip behaves normally. Non-empty makes it follow what
    /// you are doing: it fans when one of these is in front and folds when none
    /// of them is. Reading the frontmost app needs no permission — Ledge already
    /// watches it to give focus back when you close a note.
    var showsWith: [String] = []

    /// Keeps the tabs fanned instead of folding back to a stripe. On by default:
    /// the fold-away is lovely on a laptop and a way to lose a strip on a wide
    /// display. Also the decoding default, so strips saved before this existed
    /// come back visible.
    var pinned: Bool = true

    static let primaryID = "main"
    var isPrimary: Bool { id == StripConfig.primaryID }

    static func primary() -> StripConfig {
        StripConfig(id: primaryID, name: "Deck", edge: .right,
                    screenID: NSScreen.screens.first?.ledgeDisplayID ?? 0,
                    offset: 0, showsWith: [], pinned: true)
    }

    /// The screen it is pinned to, or the main one if that display has gone.
    var screen: NSScreen {
        NSScreen.screens.first { $0.ledgeDisplayID == screenID }
            ?? NSScreen.screens.first
            ?? NSScreen.main!
    }

    var screenIsPresent: Bool {
        NSScreen.screens.contains { $0.ledgeDisplayID == screenID }
    }

    /// A description a person can pick out of a menu.
    var subtitle: String {
        let screens = NSScreen.screens
        var text = "\(edge.label.lowercased()) edge"
        if abs(offset) > 0.05 { text += " · \(positionName.lowercased())" }
        if !showsWith.isEmpty { text += " · follows \(showsWith.count) app\(showsWith.count == 1 ? "" : "s")" }
        if screens.count > 1,
           let index = screens.firstIndex(where: { $0.ledgeDisplayID == screenID }) {
            text += " · display \(index + 1)"
        }
        return text
    }

    /// Whether this strip should be out, given what is in front.
    ///
    /// `nil` means "not this strip's business" — leave it however the user left
    /// it. A strip with no apps configured never answers.
    func wantsToShow(whenFrontmost bundleID: String?) -> Bool? {
        guard !showsWith.isEmpty else { return nil }
        guard let bundleID else { return false }
        return showsWith.contains(bundleID)
    }

    var positionName: String {
        if offset < -0.2 { return edge.isHorizontal ? "Left" : "Top" }
        if offset > 0.2 { return edge.isHorizontal ? "Right" : "Bottom" }
        return "Middle"
    }

    /// A bottom strip lives in the Dock's band, not above it, so it can sit to
    /// either side of the Dock instead of being pushed off by it.
    var placementFrame: NSRect {
        edge.isHorizontal ? screen.frame : screen.visibleFrame
    }
}

extension NSScreen {
    var ledgeDisplayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension Settings {

    private static let folderBookmarkKey = "ledge.notesFolderBookmark"

    /// Where the notes live, if it has been moved from the default.
    ///
    /// Stored as a security-scoped bookmark rather than a path, so it survives
    /// the folder being renamed and will keep working if the app is ever
    /// sandboxed. Falls back to nothing if the folder has gone.
    static var notesFolderOverride: URL? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
            ?? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                   bookmarkDataIsStale: &stale)
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    static func setNotesFolder(_ url: URL) {
        let data = (try? url.bookmarkData(options: [.withSecurityScope],
                                          includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
        guard let data else { return }
        UserDefaults.standard.set(data, forKey: folderBookmarkKey)
    }

    static func clearNotesFolder() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
    }

    private static let stripsKey = "ledge.strips"

    static var strips: [StripConfig] {
        get {
            guard let data = UserDefaults.standard.data(forKey: stripsKey),
                  let decoded = try? JSONDecoder().decode([StripConfig].self, from: data),
                  !decoded.isEmpty
            else { return [.primary()] }
            // The primary strip is never allowed to disappear: it is where every
            // unassigned note goes.
            return decoded.contains { $0.isPrimary } ? decoded : [.primary()] + decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: stripsKey)
            NotificationCenter.default.post(name: stripsDidChange, object: nil)
        }
    }

    static let stripsDidChange = Notification.Name("LedgeStripsDidChange")

    private static let seededKey = "ledge.seededStrips"

    /// A brand-new strip is an empty stripe with nothing to point at. Each one
    /// gets a single note the first time it appears, once and never again — so
    /// deleting the last note off a strip leaves it empty, as you asked it to.
    static func hasBeenSeeded(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: seededKey) ?? []).contains(id)
    }

    static func markSeeded(_ id: String) {
        var all = UserDefaults.standard.stringArray(forKey: seededKey) ?? []
        guard !all.contains(id) else { return }
        all.append(id)
        UserDefaults.standard.set(all, forKey: seededKey)
    }

    static func addStrip(edge: StripEdge, screen: NSScreen, offset: Double? = nil) {
        var all = strips
        let taken = all.filter { $0.edge == edge && $0.screenID == screen.ledgeDisplayID }.count
        let name = taken == 0 ? edge.label : "\(edge.label) \(taken + 1)"
        all.append(StripConfig(id: UUID().uuidString, name: name, edge: edge,
                               screenID: screen.ledgeDisplayID,
                               // a second strip on the same edge starts further along it
                               offset: offset ?? (taken == 0 ? 0 : min(0.4, Double(taken) * 0.35)),
                               showsWith: [], pinned: true))
        strips = all
    }

    static func update(_ id: String, _ change: (inout StripConfig) -> Void) {
        var all = strips
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        strips = all
    }

    static func removeStrip(id: String) {
        guard id != StripConfig.primaryID else { return }
        strips = strips.filter { $0.id != id }
    }
}
