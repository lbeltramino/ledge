import Foundation
import LedgeCore

/// The derived index. Markdown files are the truth; this is a cache that may be
/// deleted at any moment and rebuilt from the folder.
///
/// Therefore: **no migrations, ever.** A schema mismatch deletes the file and
/// rebuilds. A derived cache that needs migration logic has stopped being one.
public final class NoteIndex {
    public static let schemaVersion = 3
    public static let filename = ".index.sqlite3"

    private var db: Connection
    private let path: String

    public enum Filter: Sendable, Equatable {
        case all, active, archived

        var clause: String {
            switch self {
            case .all:      return ""
            case .active:   return "WHERE state = 'active'"
            case .archived: return "WHERE state = 'archived'"
            }
        }
        var matches: NoteState? {
            switch self {
            case .all: return nil
            case .active: return .active
            case .archived: return .archived
            }
        }
    }

    /// Opens the index at `url`, discarding and recreating it if it is missing,
    /// unreadable, or written by a different schema version.
    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    public init(path: String) throws {
        self.path = path
        do {
            db = try Connection(path: path)
            try NoteIndex.createSchema(db)
            let version = try NoteIndex.readVersion(db)
            if version != NoteIndex.schemaVersion {
                db = try NoteIndex.recreate(at: path)
            }
        } catch {
            db = try NoteIndex.recreate(at: path)
        }
    }

    /// A private in-memory index, for tests. Note the literal path: routing this
    /// through `URL(fileURLWithPath:)` would resolve it against the working
    /// directory and quietly give every caller the same file.
    public static func ephemeral() throws -> NoteIndex {
        try NoteIndex(path: ":memory:")
    }

