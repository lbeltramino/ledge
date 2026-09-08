import Foundation
import LedgeCore

@MainActor
enum CoreTests {
    static func run() async {

        Runner.suite("Rank — fractional indexing")

        await Runner.test("an empty deck starts at a0") { c in
            c.equal(try Rank.between(nil, nil), "a0")
        }

        await Runner.test("appending a thousand notes stays ordered and stays short") { c in
            var ranks: [String] = []
            var cursor: String? = nil
            for _ in 0..<1000 {
                let next = try Rank.between(cursor, nil)
                ranks.append(next); cursor = next
            }
            c.expect(ranks == ranks.sorted(), "append order broke")
            c.equal(Set(ranks).count, ranks.count, "duplicate ranks")
            // The whole reason ranks carry an integer part: appends must not grow.
            c.expect(ranks.map(\.count).max()! <= 5, "ranks grew to \(ranks.map(\.count).max()!) chars")
        }

        await Runner.test("prepending a couple hundred stays ordered") { c in
            var ranks: [String] = []
            var cursor: String? = nil
            for _ in 0..<200 {
                let next = try Rank.between(nil, cursor)
                ranks.insert(next, at: 0); cursor = next
            }
            c.expect(ranks == ranks.sorted(), "prepend order broke")
        }

        await Runner.test("a value can always be minted between two neighbours") { c in
            var lo = try Rank.between(nil, nil)
            var hi = try Rank.between(lo, nil)
            for i in 0..<300 {
                let mid = try Rank.between(lo, hi)
                c.expect(lo < mid && mid < hi, "step \(i): \(lo) < \(mid) < \(hi) violated")
                if i % 2 == 0 { lo = mid } else { hi = mid }
            }
        }

        await Runner.test("dragging one note into every slot keeps the deck ordered") { c in
            var deck = try Rank.sequence(after: nil, count: 12)
            for target in 0..<11 {
                _ = deck.removeLast()
                let before: String? = target > 0 ? deck[target - 1] : nil
                let after: String?  = target < deck.count ? deck[target] : nil
                deck.insert(try Rank.between(before, after), at: target)
                c.expect(deck == deck.sorted(), "out of order after moving to \(target)")
            }
        }

        await Runner.test("out-of-order arguments are rejected, not silently accepted") { c in
            c.throwsError { _ = try Rank.between("a1", "a0") }
            c.throwsError { _ = try Rank.between("a0", "a0") }
        }

        Runner.suite("Frontmatter")

        let sample = """
        ---
        id: 01K2F3QW8N4Z7YB0PMRTXAGH5J
        title: Office
        color: blue
        state: active
        rank: a0V
        tags: [work, api]
        created: 2026-08-29T21:06:12Z
        updated: 2026-08-29T21:31:44Z
        ---
        - understand all the apis listed
        - create tickets for PRD creation
        """

        await Runner.test("parses every known key") { c in
            let n = Frontmatter.parse(sample, fallbackTitle: "ignored")
            c.equal(n.id, "01K2F3QW8N4Z7YB0PMRTXAGH5J")
            c.equal(n.title, "Office")
            c.equal(n.color, .blue)
            c.equal(n.state, .active)
            c.equal(n.rank, "a0V")
            c.equal(n.tags, ["work", "api"])
            c.equal(n.body, "- understand all the apis listed\n- create tickets for PRD creation")
        }

        await Runner.test("round-trips without drift") { c in
            let first = Frontmatter.parse(sample, fallbackTitle: "x")
            let second = Frontmatter.parse(Frontmatter.serialize(first), fallbackTitle: "x")
            c.expect(first == second, "note changed through a round-trip")
            c.equal(Frontmatter.serialize(first), Frontmatter.serialize(second))
        }

        await Runner.test("keys written by another tool survive a rewrite") { c in
            let text = """
            ---
            id: 01K2F3QW8N4Z7YB0PMRTXAGH5J
            title: Office
            obsidian-cssclass: wide
            aliases: [work-notes]
            ---
            body
            """
            let out = Frontmatter.serialize(Frontmatter.parse(text, fallbackTitle: "x"))
            c.expect(out.contains("obsidian-cssclass: wide"), "dropped a foreign key")
            c.expect(out.contains("aliases: [work-notes]"), "dropped a foreign key")
        }

        await Runner.test("a plain markdown file with no frontmatter is adopted, not refused") { c in
            let n = Frontmatter.parse("just some text\nand more", fallbackTitle: "Dropped in")
            c.equal(n.title, "Dropped in")
            c.equal(n.body, "just some text\nand more")
            c.expect(ULID.isValid(n.id), "adopted note got no valid id")
            c.equal(n.state, .active)
        }

        await Runner.test("awkward titles survive serialisation") { c in
            for title in ["Q3: the reckoning", #"He said "no""#, "- leading dash", "  padded  ", "", "#hash [brackets]"] {
                var n = Note(title: title); n.body = "x"
                let parsed = Frontmatter.parse(Frontmatter.serialize(n), fallbackTitle: "fallback")
                c.equal(parsed.title, title, "lost title")
            }
        }

        await Runner.test("an unterminated fence is treated as body, not swallowed") { c in
            let n = Frontmatter.parse("---\ntitle: Broken\nno closing fence", fallbackTitle: "File")
            c.equal(n.title, "File")
            c.expect(n.body.contains("no closing fence"), "lost the body")
        }

        await Runner.test("an unknown colour or state falls back instead of failing") { c in
            let n = Frontmatter.parse("---\ncolor: chartreuse\nstate: pending\n---\nx", fallbackTitle: "f")
            c.equal(n.color, .default)
            c.equal(n.state, .active)
        }

        Runner.suite("Tags")

        await Runner.test("a hashtag in the body is a tag, a heading is not") { c in
            c.equal(Tags.found(in: "call the #plumber about #kitchen-sink"), ["plumber", "kitchen-sink"])
            c.equal(Tags.found(in: "# Heading\n## Another"), [])
            c.equal(Tags.found(in: "#work and # not a tag"), ["work"])
        }

        await Runner.test("things that look like tags but are not") { c in
            c.equal(Tags.found(in: "written in C# today"), [], "C# is not a tag")
            c.equal(Tags.found(in: "issue foo#42"), [], "a suffix is not a tag")
            c.equal(Tags.found(in: "#1234"), [], "a tag starts with a letter")
            c.equal(Tags.found(in: "##double"), [], "two hashes is not a tag")
        }

        await Runner.test("tags are lowercased and de-duplicated, in the order written") { c in
            c.equal(Tags.found(in: "#Work then #home then #work again"), ["work", "home"])
        }

        await Runner.test("adding a tag to the body adds it; removing it removes it") { c in
            c.equal(Tags.merged(existing: [], oldBody: "nothing", newBody: "now #work"), ["work"])
            c.equal(Tags.merged(existing: ["work"], oldBody: "now #work", newBody: "now nothing"), [])
        }

        await Runner.test("a tag written by hand in the frontmatter is never taken away") { c in
            // Ledge did not put it there, so it does not get to remove it.
            c.equal(Tags.merged(existing: ["archive"], oldBody: "plain", newBody: "still plain"),
                    ["archive"])
            c.equal(Tags.merged(existing: ["archive"], oldBody: "plain", newBody: "and #work"),
                    ["archive", "work"])
        }

        await Runner.test("editing around a tag leaves it alone") { c in
            c.equal(Tags.merged(existing: ["work"],
                                oldBody: "- call #work",
                                newBody: "- call #work\n- and again"),
                    ["work"])
        }

        Runner.suite("Filenames")

        await Runner.test("strips characters the filesystem will not take") { c in
            c.equal(Filename.base(for: "Q3/Q4: plan"), "Q3 Q4 plan")
            c.equal(Filename.base(for: "a\\b*c?d"), "a b c d")
        }

        await Runner.test("an empty title becomes Untitled note") { c in
            c.equal(Filename.base(for: ""), Note.untitled)
            c.equal(Filename.base(for: "   "), Note.untitled)
        }

        await Runner.test("collisions get numbered, case-insensitively") { c in
            var taken: Set<String> = ["office.md"]
            c.equal(Filename.unique(for: "Office", taken: taken), "Office 2.md")
            taken.insert("office 2.md")
            c.equal(Filename.unique(for: "Office", taken: taken), "Office 3.md")
        }

        Runner.suite("Jitter — the notes are not square to the edge")

        await Runner.test("the same note always leans the same way") { c in
            c.expect(Jitter(id: "01K2F3QW8N4Z7YB0PMRTXAGH5J") == Jitter(id: "01K2F3QW8N4Z7YB0PMRTXAGH5J"),
                     "a note changed its lean between reads")
        }

        await Runner.test("different notes lean differently") { c in
            let rotations = Set((0..<200).map { _ in Jitter(id: ULID.generate()).cardRotation })
            c.expect(rotations.count > 190, "only \(rotations.count)/200 distinct rotations")
        }

        await Runner.test("stays inside the range the deck can absorb") { c in
            for _ in 0..<500 {
                let j = Jitter(id: ULID.generate())
                c.expect(abs(j.cardRotation) <= 1.4, "card rotation \(j.cardRotation)")
                c.expect(abs(j.tabRotation) <= 0.6, "tab rotation \(j.tabRotation)")
                c.expect(j.tabOverlap >= 2 && j.tabOverlap <= 5, "overlap \(j.tabOverlap)")
                c.expect(j.tabProtrusion >= 0 && j.tabProtrusion <= 2.5, "protrusion \(j.tabProtrusion)")
                c.expect(j.shadowScale >= 0.85 && j.shadowScale <= 1.15, "shadow \(j.shadowScale)")
            }
        }

        await Runner.test("nothing lands perfectly square") { c in
            for _ in 0..<500 {
                let j = Jitter(id: ULID.generate())
                c.expect(abs(j.cardRotation) > 0.4, "a card sat almost dead level: \(j.cardRotation)")
                c.expect(abs(j.tabRotation) > 0.2, "a tab sat almost dead level: \(j.tabRotation)")
            }
        }

        await Runner.test("leans are balanced left and right, not biased one way") { c in
            let rotations = (0..<4000).map { _ in Jitter(id: ULID.generate()).cardRotation }
            let left = rotations.filter { $0 < 0 }.count
            let ratio = Double(left) / Double(rotations.count)
            c.expect(ratio > 0.45 && ratio < 0.55,
                     String(format: "%.1f%% of notes lean left — the deck would visibly list", ratio * 100))
        }

        await Runner.test("leans fill their range instead of clustering at the minimum") { c in
            let magnitudes = (0..<4000).map { _ in abs(Jitter(id: ULID.generate()).cardRotation) }
            let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
            // range is 0.49…1.4; a uniform spread means a mean near 0.945
            c.expect(mean > 0.85 && mean < 1.05,
                     String(format: "mean lean is %.3f° — leans are bunching, not spreading", mean))
            let bigLeans = magnitudes.filter { $0 > 1.1 }.count
            c.expect(bigLeans > magnitudes.count / 5,
                     "only \(bigLeans)/4000 notes lean more than 1.1° — the jitter is too timid")
        }

        await Runner.test("a card straightens under the caret") { c in
            let j = Jitter(id: ULID.generate())
            c.equal(j.cardRotation(focused: true), 0)
            c.equal(j.cardRotation(focused: false), j.cardRotation)
        }

        Runner.suite("Checkboxes")

        await Runner.test("a task line is recognised, an ordinary bullet is not") { c in
            let text = "- [ ] milk\n- [x] bread\n- butter"
            let items = Checkbox.items(in: text)
            c.equal(items.count, 2, "found \(items.count) tasks")
            c.equal(items.first?.isDone, false)
            c.equal(items.last?.isDone, true)
        }

        await Runner.test("clicking a box flips exactly one character") { c in
            let text = "- [ ] milk\n- [x] bread"
            guard let flip = Checkbox.toggle(in: text, at: 8) else {
                c.expect(false, "clicking the first line found no task"); return
            }
            c.equal(flip.range.length, 1, "more than one character would be replaced")
            c.equal(flip.replacement, "x")
            let after = (text as NSString).replacingCharacters(in: flip.range, with: flip.replacement)
            c.equal(after, "- [x] milk\n- [x] bread")

            guard let back = Checkbox.toggle(in: after, at: 8) else {
                c.expect(false, "cannot untick"); return
            }
            c.equal((after as NSString).replacingCharacters(in: back.range, with: back.replacement),
                    text, "unticking did not restore the line")
        }

        await Runner.test("clicking a line with no task does nothing") { c in
            c.expect(Checkbox.toggle(in: "- just a bullet", at: 4) == nil, "a plain bullet was toggled")
            c.expect(Checkbox.toggle(in: "plain text", at: 4) == nil, "plain text was toggled")
        }

        await Runner.test("Enter continues a checklist, and an empty item ends it") { c in
            c.equal(Checkbox.continuation(after: "- [ ] milk"), "- [ ] ")
            c.equal(Checkbox.continuation(after: "  * [x] bread"), "  * [ ] ")
            c.equal(Checkbox.continuation(after: "- [ ] "), "", "an empty task should end the list")
            c.expect(Checkbox.continuation(after: "- plain") == nil, "a plain bullet is not a task")
        }

        await Runner.test("a note knows how much of it is done") { c in
            c.equal(Checkbox.progress(in: "- [x] a\n- [ ] b\n- [x] c")?.done, 2)
            c.equal(Checkbox.progress(in: "- [x] a\n- [ ] b\n- [x] c")?.total, 3)
            c.expect(Checkbox.progress(in: "no tasks here") == nil)
        }

        Runner.suite("Editing keys")

        await Runner.test("Tab indents the list item it is on") { c in
            let text = "- one\n- two"
            let lines = NSRange(location: 6, length: 5)   // the second line
            c.equal(MarkdownText.shiftIndent(text, lines: lines, by: 1), "- one\n  - two")
        }

        await Runner.test("Shift-Tab takes a level back, and stops at the margin") { c in
            c.equal(MarkdownText.shiftIndent("    - deep", lines: NSRange(location: 0, length: 10), by: -1),
                    "  - deep")
            c.equal(MarkdownText.shiftIndent("- flat", lines: NSRange(location: 0, length: 6), by: -1),
                    "- flat", "outdenting past the margin should do nothing")
        }

        await Runner.test("a range past the end is refused, not fatal") { c in
            c.expect(MarkdownText.shiftIndent("- a", lines: NSRange(location: 0, length: 999), by: 1) != nil,
                     "a too-long range should be clamped")
            c.expect(MarkdownText.shiftIndent("", lines: NSRange(location: 5, length: 5), by: 1) == nil,
                     "an empty string has no list to indent")
        }

        await Runner.test("Tab on something that is not a list says so") { c in
            c.expect(MarkdownText.shiftIndent("plain text", lines: NSRange(location: 0, length: 10), by: 1) == nil,
                     "Tab should fall through to inserting a tab")
        }

        await Runner.test("Tab indents a whole selection, tasks and all") { c in
            let text = "- [ ] a\n- [x] b"
            c.equal(MarkdownText.shiftIndent(text, lines: NSRange(location: 0, length: 15), by: 1),
                    "  - [ ] a\n  - [x] b")
        }

        await Runner.test("numbered lists renumber themselves") { c in
            c.equal(MarkdownText.renumber("1. a\n1. b\n1. c"), "1. a\n2. b\n3. c",
                    "typing 1. three times should still count")
            c.equal(MarkdownText.renumber("1. a\n5. b"), "1. a\n2. b", "a wrong number is corrected")
        }

        await Runner.test("a nested numbered list starts again at one") { c in
            c.equal(MarkdownText.renumber("1. a\n2. b\n  1. inner\n  1. inner\n3. c"),
                    "1. a\n2. b\n  1. inner\n  2. inner\n3. c")
        }

        await Runner.test("indenting the third item makes it the first of its level") { c in
            let text = "1. a\n2. b\n3. c"
            c.equal(MarkdownText.shiftIndent(text, lines: NSRange(location: 10, length: 4), by: 1),
                    "1. a\n2. b\n  1. c", "a nested item carrying on from three reads as a mistake")
        }

        await Runner.test("bullets are left alone by renumbering") { c in
            c.equal(MarkdownText.renumber("- a\n- b"), "- a\n- b")
        }

        await Runner.test("backspace at the start of an item outdents before it deletes") { c in
            let text = "  - nested"
            guard let edit = MarkdownText.outdentOrUnmark(text, at: 4) else {
                c.expect(false, "backspace did nothing on an indented item"); return
            }
            c.equal((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement),
                    "- nested")
        }

        await Runner.test("…and then takes the marker off") { c in
            let text = "- flat"
            guard let edit = MarkdownText.outdentOrUnmark(text, at: 2) else {
                c.expect(false, "backspace did nothing on a flat item"); return
            }
            c.equal((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement),
                    "flat")
        }

        await Runner.test("backspace anywhere else is ordinary backspace") { c in
            c.expect(MarkdownText.outdentOrUnmark("- flat", at: 4) == nil,
                     "mid-word backspace was intercepted")
            c.expect(MarkdownText.outdentOrUnmark("plain", at: 0) == nil,
                     "backspace on a plain line was intercepted")
        }

        await Runner.test("quotes are list-shaped too") { c in
            c.equal(MarkdownText.marker(of: "> quoted")?.kind, .quote)
            c.equal(MarkdownText.shiftIndent("> quoted", lines: NSRange(location: 0, length: 8), by: 1),
                    "  > quoted")
        }

        Runner.suite("Links between notes")

        await Runner.test("a wikilink is found, with its name") { c in
            let text = "see [[Office]] and [[Side-projects]]"
            c.equal(Wikilink.names(in: text), ["Office", "Side-projects"])
            c.equal(Wikilink.link(in: text, at: 6)?.name, "Office")
            c.expect(Wikilink.link(in: text, at: 2) == nil, "found a link where there is none")
        }

        await Runner.test("brackets that are not links are left alone") { c in
            c.equal(Wikilink.names(in: "a [markdown](link) and [one bracket]"), [])
            c.equal(Wikilink.names(in: "[[]]"), [])
            c.equal(Wikilink.names(in: "[[ padded ]]"), ["padded"], "names are trimmed")
        }

        Runner.suite("The ledge:// scheme")

        await Runner.test("a new note can be fully described in a link") { c in
            let url = URL(string: "ledge://new?title=Groceries&text=milk&color=green&strip=left-1")!
            c.equal(LedgeURL.parse(url),
                    .new(title: "Groceries", text: "milk", color: .green, strip: "left-1"))
        }

        await Runner.test("the parts are all optional") { c in
            c.equal(LedgeURL.parse(URL(string: "ledge://new")!),
                    .new(title: nil, text: nil, color: nil, strip: nil))
            c.equal(LedgeURL.parse(URL(string: "ledge://new?text=just%20this")!),
                    .new(title: nil, text: "just this", color: nil, strip: nil))
        }

        await Runner.test("opening and searching") { c in
            c.equal(LedgeURL.parse(URL(string: "ledge://open?title=Office")!), .open(reference: "Office"))
            c.equal(LedgeURL.parse(URL(string: "ledge://search?q=plumber")!), .search("plumber"))
            c.equal(LedgeURL.parse(URL(string: "ledge:///search?query=plumber")!), .search("plumber"),
                    "a third slash is how plenty of tools write these")
        }

        await Runner.test("anything malformed is nil rather than a surprise") { c in
            c.expect(LedgeURL.parse(URL(string: "https://example.com/new")!) == nil, "wrong scheme")
            c.expect(LedgeURL.parse(URL(string: "ledge://delete?all=1")!) == nil, "unknown action")
            c.expect(LedgeURL.parse(URL(string: "ledge://open")!) == nil, "open with nothing to open")
            c.expect(LedgeURL.parse(URL(string: "ledge://search?q=")!) == nil, "an empty query")
            c.equal(LedgeURL.parse(URL(string: "ledge://new?color=chartreuse")!),
                    .new(title: nil, text: nil, color: nil, strip: nil),
                    "an unknown colour is ignored, not fatal")
        }

        await Runner.test("a link back to a note round-trips") { c in
            let url = LedgeURL.link(toTitle: "Hold my lid")
            c.expect(url != nil)
            c.equal(url.flatMap(LedgeURL.parse), .open(reference: "Hold my lid"))
        }

        Runner.suite("Version comparison")

        await Runner.test("a newer release is recognised, an older one is not") { c in
            c.expect(UpdateCheckVersions.isNewer("0.2.0", than: "0.1.0"), "0.2.0 > 0.1.0")
            c.expect(UpdateCheckVersions.isNewer("0.10.0", than: "0.9.0"),
                     "0.10.0 > 0.9.0 — string comparison gets this wrong")
            c.expect(UpdateCheckVersions.isNewer("1.0.0", than: "0.99.99"), "1.0.0 > 0.99.99")
            c.expect(!UpdateCheckVersions.isNewer("0.1.0", than: "0.1.0"), "equal is not newer")
            c.expect(!UpdateCheckVersions.isNewer("0.1.0", than: "0.2.0"), "older is not newer")
            c.expect(UpdateCheckVersions.isNewer("0.1.1", than: "0.1"), "0.1.1 > 0.1")
            c.expect(!UpdateCheckVersions.isNewer("0.1", than: "0.1.0"), "0.1 == 0.1.0")
        }

        Runner.suite("ULID")

        await Runner.test("sorts by creation time") { c in
            let early = ULID.generate(date: Date(timeIntervalSince1970: 1_000_000))
            let late  = ULID.generate(date: Date(timeIntervalSince1970: 2_000_000))
            c.expect(early < late, "\(early) should sort before \(late)")
        }

        await Runner.test("is 26 valid characters and effectively unique") { c in
            let ids = (0..<10_000).map { _ in ULID.generate() }
            c.expect(ids.allSatisfy { ULID.isValid($0) }, "an id failed validation")
            c.equal(Set(ids).count, ids.count, "collision in 10k ids")
        }
    }
}
