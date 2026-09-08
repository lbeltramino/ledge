import Foundation
import LedgeCore

/// What the index knows about a note without opening its file.
/// Enough to draw the deck and every list row; the body is read on demand.
public struct NoteRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var filename: String
    public var title: String
    public var color: NoteColor
    public var state: NoteState
    public var rank: String
    public var tags: [String]
    public var strip: String
    public var snippet: String
    public var created: Date
    public var updated: Date

    // reconciliation
    public var mtime: Double
    public var size: Int
    public var hash: String

    // ephemeral UI state — expendable on a rebuild, which is what makes
    // "the index is disposable" an honest claim rather than a slogan
    public var width: Double?
    public var height: Double?

    public init(
        id: String, filename: String, title: String, color: NoteColor, state: NoteState,
        rank: String, tags: [String], strip: String, snippet: String, created: Date, updated: Date,
        mtime: Double, size: Int, hash: String, width: Double? = nil, height: Double? = nil
    ) {
        self.id = id; self.filename = filename; self.title = title; self.color = color
        self.state = state; self.rank = rank; self.tags = tags; self.strip = strip; self.snippet = snippet
        self.created = created; self.updated = updated
        self.mtime = mtime; self.size = size; self.hash = hash
        self.width = width; self.height = height
    }

    public var displayTitle: String { title.isEmpty ? Note.untitled : title }

    public init(note: Note, filename: String, mtime: Double, size: Int, hash: String,
                width: Double? = nil, height: Double? = nil) {
        self.init(
            id: note.id, filename: filename, title: note.title, color: note.color,
            state: note.state, rank: note.rank, tags: note.tags, strip: note.strip,
            snippet: note.snippet,
            created: note.created, updated: note.updated,
            mtime: mtime, size: size, hash: hash, width: width, height: height
        )
    }
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var record: NoteRecord
    /// Match context from FTS5, with the matched terms wrapped in `\u{2)`-free
    /// sentinels the UI turns into emphasis.
    public var excerpt: String
    public var id: String { record.id }

    public static let openMark  = "\u{E000}"
    public static let closeMark = "\u{E001}"
}
