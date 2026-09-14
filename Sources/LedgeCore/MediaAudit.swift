import Foundation

/// Which pictures in the folder are still spoken for, and which nothing points
/// at any more.
///
/// Pure arithmetic over names, sizes and dates — the file system belongs to the
/// caller. That is what lets the interesting decisions be checked without a
/// folder full of fixtures, and the interesting decisions here are all about
/// *not* deleting something.
public enum MediaAudit {

    public struct Picture: Equatable, Sendable {
        public let name: String
        public let bytes: Int
        public let modified: Date

        public init(name: String, bytes: Int, modified: Date) {
            self.name = name
            self.bytes = bytes
            self.modified = modified
        }
    }

    public struct Report: Equatable, Sendable {
        /// Some note mentions it.
        public let used: [Picture]
        /// Nothing mentions it, and it is old enough to act on.
        public let unused: [Picture]
        /// Nothing mentions it *yet* — see `grace`.
        public let tooRecent: [Picture]

        public var usedBytes: Int { used.reduce(0) { $0 + $1.bytes } }
        public var unusedBytes: Int { unused.reduce(0) { $0 + $1.bytes } }
    }

    /// How long a picture nothing points at is left alone.
    ///
    /// A week, because the ways a reference goes missing for a moment are all
    /// short: pasting and undoing, cutting a paragraph to move it, or a note
    /// that has not arrived on this machine yet because iCloud is still
    /// thinking about it. The cost of waiting is some bytes; the cost of not
    /// waiting is a note somewhere else pointing at nothing.
    public static let grace = 7

    /// Is this picture spoken for?
    ///
    /// The test is whether the file's *name* appears anywhere in any note, not
    /// whether Ledge would draw a picture there. A reference in the middle of a
    /// sentence, one inside a code fence, one in a link rather than an image —
    /// none of those are drawn, and every one of them is somebody meaning to
    /// keep the file. Deliberately generous: the failure this must never have
    /// is calling something unused when it is not.
    public static func isMentioned(_ name: String, in notes: [String]) -> Bool {
        notes.contains { $0.contains(name) }
    }

    public static func report(pictures: [Picture], notes: [String],
                              grace: Int = grace, now: Date = Date()) -> Report {
        var used: [Picture] = []
        var unused: [Picture] = []
        var tooRecent: [Picture] = []
        let cutoff = now.addingTimeInterval(-Double(grace) * 86_400)

        for picture in pictures.sorted(by: { $0.name < $1.name }) {
            if isMentioned(picture.name, in: notes) {
                used.append(picture)
            } else if picture.modified > cutoff {
                tooRecent.append(picture)
            } else {
                unused.append(picture)
            }
        }
        return Report(used: used, unused: unused, tooRecent: tooRecent)
    }

    /// Where a picture goes instead of being deleted.
    ///
    /// Moved, never removed: this is somebody's folder, and it is allowed to
    /// contain files Ledge knows nothing about. A wrong answer here should cost
    /// a `mv` to undo, not a backup.
    public static let trash = "\(Media.folder)/trash"

    /// Bytes, said the way a person would.
    public static func readable(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) bytes"
    }
}
