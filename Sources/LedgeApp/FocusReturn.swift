import AppKit

/// The half of the focus choreography people actually notice.
///
/// Hovering, fanning and previewing never touch focus at all. Only a deliberate
/// click into a note activates Ledge — and when that note is dismissed, focus
/// has to go back where it came from. Without this, closing a note drops you on
/// the Finder and you have to go find your editor again.
@MainActor
final class FocusReturn {

    private var previous: NSRunningApplication?

    /// Call immediately *before* activating, while the other app is still front.
    func capture() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previous = front
    }

    func restore() {
        defer { previous = nil }
        guard let previous, !previous.isTerminated else { return }
        previous.activate()
    }

    func forget() { previous = nil }
}
