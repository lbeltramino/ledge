import Foundation
import LedgeCore
import LedgeIndex
import LedgeStore

@MainActor
enum StoreTests {
    static func run() async {

        Runner.suite("Store — files are the truth")

        await Runner.test("creating a note puts a real markdown file on disk") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let note = try await store.create(title: "Office", body: "- understand all the apis listed")

            c.expect(box.exists("Office.md"), "no file was written; got \(box.filenames())")
            let text = try box.read("Office.md")
            c.expect(text.hasPrefix("---\n"), "file has no frontmatter")
            c.expect(text.contains("id: \(note.id)"), "file does not carry its id")
            c.expect(text.contains("- understand all the apis listed"), "body missing")
        }

        await Runner.test("retitling renames the file and keeps the same note") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            var note = try await store.create(title: "Office")
            let originalID = note.id

            note.title = "Office hours"
            _ = try await store.save(note)

            c.expect(!box.exists("Office.md"), "the old filename is still there")
            c.expect(box.exists("Office hours.md"), "the new filename was not written")
            c.equal(try await store.records().count, 1, "renaming produced a second note")
            c.equal(try await store.records().first?.id, originalID, "the note lost its identity")
        }

        await Runner.test("two notes with the same title get distinct files") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            _ = try await store.create(title: "Office")
            _ = try await store.create(title: "Office")
            c.equal(box.filenames(), ["Office 2.md", "Office.md"])
            c.equal(try await store.records().count, 2)
        }

        await Runner.test("archiving keeps the file, the colour and the dates") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let note = try await store.create(title: "supercmd", color: .lavender,
                                              body: "work on the custom extension")
            let created = note.created

            let archived = try await store.archive(id: note.id)
            c.equal(archived.state, .archived)
            c.equal(archived.color, .lavender, "archiving changed the colour")
            c.equal(archived.created.timeIntervalSince1970.rounded(),
                    created.timeIntervalSince1970.rounded(), "archiving moved the creation date")
            c.expect(box.exists("supercmd.md"), "archiving deleted the file")
            c.equal(try await store.deck().count, 0, "an archived note is still in the deck")
            c.equal(try await store.count(.archived), 1)
        }

        await Runner.test("an archived note is still one query away") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let note = try await store.create(title: "supercmd", body: "work on the custom extension")
            _ = try await store.archive(id: note.id)
            c.equal(try await store.search("extension").count, 1, "the archive promise is broken")
        }

        await Runner.test("restoring puts the note back at the end of the deck") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let first = try await store.create(title: "One")
            _ = try await store.create(title: "Two")
            _ = try await store.archive(id: first.id)
            _ = try await store.restore(id: first.id)
            c.equal(try await store.deck().map(\.title), ["Two", "One"])
        }

        await Runner.test("deleting removes the file and the index row") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let note = try await store.create(title: "Office", body: "tickets")
            try await store.delete(id: note.id)
            c.expect(!box.exists("Office.md"), "file survived the delete")
            c.equal(try await store.records().count, 0)
            c.equal(try await store.search("tickets").count, 0)
        }

        await Runner.test("saving an unchanged note does not rewrite the file") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let note = try await store.create(title: "Office", body: "tickets")
            let onDisk = try box.read("Office.md")

            let reloaded = try await store.load(id: note.id)
            c.equal(reloaded.id, note.id, "a reload minted a new identity")
            c.equal(reloaded.body, note.body, "body drifted through a round-trip")
            c.equal(reloaded.created, note.created, "creation date drifted through a round-trip")

            _ = try await store.save(reloaded, touch: false)
            c.equal(try box.read("Office.md"), onDisk, "an untouched save rewrote the file")
        }

        await Runner.test("a file with no frontmatter keeps its identity across rescans") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            try box.write("Dropped in.md", "no frontmatter at all")
            _ = try await store.scan()
            let first = try await store.records().first?.id

            try box.write("Dropped in.md", "no frontmatter, edited outside")
            _ = try await store.scan()
            let second = try await store.records().first?.id

            c.equal(second, first, "the note was reborn as a different note")
            c.equal(try await store.records().count, 1, "an external edit duplicated the note")
        }

        await Runner.test("a note whose rank is legitimately a0 survives a rebuild in place") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            for t in ["Zebra", "Apple", "Mango"] { _ = try await store.create(title: t) }
            let before = try await store.deck().map(\.title)
            _ = try await store.rebuildIndex()
            c.equal(try await store.deck().map(\.title), before, "a rebuild reshuffled the deck")
        }

        Runner.suite("Store — reordering")

        await Runner.test("moving one note rewrites exactly one file") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            var notes: [Note] = []
            for t in ["One", "Two", "Three", "Four"] { notes.append(try await store.create(title: t)) }

            try await Task.sleep(for: .milliseconds(1100))   // filesystem mtime granularity
            let before = Dictionary(uniqueKeysWithValues: box.filenames().map { ($0, box.modified($0)) })

            // drag "Four" to the front
            _ = try await store.move(id: notes[3].id, after: nil, before: notes[0].id)

            let touched = box.filenames().filter { box.modified($0) != before[$0] ?? nil }
            c.equal(touched, ["Four.md"], "a reorder touched \(touched.count) files")
            c.equal(try await store.deck().map(\.title), ["Four", "One", "Two", "Three"])
        }

        Runner.suite("Store — reconciling with the outside world")

        await Runner.test("a note edited in another app is picked up") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let note = try await store.create(title: "Office", body: "old text")

            var raw = try box.read("Office.md")
            raw = raw.replacingOccurrences(of: "old text", with: "brand new text")
            try box.write("Office.md", raw)

            c.equal(try await store.reconcile(filenames: ["Office.md"]), 1, "the external edit was ignored")
            c.equal(try await store.load(id: note.id).body.trimmingCharacters(in: .whitespacesAndNewlines),
                    "brand new text")
            c.equal(try await store.search("brand").count, 1, "search did not see the external edit")
        }

        await Runner.test("our own save does not come back through the watcher") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            var note = try await store.create(title: "Office", body: "text")
            note.body = "edited by us"
            _ = try await store.save(note)

            // FSEvents will fire for the write we just made; it must be dropped.
            c.equal(try await store.reconcile(filenames: ["Office.md"]), 0,
                    "the store reprocessed its own write")
        }

        await Runner.test("a markdown file dropped into the folder becomes a note") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            _ = try await store.create(title: "Existing")
            try box.write("Dropped in.md", "no frontmatter at all\njust text")

            c.equal(try await store.scan(), 1, "the dropped file was not adopted")
            let titles = try await store.records().map(\.title)
            let adopted = try await store.records().first { $0.title == "Dropped in" }
            c.expect(adopted != nil, "adopted note has the wrong title; folder holds \(titles)")
            c.expect(ULID.isValid(adopted?.id ?? ""), "adopted note got no valid id")
            c.equal(try await store.search("frontmatter").count, 1, "adopted note is not searchable")

            // and it gains frontmatter the first time we save it
            if let adopted {
                _ = try await store.save(try await store.load(id: adopted.id))
                c.expect(try box.read("Dropped in.md").hasPrefix("---\n"), "no frontmatter after save")
            }
        }

        await Runner.test("a file deleted outside the app leaves the index") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            _ = try await store.create(title: "Office", body: "tickets")
            try FileManager.default.removeItem(at: box.url.appendingPathComponent("Office.md"))

            _ = try await store.scan()
            c.equal(try await store.records().count, 0, "the index kept a note whose file is gone")
            c.equal(try await store.search("tickets").count, 0)
        }

        await Runner.test("an unchanged folder costs nothing to rescan") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            for t in ["One", "Two", "Three"] { _ = try await store.create(title: t) }
            c.equal(try await store.scan(), 0, "a no-op scan reparsed files")
        }

        Runner.suite("Moving the notes folder")

        await Runner.test("relocating takes the notes and leaves the index behind") { c in
            let source = Sandbox()
            let store = try NoteStore(folder: source.url)
            _ = try await store.create(title: "Office", color: .coral, body: "- tickets")
            let archived = try await store.create(title: "supercmd", body: "extension")
            _ = try await store.archive(id: archived.id)

            let destination = Sandbox()
            c.equal(try NoteStore.relocateNotes(from: source.url, to: destination.url), 2)
            c.equal(source.filenames().filter { $0.hasSuffix(".md") }.count, 0,
                    "the old folder still holds notes")

            let moved = try NoteStore(folder: destination.url)
            _ = try await moved.scan()
            c.equal(try await moved.records().count, 2, "the notes did not arrive")
            c.equal(try await moved.deck().first?.color, .coral, "colour was lost in the move")
            c.equal(try await moved.count(.archived), 1, "archived state was lost in the move")
            c.equal(try await moved.search("tickets").count, 1, "search did not survive the move")
        }

        await Runner.test("moving into a folder that already has notes keeps both") { c in
            let source = Sandbox()
            let store = try NoteStore(folder: source.url)
            _ = try await store.create(title: "Office", body: "mine")

            let destination = Sandbox()
            let other = try NoteStore(folder: destination.url)
            _ = try await other.create(title: "Office", body: "theirs")

            c.equal(try NoteStore.relocateNotes(from: source.url, to: destination.url), 1)
            let both = try NoteStore(folder: destination.url)
            _ = try await both.scan()
            c.equal(try await both.records().count, 2,
                    "a name clash on the way in cost a note")
            let bodies = try await both.allNotes().map(\.body).sorted()
            c.equal(bodies, ["mine", "theirs"], "the wrong note survived the clash")
        }

        Runner.suite("Strips")

        await Runner.test("a note remembers its strip in the file, not the index") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let note = try await store.create(title: "Office", body: "x", strip: "left-1")

            c.expect(try box.read("Office.md").contains("strip: left-1"),
                     "the strip did not reach the file")
            _ = try await store.rebuildIndex()
            c.equal(try await store.records().first?.strip, "left-1",
                    "the strip was lost when the index was rebuilt")
        }

        await Runner.test("an unassigned note belongs to the primary strip") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            _ = try await store.create(title: "Unassigned", body: "x")
            _ = try await store.create(title: "Sidebar", body: "x", strip: "left-1")

            let primary = try await store.deck(strip: "", collectingUnassigned: true)
            c.equal(primary.map(\.title), ["Unassigned"],
                    "the primary strip should collect notes with no strip of their own")
            let other = try await store.deck(strip: "left-1", collectingUnassigned: false)
            c.equal(other.map(\.title), ["Sidebar"])
        }

        await Runner.test("moving a note between strips keeps everything else") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let note = try await store.create(title: "Office", color: .coral, body: "- tickets")
            let created = note.created

            _ = try await store.move(id: note.id, toStrip: "left-1")

            let moved = try await store.load(id: note.id)
            c.equal(moved.strip, "left-1")
            c.equal(moved.id, note.id, "the note lost its identity in the move")
            c.equal(moved.color, .coral, "colour was lost in the move")
            c.equal(moved.body, "- tickets", "body was lost in the move")
            c.equal(moved.created, created, "creation date was lost in the move")
            c.equal(try await store.deck(strip: "", collectingUnassigned: true).count, 0,
                    "the note is still on the strip it left")
        }

        await Runner.test("removing a strip does not take its notes with it") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            _ = try await store.create(title: "Home", body: "x")
            let stranded = try await store.create(title: "Sidebar", body: "x", strip: "left-1")

            // the user removes the "left-1" strip; only "" remains
            c.equal(try await store.reassignOrphans(knownStrips: [""]), 1)

            c.equal(try await store.load(id: stranded.id).strip, "",
                    "the stranded note did not come home")
            c.equal(try await store.deck(strip: "", collectingUnassigned: true).count, 2,
                    "a note on a removed strip vanished from every deck")
        }

        await Runner.test("notes on strips that still exist are left alone") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            _ = try await store.create(title: "Sidebar", body: "x", strip: "left-1")
            c.equal(try await store.reassignOrphans(knownStrips: ["", "left-1"]), 0)
            c.equal(try await store.records().first?.strip, "left-1")
        }

        await Runner.test("a strip assignment survives an export and import") { c in
            let source = Sandbox()
            let store = try NoteStore(folder: source.url)
            _ = try await store.create(title: "Sidebar", body: "x", strip: "left-1")
            let data = try await Exporter.archive(store.allNotes())

            let destination = Sandbox()
            let second = try NoteStore(folder: destination.url)
            _ = try await second.importNotes(Exporter.read(archive: data))
            c.equal(try await second.records().first?.strip, "left-1",
                    "the strip did not survive the archive")
        }

        Runner.suite("Export — the three lossy formats")

        await Runner.test("markdown export drops the frontmatter and promotes the title") { c in
            var note = Note(title: "Office", color: .blue, tags: ["work"])
            note.body = "- understand all the apis listed"
            let file = Exporter.markdown(note)
            let text = String(decoding: file.contents, as: UTF8.self)
            c.equal(file.name, "Office.md")
            c.expect(!text.contains("---"), "frontmatter leaked into a markdown export")
            c.expect(!text.contains(note.id), "the id leaked into a markdown export")
            c.expect(text.hasPrefix("# Office\n"), "title was not promoted to an H1")
            c.expect(text.contains("- understand all the apis listed"), "body missing")
        }

        await Runner.test("plain text export is title, blank line, body") { c in
            var note = Note(title: "Groceries")
            note.body = "- apple\n- 4x banana"
            let file = Exporter.plainText(note)
            c.equal(file.name, "Groceries.txt")
            c.equal(String(decoding: file.contents, as: UTF8.self), "Groceries\n\n- apple\n- 4x banana\n")
        }

        await Runner.test("single file separates notes with a rule") { c in
            var a = Note(title: "One"); a.body = "first"
            var b = Note(title: "Two"); b.body = "second"
            let text = String(decoding: Exporter.singleFile([a, b]).contents, as: UTF8.self)
            c.expect(text.contains("## One"), "missing a heading")
            c.expect(text.contains("## Two"), "missing a heading")
            c.expect(text.contains("\n---\n"), "notes are not separated")
        }

        await Runner.test("two notes with the same title get distinct export filenames") { c in
            let notes = [Note(title: "Office"), Note(title: "Office")]
            let names = Exporter.files(for: .markdown, notes: notes).map(\.name)
            c.equal(names, ["Office.md", "Office 2.md"])
        }

        Runner.suite("Export — the lossless one")

        await Runner.test("a .ledge archive round-trips colour, state, tags and dates") { c in
            var a = Note(title: "Office", color: .lavender, state: .archived, tags: ["work", "api"])
            a.body = "- tickets"
            var b = Note(title: "Groceries", color: .green)
            b.body = "- apple"

            let data = Exporter.archive([a, b])
            let back = try Exporter.read(archive: data)

            c.equal(back.count, 2)
            let office = back.first { $0.title == "Office" }
            c.equal(office?.id, a.id, "the note lost its identity")
            c.equal(office?.color, .lavender, "colour was lost")
            c.equal(office?.state, .archived, "state was lost")
            c.equal(office?.tags, ["work", "api"], "tags were lost")
            c.equal(office?.created, a.created, "creation date was lost")
            c.equal(office?.body, "- tickets", "body was lost")
        }

        await Runner.test("the archive is a real zip a person can open") { c in
            let data = Exporter.archive([Note(title: "Office")])
            c.expect(data.starts(with: [0x50, 0x4b, 0x03, 0x04]), "not a PK zip")
            let entries = try Zip.entries(of: data)
            c.expect(entries.contains { $0.name == Exporter.manifestName }, "no manifest")
            c.expect(entries.contains { $0.name.hasPrefix("notes/") && $0.name.hasSuffix(".md") },
                     "notes are not in the archive: \(entries.map(\.name))")
        }

        await Runner.test("zip entries survive their own checksum") { c in
            let payload = Data("the quick brown fox".utf8)
            let data = Zip.archive([Zip.Entry(name: "a.txt", data: payload),
                                    Zip.Entry(name: "b/c.md", data: Data())])
            let back = try Zip.entries(of: data)
            c.equal(back.count, 2)
            c.equal(back.first?.data, payload)
            c.equal(back.last?.name, "b/c.md")
            // The canonical CRC-32 check value, from the standard itself.
            c.equal(Zip.crc32(Data("123456789".utf8)), 0xCBF43926, "CRC32 fails the standard check vector")
            c.equal(Zip.crc32(payload), 0x91C102CA, "CRC32 disagrees with zlib")
        }

        await Runner.test("something that is not an archive is refused, not crashed on") { c in
            c.throwsError { _ = try Exporter.read(archive: Data("hello".utf8)) }
            c.throwsError { _ = try Exporter.read(archive: Data()) }
        }

        await Runner.test("importing an archive twice copies rather than clobbers") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let original = try await store.create(title: "Office", color: .blue, body: "the real one")

            let data = try await Exporter.archive(store.allNotes())
            c.equal(try await store.importNotes(Exporter.read(archive: data)), 1)

            c.equal(try await store.records().count, 2, "the import did not produce a second note")
            let survivor = try await store.load(id: original.id)
            c.equal(survivor.body, "the real one", "the existing note was overwritten by its own copy")
            let copy = try await store.records().first { $0.id != original.id }
            c.expect(copy?.title.contains("copy") == true, "the copy is not marked as one")
        }

        await Runner.test("a note exported and imported into an empty folder is unchanged") { c in
            let source = Sandbox()
            let store = try NoteStore(folder: source.url)
            _ = try await store.create(title: "Office", color: .coral, body: "- tickets for PRD")
            let archived = try await store.create(title: "supercmd", color: .green, body: "extension")
            _ = try await store.archive(id: archived.id)
            let data = try await Exporter.archive(store.allNotes())

            let destination = Sandbox()
            let second = try NoteStore(folder: destination.url)
            c.equal(try await second.importNotes(Exporter.read(archive: data)), 2)
            c.equal(try await second.count(.archived), 1, "archived state did not survive the trip")
            c.equal(try await second.deck().first?.color, .coral, "colour did not survive the trip")
            c.equal(try await second.search("PRD").count, 1, "imported notes are not searchable")
        }

        Runner.suite("Store — the index is disposable")

        await Runner.test("throwing the index away and rebuilding loses nothing that matters") { c in
            let box = Sandbox()
            let store = try NoteStore(folder: box.url)
            let a = try await store.create(title: "Office", color: .blue, body: "tickets for PRD")
            _ = try await store.create(title: "Groceries", color: .green, body: "apple banana")
            let archived = try await store.create(title: "supercmd", color: .coral, body: "custom extension")
            _ = try await store.archive(id: archived.id)

            let before = try await store.records().map { [$0.id, $0.title, $0.color.rawValue, $0.state.rawValue, $0.rank] }

            _ = try await store.rebuildIndex()

            let after = try await store.records().map { [$0.id, $0.title, $0.color.rawValue, $0.state.rawValue, $0.rank] }
            c.equal(after, before, "a rebuild changed the notes")
            c.equal(try await store.search("PRD").first?.record.id, a.id, "search broke after a rebuild")
            c.equal(try await store.count(.archived), 1, "archived state was lost in the rebuild")
        }

        await Runner.test("deleting the index file on disk is survivable") { c in
            let box = Sandbox()
            do {
                let store = try NoteStore(folder: box.url)
                _ = try await store.create(title: "Office", body: "tickets for PRD")
                _ = try await store.create(title: "Groceries", body: "apple banana")
            }
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: box.url.appendingPathComponent(NoteIndex.filename + suffix))
            }

            let reopened = try NoteStore(folder: box.url)
            _ = try await reopened.scan()
            c.equal(try await reopened.records().count, 2, "notes did not come back from the folder")
            c.equal(try await reopened.search("PRD").count, 1, "search did not come back")
        }
    }
}
