import Foundation
import LedgeCore
import LedgeIndex
import SQLite3

@MainActor
enum IndexTests {

    static func record(_ title: String, body: String = "", color: NoteColor = .blue,
                       state: NoteState = .active, rank: String = "a0",
                       tags: [String] = []) -> (NoteRecord, String) {
        var note = Note(title: title, color: color, state: state, rank: rank, tags: tags)
        note.body = body
        let r = NoteRecord(note: note, filename: "\(title).md", mtime: 1, size: body.count, hash: "h")
        return (r, note.searchableBody)
    }

    static func run() async {

        Runner.suite("Index — writing and reading")

        await Runner.test("a note written to the index reads back intact") { c in
            let idx = try NoteIndex.ephemeral()
            let (r, body) = record("Office", body: "understand all the apis", tags: ["work"])
            try idx.upsert(r, body: body)
            let back = try idx.record(id: r.id)
            c.expect(back != nil, "note vanished")
            c.equal(back?.title, "Office")
            c.equal(back?.tags, ["work"])
            c.equal(back?.color, .blue)
        }

        await Runner.test("upsert updates rather than duplicating") { c in
            let idx = try NoteIndex.ephemeral()
            var (r, body) = record("Office")
            try idx.upsert(r, body: body)
            r.title = "Office renamed"; r.filename = "Office renamed.md"
            try idx.upsert(r, body: body)
            c.equal(try idx.count(), 1, "upsert created a second row")
            c.equal(try idx.record(id: r.id)?.title, "Office renamed")
        }

        await Runner.test("the deck comes back in rank order, actives only") { c in
            let idx = try NoteIndex.ephemeral()
            let ranks = try Rank.sequence(after: nil, count: 4)
            for (i, rank) in ranks.enumerated().reversed() {
                let (r, b) = record("Note \(i)", state: i == 2 ? .archived : .active, rank: rank)
                try idx.upsert(r, body: b)
            }
            let deck = try idx.deck()
            c.equal(deck.map(\.title), ["Note 0", "Note 1", "Note 3"])
            c.equal(try idx.count(.archived), 1)
        }

        await Runner.test("window size survives a metadata update but not a rebuild") { c in
            let idx = try NoteIndex.ephemeral()
            var (r, body) = record("Office")
            try idx.upsert(r, body: body)
            try idx.setGeometry(id: r.id, width: 400, height: 500)
            r.title = "Office again"
            try idx.upsert(r, body: body)          // no geometry supplied
            c.equal(try idx.record(id: r.id)?.width, 400, "a plain save dropped the window size")
            try idx.removeAll()
            try idx.upsert(r, body: body)
            c.equal(try idx.record(id: r.id)?.width, nil, "geometry should not survive a rebuild")
        }

        Runner.suite("Index — search")

        await Runner.test("finds by title, body and tag") { c in
            let idx = try NoteIndex.ephemeral()
            let (a, ab) = record("Groceries", body: "apple banana peanuts", tags: ["home"])
            let (b, bb) = record("Office", body: "create tickets for PRD creation", tags: ["work"])
            try idx.upsert([(a, ab), (b, bb)])
            c.equal(try idx.search("groceries").map(\.record.title), ["Groceries"])
            c.equal(try idx.search("peanuts").map(\.record.title), ["Groceries"])
            c.equal(try idx.search("work").map(\.record.title), ["Office"])
        }

        await Runner.test("matches as you type, on a prefix") { c in
            let idx = try NoteIndex.ephemeral()
            let (a, ab) = record("Groceries", body: "apple banana")
            try idx.upsert(a, body: ab)
            for typed in ["g", "gr", "gro", "groc"] {
                c.equal(try idx.search(typed).count, 1, "no hit after typing \"\(typed)\"")
            }
        }

        await Runner.test("a title match outranks a body match") { c in
            let idx = try NoteIndex.ephemeral()
            let (a, ab) = record("Notes about nothing", body: "the word office appears here")
            let (b, bb) = record("Office", body: "unrelated content entirely")
            try idx.upsert([(a, ab), (b, bb)])
            c.equal(try idx.search("office").first?.record.title, "Office", "body match outranked the title")
        }

        await Runner.test("an archived note is still one query away") { c in
            let idx = try NoteIndex.ephemeral()
            let (a, ab) = record("supercmd", body: "work on the custom extension", state: .archived)
            try idx.upsert(a, body: ab)
            c.equal(try idx.search("extension").count, 1, "the archive promise is broken")
            c.equal(try idx.search("extension", filter: .active).count, 0)
            c.equal(try idx.search("extension", filter: .archived).count, 1)
        }

        await Runner.test("a deleted note leaves nothing behind in the search index") { c in
            let idx = try NoteIndex.ephemeral()
            let (a, ab) = record("Groceries", body: "apple banana peanuts")
            try idx.upsert(a, body: ab)
            try idx.delete(id: a.id)
            c.equal(try idx.count(), 0)
            c.equal(try idx.search("peanuts").count, 0, "FTS kept a ghost row")
        }

        await Runner.test("an edited note stops matching its old text") { c in
            let idx = try NoteIndex.ephemeral()
            var (a, _) = record("Groceries", body: "apple banana peanuts")
            try idx.upsert(a, body: "apple banana peanuts")
            a.snippet = "walnuts only"
            try idx.upsert(a, body: "walnuts only")
            c.equal(try idx.search("peanuts").count, 0, "FTS still matches deleted text")
            c.equal(try idx.search("walnuts").count, 1)
        }

        await Runner.test("punctuation a user types does not become an FTS syntax error") { c in
            let idx = try NoteIndex.ephemeral()
            let (a, ab) = record("Office", body: "read the docs")
            try idx.upsert(a, body: ab)
            for query in ["\"", "AND", "office*", "a NEAR b", "(", "foo:bar", "-", "^"] {
                _ = try idx.search(query)   // must not throw
            }
            c.expect(true)
        }

        Runner.suite("Index — disposability")

        await Runner.test("a foreign schema version is discarded, not migrated") { c in
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ledge-schema-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(NoteIndex.filename)

            let first = try NoteIndex(url: url)
            let (r, body) = record("Office")
            try first.upsert(r, body: body)
            c.equal(try first.count(), 1)

            // pretend a newer build wrote this file
            var raw: OpaquePointer?
            sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READWRITE, nil)
            sqlite3_exec(raw, "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', '999')", nil, nil, nil)
            sqlite3_close_v2(raw)

            let second = try NoteIndex(url: url)
            c.equal(try second.count(), 0, "a mismatched index should be thrown away, not reused")
        }

        await Runner.test("a corrupt index file is replaced rather than fatal") { c in
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ledge-corrupt-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(NoteIndex.filename)
            try Data("this is not a database".utf8).write(to: url)

            let idx = try NoteIndex(url: url)
            let (r, body) = record("Office")
            try idx.upsert(r, body: body)
            c.equal(try idx.count(), 1, "could not recover from a corrupt index")
        }
    }
}
