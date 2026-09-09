import Foundation
import LedgeCore

/// The notes folder, without the index.
///
/// This is what something *other than the app* uses: the `ledge` command, and
/// anything built on it. It deliberately never opens the SQLite index — that is
/// the app's cache, and two processes writing it is a problem nobody needs to
/// have. Writing the file is enough: the app is watching the folder and will
/// re-read and re-index whatever changed, within 150 ms.
///
/// Reads and writes go through `FileIO`, so they are coordinated with the app's
/// own saves rather than racing them.
public struct FeedStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public struct Entry: Sendable {
        public var note: Note
        public var url: URL
    }

    /// Every note in the folder. A folder scan rather than a query: dozens of
    /// small files, read once per command, against never having to keep a
    /// second copy of the truth in sync.
    public func notes() throws -> [Entry] {
        try FileIO.noteFilenames(in: folder).compactMap { name -> Entry? in
            let url = folder.appendingPathComponent(name)
            guard let loaded = try? FileIO.read(url) else { return nil }
            let note = Frontmatter.parse(loaded.text,
                                         fallbackTitle: (name as NSString).deletingPathExtension,
                                         fallbackID: nil)
            return Entry(note: note, url: url)
        }
    }

    /// A note by id, or failing that by title.
    ///
    /// Agents are given ids and lose them; a title is what a person puts in a
    /// prompt. An exact title wins over a partial one, and an ambiguous partial
    /// match is refused rather than guessed at.
    public func find(_ reference: String) throws -> Entry? {
        let all = try notes()
        if let byID = all.first(where: { $0.note.id == reference }) { return byID }

        let wanted = fold(reference)
        guard !wanted.isEmpty else { return nil }
        if let exact = all.first(where: { fold($0.note.title) == wanted }) { return exact }

        let partial = all.filter { fold($0.note.title).contains(wanted) }
        return partial.count == 1 ? partial[0] : nil
    }

    private func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public func create(title: String, body: String = "", feed: String = "",
                       strip: String = "", color: NoteColor? = nil) throws -> Entry {
        let existing = try notes()
        let last = existing.filter { $0.note.state == .active }
            .map(\.note.rank).max()
        let taken = Set(try FileIO.noteFilenames(in: folder).map { $0.lowercased() })

        let now = Date()
        let note = Note(
            title: title,
            color: color ?? NoteColor.next(after: existing.last?.note.color),
            rank: (try? Rank.between(last, nil)) ?? Rank.initial,
            strip: strip,
            feed: feed,
            created: now, updated: now,
            body: body
        )
        let url = folder.appendingPathComponent(Filename.unique(for: note.displayTitle, taken: taken))
        _ = try FileIO.write(Frontmatter.serialize(note), to: url)
        return Entry(note: note, url: url)
    }

    /// Writes a changed note back, stamping `updated`.
    ///
    /// The file keeps its name even when the title changes: renaming is the
    /// app's business, and a rename from underneath it while it has the note
    /// open is a fight over nothing.
    @discardableResult
    public func write(_ note: Note, to url: URL) throws -> Note {
        var updated = note
        updated.updated = Frontmatter.normalized(Date())
        updated.tags = Tags.merged(existing: note.tags, oldBody: "", newBody: note.body)
        _ = try FileIO.write(Frontmatter.serialize(updated), to: url)
        return updated
    }
}
