import Foundation
import LedgeCore
import LedgeIndex

/// Owns the notes folder and keeps the index agreeing with it.
///
/// Files are the truth. Every mutation writes the file first and updates the
/// index second, so a crash between the two costs a rebuild, never a note.
public actor NoteStore {

    public let folder: URL
    private let index: NoteIndex

    /// Paths this store wrote recently, with the hash it expects to see back.
    /// The watcher drops matching events, so a 250 ms autosave never returns
    /// through FSEvents as an external change.
    private var echoes: [String: (hash: String, at: Date)] = [:]
    private static let echoWindow: TimeInterval = 4.0

    public enum Failure: Error, Equatable {
        case noteNotFound(String)
        case notADirectory(String)
    }

    public init(folder: URL, index: NoteIndex? = nil) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.index = try index ?? NoteIndex(url: folder.appendingPathComponent(NoteIndex.filename))
    }

    // MARK: - reading

    public func deck() throws -> [NoteRecord] { try index.deck() }

    public func deck(strip: String, collectingUnassigned: Bool) throws -> [NoteRecord] {
        try index.deck(strip: strip, collectingUnassigned: collectingUnassigned)
    }

    /// Moves a note to another strip. Persisted in the file, because which strip
    /// a note lives on is a decision, not a cached detail.
    @discardableResult
    public func move(id: String, toStrip strip: String) throws -> Note {
        var note = try load(id: id)
        guard note.strip != strip else { return note }
        note.strip = strip
        note.rank = (try? Rank.between(try index.maxRank(.active), nil)) ?? note.rank
        return try save(note, touch: false)
    }
    public func records(_ filter: NoteIndex.Filter = .all) throws -> [NoteRecord] { try index.all(filter) }
    public func count(_ filter: NoteIndex.Filter = .all) throws -> Int { try index.count(filter) }
    public func search(_ text: String, filter: NoteIndex.Filter = .all) throws -> [SearchHit] {
        try index.search(text, filter: filter)
    }

    /// Reads a note's full text from disk. The deck and lists run off the index;
    /// only opening a note touches the file.
    public func load(id: String) throws -> Note {
        guard let record = try index.record(id: id) else { throw Failure.noteNotFound(id) }
        let url = folder.appendingPathComponent(record.filename)
        let loaded = try FileIO.read(url)
        // A file with no `id:` must adopt the one the index already knows,
        // or every read would mint a new note.
        return Frontmatter.parse(loaded.text,
                                 fallbackTitle: titleFromFilename(record.filename),
                                 fallbackID: record.id)
    }

    // MARK: - writing

    public func create(title: String = "", color: NoteColor? = nil,
                       body: String = "", strip: String = "") throws -> Note {
        let last = try index.maxRank(.active)
        let rank = (try? Rank.between(last, nil)) ?? Rank.initial
        let previous = try index.all(.active).last?.color
        let now = Date()
        let note = Note(
            title: title,
            color: color ?? NoteColor.next(after: previous),
            rank: rank,
            strip: strip,
            created: now, updated: now,
            body: body
        )
        return try save(note, touch: false)
    }

    /// Writes the note, renaming its file if the title changed, then updates the
    /// index. `touch` bumps `updated`; a pure reorder or state change does not.
    @discardableResult
    public func save(_ note: Note, touch: Bool = true) throws -> Note {
        var note = note
        if touch { note.updated = Frontmatter.normalized(Date()) }

        let existing = try index.record(id: note.id)
        let filename = try filename(for: note, existing: existing)

        if let existing, existing.filename != filename {
            let from = folder.appendingPathComponent(existing.filename)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileIO.move(from: from, to: folder.appendingPathComponent(filename))
            }
        }

        let url = folder.appendingPathComponent(filename)
        let text = Frontmatter.serialize(note)
        let stamp = try FileIO.write(text, to: url)
        remember(filename, hash: stamp.hash)

        try index.upsert(
            NoteRecord(note: note, filename: filename, mtime: stamp.mtime, size: stamp.size,
                       hash: stamp.hash, width: existing?.width, height: existing?.height),
            body: note.searchableBody
        )
        return note
    }

    public func setState(id: String, to state: NoteState) throws -> Note {
        var note = try load(id: id)
        guard note.state != state else { return note }
        note.state = state
        if state == .active {
            note.rank = (try? Rank.between(try index.maxRank(.active), nil)) ?? note.rank
        }
        return try save(note, touch: false)
    }

    public func archive(id: String) throws -> Note { try setState(id: id, to: .archived) }
    public func restore(id: String) throws -> Note { try setState(id: id, to: .active) }

    public func delete(id: String) throws {
        if let record = try index.record(id: id) {
            try FileIO.remove(folder.appendingPathComponent(record.filename))
            remember(record.filename, hash: "")
        }
        try index.delete(id: id)
    }

    /// Moves `id` so it sits between the two given neighbours. Rewrites exactly
    /// one file — the whole reason `rank` is a fractional index.
    @discardableResult
    public func move(id: String, after: String?, before: String?) throws -> Note {
        let lower = try after.flatMap { try index.record(id: $0)?.rank }
        let upper = try before.flatMap { try index.record(id: $0)?.rank }
        var note = try load(id: id)
        note.rank = try Rank.between(lower, upper)
        return try save(note, touch: false)
    }

    public func setGeometry(id: String, width: Double?, height: Double?) throws {
        try index.setGeometry(id: id, width: width, height: height)
    }

    /// Moves the note files from one folder to another, leaving the index
    /// behind — it is derived, and rebuilds itself from whatever it finds.
    ///
    /// Static because it is a move *between* stores, not an operation on one.
    @discardableResult
    public static func relocateNotes(from source: URL, to destination: URL) throws -> Int {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var moved = 0
        var taken = Set(try FileIO.noteFilenames(in: destination).map { $0.lowercased() })
        for name in try FileIO.noteFilenames(in: source) {
            var target = name
            var n = 2
            while taken.contains(target.lowercased()) {
                let base = (name as NSString).deletingPathExtension
                target = "\(base) \(n).md"
                n += 1
            }
            taken.insert(target.lowercased())
            try FileIO.move(from: source.appendingPathComponent(name),
                            to: destination.appendingPathComponent(target))
            moved += 1
        }
        return moved
    }

    // MARK: - import

    /// Brings notes in from a `.ledge` archive.
    ///
    /// An id that is already here arrives as a copy with a fresh id rather than
    /// overwriting: importing your own archive twice should never silently
    /// clobber the newer note.
    @discardableResult
    public func importNotes(_ incoming: [Note]) throws -> Int {
        var imported = 0
        for var note in incoming {
            if try index.record(id: note.id) != nil {
                note.id = ULID.generate()
                note.title = note.title.isEmpty ? Note.untitled : note.title + " copy"
            }
            note.rank = (try? Rank.between(try index.maxRank(forState: note.state), nil)) ?? note.rank
            _ = try save(note, touch: false)
            imported += 1
        }
        return imported
    }

    /// Loads full notes for export. The index has metadata; the files have text.
    public func notes(ids: [String]) throws -> [Note] {
        try ids.compactMap { try? load(id: $0) }
    }

    public func allNotes(_ filter: NoteIndex.Filter = .all) throws -> [Note] {
        try index.all(filter).compactMap { try? load(id: $0.id) }
    }

    /// Brings home any note assigned to a strip that no longer exists.
    ///
    /// Removing a strip must never take its notes with it. Without this a note
    /// sits in the folder, searchable and intact, and simply never appears on
    /// any edge again — which looks exactly like losing it.
    @discardableResult
    public func reassignOrphans(knownStrips: Set<String>) throws -> Int {
        var rescued = 0
        for record in try index.all(.all) where !record.strip.isEmpty {
            guard !knownStrips.contains(record.strip) else { continue }
            _ = try move(id: record.id, toStrip: "")
            rescued += 1
        }
        return rescued
    }

    // MARK: - reconciliation

    @discardableResult
    public func scan() throws -> Int {
        let names = try FileIO.noteFilenames(in: folder)
        let known = try index.fingerprints()
        var seen = Set<String>()
        var touched = 0

        for name in names {
            seen.insert(name)
            let url = folder.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1

            if let fingerprint = known[name], fingerprint.mtime == mtime, fingerprint.size == size {
                continue
            }
            try adopt(name, at: url)
            touched += 1
        }

        for (name, _) in known where !seen.contains(name) {
            if let record = try index.record(filename: name) { try index.delete(id: record.id) }
            touched += 1
        }
        return touched
    }

    /// Re-reads the named files. Events for our own writes are dropped.
    @discardableResult
    public func reconcile(filenames: [String]) throws -> Int {
        var touched = 0
        for name in Set(filenames) {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if let record = try index.record(filename: name) {
                    try index.delete(id: record.id)
                    touched += 1
                }
                continue
            }
            let loaded = try FileIO.read(url)
            if isEcho(name, hash: loaded.stamp.hash) { continue }
            try adopt(name, at: url, preloaded: loaded)
            touched += 1
        }
        return touched
    }

    /// Reads a file into the index, giving a file with no frontmatter an
    /// identity rather than refusing it.
    private func adopt(_ name: String, at url: URL, preloaded: FileIO.Loaded? = nil) throws {
        let loaded = try preloaded ?? FileIO.read(url)
        let known = try index.record(filename: name)
        let parsed = Frontmatter.parseDetailed(loaded.text,
                                               fallbackTitle: titleFromFilename(name),
                                               fallbackID: known?.id)
        var note = parsed.note

        // Only a file that never declared a rank gets one assigned. Testing the
        // value instead would reshuffle any note that legitimately sits at a0.
        if !parsed.declares("rank") {
            note.rank = (try? Rank.between(try index.maxRank(.active), nil)) ?? note.rank
        }

        try index.upsert(
            NoteRecord(note: note, filename: name, mtime: loaded.stamp.mtime,
                       size: loaded.stamp.size, hash: loaded.stamp.hash),
            body: note.searchableBody
        )
    }

    /// Throws away the index and rebuilds it from the folder. Safe at any time:
    /// nothing here is a source of truth.
    @discardableResult
    public func rebuildIndex() throws -> Int {
        try index.removeAll()
        return try scan()
    }

    // MARK: - echo suppression

    private func remember(_ filename: String, hash: String) {
        let now = Date()
        echoes = echoes.filter { now.timeIntervalSince($0.value.at) < Self.echoWindow }
        echoes[filename] = (hash, now)
    }

    private func isEcho(_ filename: String, hash: String) -> Bool {
        guard let echo = echoes[filename] else { return false }
        guard Date().timeIntervalSince(echo.at) < Self.echoWindow else {
            echoes[filename] = nil
            return false
        }
        return echo.hash == hash
    }

    // MARK: - naming

    private func filename(for note: Note, existing: NoteRecord?) throws -> String {
        let desired = Filename.base(for: note.displayTitle)
        if let existing, Filename.base(for: existing.displayTitle) == desired {
            return existing.filename
        }
        var taken = Set(try FileIO.noteFilenames(in: folder).map { $0.lowercased() })
        if let existing { taken.remove(existing.filename.lowercased()) }
        return Filename.unique(for: note.displayTitle, taken: taken)
    }

    private func titleFromFilename(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}