    private static func recreate(at path: String) throws -> Connection {
        if path != ":memory:" {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let fresh = try Connection(path: path)
        try createSchema(fresh)
        try fresh.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)",
                      [.text(String(schemaVersion))])
        return fresh
    }

    private static func readVersion(_ db: Connection) throws -> Int {
        let rows = try db.query("SELECT value FROM meta WHERE key = 'schema_version'", []) { $0.text(0) }
        return rows.first.flatMap(Int.init) ?? -1
    }

    private static func createSchema(_ db: Connection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS notes (
          rowid    INTEGER PRIMARY KEY,
          id       TEXT NOT NULL UNIQUE,
          filename TEXT NOT NULL,
          title    TEXT NOT NULL,
          color    TEXT NOT NULL,
          state    TEXT NOT NULL,
          rank     TEXT NOT NULL,
          tags     TEXT NOT NULL,
          strip    TEXT NOT NULL DEFAULT '',
          feed     TEXT NOT NULL DEFAULT '',
          snippet  TEXT NOT NULL,
          created  TEXT NOT NULL,
          updated  TEXT NOT NULL,
          mtime    REAL NOT NULL,
          size     INTEGER NOT NULL,
          hash     TEXT NOT NULL,
          width    REAL,
          height   REAL
        );
        CREATE INDEX IF NOT EXISTS notes_state_rank ON notes(state, rank);
        CREATE INDEX IF NOT EXISTS notes_strip      ON notes(strip, rank);
        CREATE INDEX IF NOT EXISTS notes_filename   ON notes(filename);
        CREATE INDEX IF NOT EXISTS notes_feed       ON notes(feed);

        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
          title, body, tags,
          tokenize = 'porter unicode61',
          prefix = '2 3'
        );

        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }

    // MARK: - writing

    public func upsert(_ record: NoteRecord, body: String) throws {
        try db.transaction {
            try writeRow(record, body: body)
        }
    }

    public func upsert(_ pairs: [(record: NoteRecord, body: String)]) throws {
        try db.transaction {
            for p in pairs { try writeRow(p.record, body: p.body) }
        }
    }

    private func writeRow(_ r: NoteRecord, body: String) throws {
        let tagsJSON = (try? String(data: JSONEncoder().encode(r.tags), encoding: .utf8)) ?? "[]"
        try db.run("""
        INSERT INTO notes (id, filename, title, color, state, rank, tags, strip, feed, snippet,
                           created, updated, mtime, size, hash, width, height)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          filename = excluded.filename, title = excluded.title, color = excluded.color,
          state = excluded.state, rank = excluded.rank, tags = excluded.tags,
          strip = excluded.strip, feed = excluded.feed, snippet = excluded.snippet, created = excluded.created, updated = excluded.updated,
          mtime = excluded.mtime, size = excluded.size, hash = excluded.hash,
          width = COALESCE(excluded.width, notes.width),
          height = COALESCE(excluded.height, notes.height)
        """, [
            .text(r.id), .text(r.filename), .text(r.title), .text(r.color.rawValue),
            .text(r.state.rawValue), .text(r.rank), .text(tagsJSON ?? "[]"),
            .text(r.strip), .text(r.feed), .text(r.snippet),
            .text(Frontmatter.string(from: r.created)), .text(Frontmatter.string(from: r.updated)),
            .double(r.mtime), .int(Int64(r.size)), .text(r.hash),
            .double(r.width), .double(r.height)
        ])

        guard let rowid = try rowid(for: r.id) else { return }
        try db.run("DELETE FROM notes_fts WHERE rowid = ?", [.int(rowid)])
        try db.run("INSERT INTO notes_fts(rowid, title, body, tags) VALUES (?,?,?,?)", [
            .int(rowid), .text(r.displayTitle), .text(body), .text(r.tags.joined(separator: " "))
        ])
    }

    public func delete(id: String) throws {
        try db.transaction {
            if let rowid = try rowid(for: id) {
                try db.run("DELETE FROM notes_fts WHERE rowid = ?", [.int(rowid)])
            }
            try db.run("DELETE FROM notes WHERE id = ?", [.text(id)])
        }
    }

    public func setGeometry(id: String, width: Double?, height: Double?) throws {
        try db.run("UPDATE notes SET width = ?, height = ? WHERE id = ?",
                   [.double(width), .double(height), .text(id)])
    }

    public func removeAll() throws {
        try db.transaction {
            try db.run("DELETE FROM notes_fts")
            try db.run("DELETE FROM notes")
        }
    }

    private func rowid(for id: String) throws -> Int64? {
        try db.query("SELECT rowid FROM notes WHERE id = ?", [.text(id)]) { Int64($0.int(0)) }.first
    }

    // MARK: - reading

    public func all(_ filter: Filter = .all) throws -> [NoteRecord] {
        try db.query("SELECT \(NoteIndex.columns) FROM notes \(filter.clause) ORDER BY rank ASC", [], NoteIndex.decode)
    }

    public func deck() throws -> [NoteRecord] { try all(.active) }

    /// The active notes on one strip.
    ///
    /// The primary strip is where anything unclaimed ends up: notes with no
    /// strip, and notes naming a strip that does not exist. That second case is
    /// not hypothetical — anything writing a note from outside the app can put
    /// any word in that field, and a note nobody shows is a note you have lost.
    /// It used to take a restart, and `reassignOrphans` rewriting the file, for
    /// one of those to appear.
    public func deck(strip: String, collectingUnassigned: Bool,
                     knownStrips: Set<String>) throws -> [NoteRecord] {
        guard collectingUnassigned else {
            return try db.query(
                "SELECT \(NoteIndex.columns) FROM notes WHERE state = 'active' AND strip = ? ORDER BY rank ASC",
                [.text(strip)], NoteIndex.decode)
        }

        var clause = "WHERE state = 'active' AND (strip = ? OR strip = ''"
        var arguments: [SQLValue] = [.text(strip)]
        if knownStrips.isEmpty {
            // No strips configured at all: every note belongs here.
            clause += " OR strip != ''"
        } else {
            clause += " OR strip NOT IN (\(knownStrips.map { _ in "?" }.joined(separator: ",")))"
            arguments += knownStrips.map { .text($0) }
        }
        clause += ")"

        return try db.query("SELECT \(NoteIndex.columns) FROM notes \(clause) ORDER BY rank ASC",
                            arguments, NoteIndex.decode)
    }

    /// Every note something is writing to, newest change first — what a feed
    /// reader wants and what `ledge list --feed` answers with.
    public func all(feed: String) throws -> [NoteRecord] {
        let clause = feed.isEmpty ? "WHERE feed != ''" : "WHERE feed = ?"
        let arguments: [SQLValue] = feed.isEmpty ? [] : [.text(feed)]
        return try db.query("SELECT \(NoteIndex.columns) FROM notes \(clause) ORDER BY updated DESC",
                            arguments, NoteIndex.decode)
    }

    public func record(id: String) throws -> NoteRecord? {
        try db.query("SELECT \(NoteIndex.columns) FROM notes WHERE id = ?", [.text(id)], NoteIndex.decode).first
    }

    public func record(filename: String) throws -> NoteRecord? {
        try db.query("SELECT \(NoteIndex.columns) FROM notes WHERE filename = ?", [.text(filename)], NoteIndex.decode).first
    }

    public func count(_ filter: Filter = .all) throws -> Int {
        try db.query("SELECT COUNT(*) FROM notes \(filter.clause)", []) { $0.int(0) }.first ?? 0
    }

    /// `(mtime, size, hash)` per filename — the whole reconciliation sweep in
    /// one query, so a launch scan parses only files that actually changed.
    public func fingerprints() throws -> [String: (mtime: Double, size: Int, hash: String)] {
        let rows = try db.query("SELECT filename, mtime, size, hash FROM notes", []) {
            ($0.text(0), $0.double(1), $0.int(2), $0.text(3))
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, (mtime: $0.1, size: $0.2, hash: $0.3)) })
    }

    public func maxRank(forState state: LedgeCore.NoteState) throws -> String? {
        try maxRank(state == .active ? Filter.active : Filter.archived)
    }

    public func maxRank(_ filter: Filter = .active) throws -> String? {
        try db.query("SELECT rank FROM notes \(filter.clause) ORDER BY rank DESC LIMIT 1", []) { $0.text(0) }.first
    }

    // MARK: - search

    public func search(_ text: String, filter: Filter = .all, limit: Int = 200) throws -> [SearchHit] {
        guard let match = NoteIndex.ftsQuery(text) else {
            return try all(filter).map { SearchHit(record: $0, excerpt: $0.snippet) }
        }
        let stateClause: String
        switch filter {
        case .all:      stateClause = ""
        case .active:   stateClause = "AND n.state = 'active'"
        case .archived: stateClause = "AND n.state = 'archived'"
        }
        let sql = """
        SELECT \(NoteIndex.columns.replacingOccurrences(of: "notes.", with: "n."))
             , snippet(notes_fts, 1, '\(SearchHit.openMark)', '\(SearchHit.closeMark)', '…', 14)
        FROM notes_fts f
        JOIN notes n ON n.rowid = f.rowid
        WHERE notes_fts MATCH ? \(stateClause)
        ORDER BY bm25(notes_fts, 3.0, 1.0, 2.0) ASC
        LIMIT \(limit)
        """
        return try db.query(sql, [.text(match)]) { row in
            var excerpt = row.text(16)
            if excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                excerpt = row.text(8)
            }
            return SearchHit(record: NoteIndex.decode(row), excerpt: excerpt)
        }
    }

    /// Turns free typing into a safe FTS5 expression: every token quoted, the
    /// last one a prefix match so results narrow as you type.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.enumerated().map { i, t in
            let quoted = "\"\(t)\""
            return i == tokens.count - 1 ? quoted + "*" : quoted
        }.joined(separator: " ")
    }

    // MARK: - decoding

    static let columns = """
    notes.id, notes.filename, notes.title, notes.color, notes.state, notes.rank, notes.tags, \
    notes.strip, notes.feed, notes.snippet, notes.created, notes.updated, notes.mtime, notes.size, \
    notes.hash, notes.width, notes.height
    """

    static func decode(_ row: Row) -> NoteRecord {
        let tags = (try? JSONDecoder().decode([String].self, from: Data(row.text(6).utf8))) ?? []
        return NoteRecord(
            id: row.text(0),
            filename: row.text(1),
            title: row.text(2),
            color: NoteColor(rawValue: row.text(3)) ?? .default,
            state: NoteState(rawValue: row.text(4)) ?? .active,
            rank: row.text(5),
            tags: tags,
            strip: row.text(7),
            feed: row.text(8),
            snippet: row.text(9),
            created: Frontmatter.date(from: row.text(10)) ?? Date(),
            updated: Frontmatter.date(from: row.text(11)) ?? Date(),
            mtime: row.double(12),
            size: row.int(13),
            hash: row.text(14),
            width: row.optionalDouble(15),
            height: row.optionalDouble(16)
        )
    }
}
