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
                c.expect(j.tabProtrusion >= 0 && j.tabProtrusion <= Jitter.maxProtrusion,
                         "protrusion \(j.tabProtrusion)")
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

        await Runner.test("a line can be moved up and down") { c in
            let text = "one\ntwo\nthree"
            let down = MarkdownText.moveLines(text, lines: NSRange(location: 0, length: 3), by: 1)
            c.equal(down?.text, "two\none\nthree")
            c.equal(down?.selection, NSRange(location: 4, length: 3),
                    "the moved line stays selected so you can keep pressing")

            let up = MarkdownText.moveLines(text, lines: NSRange(location: 8, length: 5), by: -1)
            c.equal(up?.text, "one\nthree\ntwo")
        }

        await Runner.test("moving past either end does nothing") { c in
            c.expect(MarkdownText.moveLines("a\nb", lines: NSRange(location: 0, length: 1), by: -1) == nil,
                     "the first line cannot go up")
            c.expect(MarkdownText.moveLines("a\nb", lines: NSRange(location: 2, length: 1), by: 1) == nil,
                     "the last line cannot go down")
            c.expect(MarkdownText.moveLines("only", lines: NSRange(location: 0, length: 4), by: 1) == nil,
                     "a single line has nowhere to go")
        }

        await Runner.test("moving a numbered item renumbers the list") { c in
            let text = "1. a\n2. b\n3. c"
            let moved = MarkdownText.moveLines(text, lines: NSRange(location: 0, length: 4), by: 1)
            c.equal(moved?.text, "1. b\n2. a\n3. c",
                    "the numbers should describe the new order, not follow the lines")
        }

        await Runner.test("a line can be duplicated") { c in
            let copied = MarkdownText.duplicateLines("uno\ndos", lines: NSRange(location: 0, length: 3))
            c.equal(copied?.text, "uno\nuno\ndos")
            c.equal(copied?.selection, NSRange(location: 4, length: 3),
                    "the copy is what stays selected, so pressing again stacks them")
        }

        await Runner.test("duplicating the last line still leaves two") { c in
            let copied = MarkdownText.duplicateLines("solo", lines: NSRange(location: 0, length: 4))
            c.equal(copied?.text, "solo\nsolo")
        }

        await Runner.test("duplicating a numbered item renumbers") { c in
            let copied = MarkdownText.duplicateLines("1. a\n2. b", lines: NSRange(location: 0, length: 4))
            c.equal(copied?.text, "1. a\n2. a\n3. b",
                    "the copy takes the next number: \(copied?.text.debugDescription ?? "nil")")
        }

        await Runner.test("a pasted URL is recognised, other text is not") { c in
            c.expect(MarkdownText.isLink("https://example.com"), "https")
            c.expect(MarkdownText.isLink("http://example.com/a?b=c"), "with a query")
            c.expect(MarkdownText.isLink("mailto:someone@example.com"), "mailto")
            c.expect(!MarkdownText.isLink("just some words"), "prose is not a link")
            c.expect(!MarkdownText.isLink("example.com"), "no scheme, no link")
            c.expect(!MarkdownText.isLink("https://example.com and more"), "a sentence is not a link")
            c.expect(!MarkdownText.isLink(""), "nothing is not a link")
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

        Runner.suite("What an agent may edit")

        await Runner.test("appending keeps entries apart") { c in
            c.equal(FeedEdit.appending("segundo", to: "primero"), "primero\n\nsegundo")
            c.equal(FeedEdit.appending("solo", to: ""), "solo")
            c.equal(FeedEdit.appending("  ", to: "intacto"), "intacto", "nothing to add, nothing changes")
            c.equal(FeedEdit.appending("b", to: "a\n\n\n"), "a\n\nb", "no growing pile of blank lines")
        }

        await Runner.test("a new task joins the list instead of starting another") { c in
            let body = "Plan\n\n- [ ] uno\n- [x] dos\n\nNotas al final"
            let after = FeedEdit.addingTask("tres", to: body)
            c.equal(after, "Plan\n\n- [ ] uno\n- [x] dos\n- [ ] tres\n\nNotas al final",
                    "got: \(after.debugDescription)")
            c.equal(Checkbox.items(in: after).count, 3)
        }

        await Runner.test("a new task keeps the indent of the list it joins") { c in
            let after = FeedEdit.addingTask("b", to: "  - [ ] a")
            c.equal(after, "  - [ ] a\n  - [ ] b")
        }

        await Runner.test("with no list, a task starts one at the end") { c in
            c.equal(FeedEdit.addingTask("uno", to: "Contexto"), "Contexto\n\n- [ ] uno")
            c.equal(FeedEdit.addingTask("uno", to: ""), "- [ ] uno")
        }

        await Runner.test("ticking finds the task by its words") { c in
            let body = "- [ ] correr migraciones\n- [ ] desplegar a staging"
            let hit = FeedEdit.setting(.done, matching: "migraciones", in: body)
            c.expect(hit?.changed == true, "should have ticked it")
            c.equal(hit?.body, "- [x] correr migraciones\n- [ ] desplegar a staging")
            c.equal(hit?.item, "correr migraciones", "and report what it ticked")
        }

        await Runner.test("ticking matches through case and accents") { c in
            let body = "- [ ] Correr Migración"
            c.expect(FeedEdit.setting(.done, matching: "migracion", in: body)?.changed == true,
                     "an agent quoting the task back should not miss on an accent")
        }

        await Runner.test("ticking twice is not work") { c in
            let body = "- [x] listo"
            let again = FeedEdit.setting(.done, matching: "listo", in: body)
            c.expect(again != nil, "the item is still found")
            c.expect(again?.changed == false, "…but nothing changed, and it should say so")
            c.equal(again?.body, body)
        }

        await Runner.test("a task that is not there is not invented") { c in
            c.expect(FeedEdit.setting(.done, matching: "no existe", in: "- [ ] algo") == nil)
            c.expect(FeedEdit.setting(.done, matching: "", in: "- [ ] algo") == nil,
                     "an empty needle must not tick the first thing it sees")
        }

        await Runner.test("unticking is the same door") { c in
            let hit = FeedEdit.setting(.todo, matching: "listo", in: "- [x] listo")
            c.equal(hit?.body, "- [ ] listo")
        }

        await Runner.test("a feed is written to the file, not beside it") { c in
            var note = Note(title: "Deploy", body: "x")
            note.feed = "claude-code"
            let text = Frontmatter.serialize(note)
            c.expect(text.contains("feed: claude-code"), "not in the frontmatter: \(text)")
            let back = Frontmatter.parse(text, fallbackTitle: "", fallbackID: note.id)
            c.equal(back.feed, "claude-code", "and it survives the round trip")

            let plain = Frontmatter.parse(Frontmatter.serialize(Note(title: "x")), fallbackTitle: "", fallbackID: ULID.generate())
            c.equal(plain.feed, "", "a note nobody writes to says nothing at all")
            c.expect(!Frontmatter.serialize(Note(title: "x")).contains("feed:"),
                     "an empty feed does not clutter every file in the folder")
        }

        Runner.suite("The ledge command")

        // Runs the binary itself rather than the functions under it: the
        // argument parsing, the folder resolution and the exit codes are the
        // parts an agent actually meets, and none of them are exercised by
        // calling FeedStore directly.
        let cli = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("ledge")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        @discardableResult
        func run(_ arguments: [String]) -> (out: String, code: Int32) {
            guard let cli, FileManager.default.isExecutableFile(atPath: cli.path) else {
                return ("", -1)
            }
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = ["LEDGE_FOLDER": folder.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    process.terminationStatus)
        }

        await Runner.test("the command writes a note a person could have written") { c in
            guard run(["folder"]).code == 0 else {
                c.expect(false, "the ledge binary was not built beside the tests")
                return
            }
            let id = run(["new", "Deploy 2.1", "--feed", "claude-code", "--strip", "work"])
            c.expect(ULID.isValid(id.out), "new should print an id, printed \(id.out.debugDescription)")

            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            c.equal(files.filter { $0.hasSuffix(".md") }.count, 1, "one note, one file")

            let text = (try? String(contentsOf: folder.appendingPathComponent(files[0]), encoding: .utf8)) ?? ""
            c.expect(text.contains("feed: claude-code"), "the feed is in the frontmatter")
            c.expect(text.contains("strip: work"), "and so is the strip it was asked for")
        }

        await Runner.test("tasks go on and come off the same list") { c in
            run(["task", "add", "Deploy", "correr", "migraciones"])
            run(["task", "add", "Deploy", "desplegar", "a", "staging"])
            let done = run(["task", "check", "Deploy", "migraciones"])
            c.equal(done.out, "done: correr migraciones")
            c.equal(done.code, 0)

            let again = run(["task", "check", "Deploy", "migraciones"])
            c.equal(again.out, "already done: correr migraciones",
                    "repeating itself is not an error — an agent will do it")
            c.equal(again.code, 0, "…and must not look like a failure")

            let missing = run(["task", "check", "Deploy", "algo que no está"])
            c.equal(missing.code, 1, "a task that is not there is a failure")
            c.expect(missing.out.contains("no task"), "and says so: \(missing.out)")
        }

        await Runner.test("progress is visible without opening anything") { c in
            let listed = run(["list"])
            c.expect(listed.out.contains("[1/2]"), "list should show progress: \(listed.out)")
            c.expect(listed.out.contains("← claude-code"), "and who is writing: \(listed.out)")
        }

        await Runner.test("an ambiguous name is refused rather than guessed") { c in
            run(["new", "Deploy staging"])
            let ambiguous = run(["append", "Deploy", "algo"])
            c.equal(ambiguous.code, 1, "two notes start with Deploy — picking one would be a coin toss")
            let exact = run(["append", "Deploy staging", "algo"])
            c.equal(exact.code, 0, "an exact title still works, even when it is a prefix of nothing else")
        }

        await Runner.test("text can arrive as arguments or on stdin") { c in
            let id = run(["new", "Desde stdin"]).out
            let process = Process()
            process.executableURL = cli
            process.arguments = ["append", id]
            process.environment = ["LEDGE_FOLDER": folder.path]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = Pipe()
            try? process.run()
            input.fileHandleForWriting.write(Data("línea uno\nlínea dos".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()

            let body = run(["get", id]).out
            c.expect(body.contains("línea uno\nlínea dos"),
                     "a multi-line block should survive stdin: \(body.debugDescription)")
        }

        await Runner.test("it refuses to invent a note") { c in
            let missing = run(["append", "no existe esta nota", "algo"])
            c.equal(missing.code, 1)
            c.expect(missing.out.contains("no note matches"), "said: \(missing.out)")
        }

        Runner.suite("Two writers at once")

        await Runner.test("the case that started this: an agent appends while you type") { c in
            let base = "- [ ] uno\n- [ ] dos"
            // You are editing the first line…
            let mine = "- [ ] uno con detalle\n- [ ] dos"
            // …while the agent adds three tasks at the end.
            let theirs = "- [ ] uno\n- [ ] dos\n- [ ] tres\n- [ ] cuatro\n- [ ] cinco"

            let merged = Merge.lines(base: base, mine: mine, theirs: theirs)
            c.equal(merged.text, "- [ ] uno con detalle\n- [ ] dos\n- [ ] tres\n- [ ] cuatro\n- [ ] cinco",
                    "got: \(merged.text.debugDescription)")
            c.expect(!merged.conflicted, "these edits do not overlap")
        }

        await Runner.test("nine tasks appended in a row all arrive") { c in
            var theirs = "Plan"
            for n in 1...9 { theirs = FeedEdit.addingTask("tarea \(n)", to: theirs) }
            let merged = Merge.lines(base: "Plan", mine: "Plan\n\nmis notas", theirs: theirs)
            c.equal(Checkbox.items(in: merged.text).count, 9, "lost some: \(merged.text)")
            c.expect(merged.text.contains("mis notas"), "and it kept what I was writing")
        }

        await Runner.test("ticking a box while you write elsewhere keeps both") { c in
            let base = "- [ ] migrar\n- [ ] avisar\n\nnotas"
            let mine = "- [ ] migrar\n- [ ] avisar\n\nnotas mías"
            let theirs = "- [x] migrar\n- [ ] avisar\n\nnotas"
            let merged = Merge.lines(base: base, mine: mine, theirs: theirs)
            c.equal(merged.text, "- [x] migrar\n- [ ] avisar\n\nnotas mías")
        }

        await Runner.test("nothing is ever lost, even when both change one line") { c in
            let merged = Merge.lines(base: "una línea",
                                     mine: "una línea mía",
                                     theirs: "una línea suya")
            c.expect(merged.conflicted, "this is a real conflict and should say so")
            c.expect(merged.text.contains("mía") && merged.text.contains("suya"),
                     "both versions have to survive: \(merged.text.debugDescription)")
        }

        await Runner.test("the easy answers stay easy") { c in
            c.equal(Merge.lines(base: "a", mine: "a mío", theirs: "a").text, "a mío",
                    "no external change: mine wins outright")
            c.equal(Merge.lines(base: "a", mine: "a", theirs: "a suyo").text, "a suyo",
                    "I typed nothing: theirs is adopted")
            c.equal(Merge.lines(base: "a", mine: "b", theirs: "b").text, "b",
                    "the same edit twice is not a conflict")
            c.equal(Merge.lines(base: "", mine: "", theirs: "primera línea").text, "primera línea",
                    "an empty note taking its first content")
        }

        await Runner.test("deletions are respected, not undone") { c in
            let merged = Merge.lines(base: "uno\ndos\ntres",
                                     mine: "uno\ntres",
                                     theirs: "uno\ndos\ntres\ncuatro")
            c.equal(merged.text, "uno\ntres\ncuatro",
                    "deleting a line must not be undone by the other side's append: \(merged.text.debugDescription)")
        }

        await Runner.test("the caret stays on the word it was on") { c in
            let base = "primera\nsegunda"
            let mine = "primera\nsegunda mía"
            let theirs = "cero\nprimera\nsegunda"
            let merged = Merge.lines(base: base, mine: mine, theirs: theirs)
            c.equal(merged.text, "cero\nprimera\nsegunda mía")

            // caret just after "segunda mía" in `mine`
            let offset = (mine as NSString).length
            let moved = Merge.caret(offset, from: mine, into: merged)
            let text = merged.text as NSString
            c.equal(text.substring(to: moved), "cero\nprimera\nsegunda mía",
                    "a line arriving above must carry the caret with it, not slide it "
                    + "through the sentence: landed after \(text.substring(to: moved).debugDescription)")
        }

        await Runner.test("a long note merges without taking a noticeable pause") { c in
            let long = (1...800).map { "línea número \($0) con algo de texto para que pese" }
                .joined(separator: "\n")
            let mine = long + "\nmi párrafo"
            let theirs = long.replacingOccurrences(of: "línea número 400 ", with: "línea CUATROCIENTOS ")
            let started = Date()
            let merged = Merge.lines(base: long, mine: mine, theirs: theirs)
            let elapsed = Date().timeIntervalSince(started)
            c.expect(merged.text.contains("mi párrafo") && merged.text.contains("CUATROCIENTOS"),
                     "both edits should survive in a long note")
            c.expect(elapsed < 0.2, "800 lines took \(Int(elapsed * 1000)) ms — that runs on a save")
        }

        Runner.suite("Tasks in progress")

        await Runner.test("[/] is a task, and it is not done") { c in
            let body = "- [ ] uno\n- [/] dos\n- [x] tres"
            let items = Checkbox.items(in: body)
            c.equal(items.count, 3, "all three are tasks")
            c.equal(items.map(\.state), [.todo, .doing, .done])
            c.expect(!items[1].isDone, "in progress is not done")

            let counted = Checkbox.progress(in: body)
            c.equal(counted?.done, 1, "only [x] counts as done — the count must not flatter")
            c.equal(counted?.doing, 1)
            c.equal(counted?.total, 3)
        }

        await Runner.test("clicking finishes a task from any state") { c in
            let body = "- [/] a"
            let flip = Checkbox.toggle(in: body, at: 3)
            c.equal(flip?.replacement, "x",
                    "a click on something in progress completes it — you finished what it started")
            c.equal(Checkbox.toggle(in: "- [x] a", at: 3)?.replacement, " ")
            c.equal(Checkbox.toggle(in: "- [ ] a", at: 3)?.replacement, "x")
        }

        await Runner.test("⌥-click sets and clears in progress") { c in
            c.equal(Checkbox.set(.doing, in: "- [ ] a", at: 3)?.replacement, "/")
            c.equal(Checkbox.set(.todo, in: "- [/] a", at: 3)?.replacement, " ")
            c.expect(Checkbox.set(.doing, in: "- [/] a", at: 3) == nil,
                     "already in that state: nothing should be written")
        }

        await Runner.test("Enter after an in-progress task starts an empty one") { c in
            c.equal(Checkbox.continuation(after: "- [/] algo"), "- [ ] ",
                    "the next task is not also in progress")
        }

        await Runner.test("the command can start a task") { c in
            let body = "- [ ] correr migraciones"
            let started = FeedEdit.setting(.doing, matching: "migraciones", in: body)
            c.equal(started?.body, "- [/] correr migraciones")
            c.expect(started?.changed == true)

            let finished = FeedEdit.setting(.done, matching: "migraciones", in: started!.body)
            c.equal(finished?.body, "- [x] correr migraciones",
                    "and take it from in progress to done without passing through anything")
        }

        await Runner.test("an unknown marker never reads as done") { c in
            // A viewer that does not know [/] shows the literal text. What must
            // never happen is the opposite mistake.
            c.expect(!Checkbox.items(in: "- [/] a")[0].isDone)
            c.equal(Checkbox.items(in: "- [?] a").count, 0,
                    "a marker we do not know is not a checkbox at all, so it cannot be ticked")
        }

        Runner.suite("The headings in a note")

        await Runner.test("finds them, with their level and their words") { c in
            let note = "# Primero\n\ntexto\n\n## Segundo\n\n### Tercero"
            let found = Headings.all(in: note)
            c.equal(found.map(\.level), [1, 2, 3])
            c.equal(found.map(\.text), ["Primero", "Segundo", "Tercero"])
        }

        await Runner.test("a tag is not a heading") { c in
            c.equal(Headings.all(in: "#work y #otra cosa").count, 0,
                    "the space after the hashes is what makes a heading")
            c.equal(Headings.all(in: "# work").count, 1)
        }

        await Runner.test("comments inside a code block are not headings") { c in
            let note = """
            # De verdad

            ```bash
            # instalar
            brew install foo
            # y listo
            ```

            ## También de verdad
            """
            let found = Headings.all(in: note)
            c.equal(found.map(\.text), ["De verdad", "También de verdad"],
                    "got: \(found.map(\.text))")
        }

        await Runner.test("the line is where it is, so you can jump to it") { c in
            let note = "texto\n## Un título\nmás"
            guard let item = Headings.all(in: note).first else {
                c.expect(false, "no lo encontró"); return
            }
            c.equal((note as NSString).substring(with: item.line), "## Un título")
        }

        await Runner.test("it is only worth offering with somewhere to jump") { c in
            c.expect(!Headings.worthShowing(in: "sin títulos"), "nada que ofrecer")
            c.expect(!Headings.worthShowing(in: "# uno solo"), "un solo título no es un índice")
            c.expect(Headings.worthShowing(in: "# uno\n## dos"), "dos ya son un índice")
        }

        Runner.suite("Markdown tables")

        // Cut from the document this was built against, pipes, backticks, bold
        // and all — a table written by hand for people, not for a parser.
        let real = """
        ## 2. Mapeo

        | Concepto en la propuesta | Primitiva IDP | Notas de implementación |
        |---|---|---|
        | Servicio **Bedrock Inference** | `service_specification` tipo `dependency` | `dimensions`: `country` + `environment`. |
        | Link **Invoke** (Inference → Scope) | `link_specification` con `assignable_to: "scope"` | El único vínculo que el dev ve como tal. |

        texto después
        """

        await Runner.test("finds a real table and its cells") { c in
            let found = Tables.all(in: real)
            c.equal(found.count, 1, "una tabla")
            guard let table = found.first else { return }
            c.equal(table.header, ["Concepto en la propuesta", "Primitiva IDP", "Notas de implementación"])
            c.equal(table.rows.count, 2)
            c.equal(table.rows[0][0], "Servicio **Bedrock Inference**",
                    "the cell keeps its markup: \(table.rows[0][0])")
            c.equal(table.rows[1][0], "Link **Invoke** (Inference → Scope)")
        }

        await Runner.test("the range covers the table and nothing else") { c in
            guard let table = Tables.all(in: real).first else { c.expect(false, "no table"); return }
            let text = (real as NSString).substring(with: table.range)
            c.expect(text.hasPrefix("| Concepto"), "starts at the header: \(text.prefix(20))")
            c.expect(text.hasSuffix("como tal. |"), "ends at the last row: …\(text.suffix(20))")
            c.expect(!text.contains("texto después"), "and does not swallow what follows")
            c.expect(!text.contains("## 2."), "nor what came before")
        }

        await Runner.test("two tables in one note stay two") { c in
            let two = real + "\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
            c.equal(Tables.all(in: two).count, 2)
        }

        await Runner.test("alignment comes from the rule") { c in
            let note = "| izq | centro | der |\n|:---|:---:|---:|\n| 1 | 2 | 3 |"
            guard let table = Tables.all(in: note).first else { c.expect(false, "no table"); return }
            c.equal(table.alignment, [.left, .centre, .right])
        }

        await Runner.test("prose with pipes in it is not a table") { c in
            c.equal(Tables.all(in: "esto | aquello | lo otro\nsin regla debajo").count, 0,
                    "the rule under the header is what makes it a table")
            c.equal(Tables.all(in: "| solo un encabezado |\n|---|").count, 0,
                    "a header and a rule with no rows is not worth drawing")
            c.equal(Tables.all(in: "```\ncat a | grep b\ncat c | grep d\n```").count, 0,
                    "a shell pipeline is not a table")
        }

        await Runner.test("an escaped pipe stays inside its cell") { c in
            let note = "| comando | qué hace |\n|---|---|\n| `a \\| b` | pasa a por b |"
            guard let table = Tables.all(in: note).first else { c.expect(false, "no table"); return }
            c.equal(table.rows[0].count, 2, "two cells, not three: \(table.rows[0])")
            c.equal(table.rows[0][0], "`a | b`")
        }

        await Runner.test("a short row is padded rather than dropped") { c in
            let note = "| a | b | c |\n|---|---|---|\n| 1 |"
            guard let table = Tables.all(in: note).first else { c.expect(false, "no table"); return }
            c.equal(table.rows[0], ["1", "", ""], "a row written short still has the table's shape")
        }

        await Runner.test("the table under a point is the one you clicked") { c in
            guard let table = Tables.all(in: real).first else { c.expect(false, "no table"); return }
            c.expect(Tables.containing(table.range.location + 5, in: real) != nil, "inside")
            c.expect(Tables.containing(0, in: real) == nil, "before it there is none")
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

        Runner.suite("Pasted code")

        // A corpus rather than one example each: detection that only works on
        // the snippet it was written against is detection that will fence your
        // prose the first time you paste a paragraph.
        let snippets: [(String, String, String)] = [
            ("hcl", """
            resource "aws_s3_bucket" "logs" {
              bucket = "acme-logs"
              tags = {
                Environment = "prod"
              }
            }
            """, "aws_s3_bucket.logs"),
            ("hcl", """
            module "vpc" {
              source  = "terraform-aws-modules/vpc/aws"
              version = "5.0.0"
              cidr    = "10.0.0.0/16"
            }
            """, "module.vpc"),
            ("yaml", """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: api
            spec:
              replicas: 3
            """, "Deployment/api"),
            ("yaml", """
            # docker-compose
            services:
              web:
                image: nginx:1.25
                ports:
                  - "80:80"
            """, "services"),
            ("json", """
            {
              "name": "api-gateway",
              "version": "1.4.0",
              "scripts": { "start": "node index.js" }
            }
            """, "api-gateway"),
            ("javascript", """
            const express = require("express");
            const app = express();
            app.get("/healthz", (req, res) => res.send("ok"));
            """, "express"),
            ("typescript", """
            export interface Config {
              region: string;
              retries: number;
            }

            export function load(env: string): Config {
              return { region: env, retries: 3 };
            }
            """, "Config"),
            ("python", """
            import boto3

            def sync_buckets(source, target):
                s3 = boto3.client("s3")
                return s3.list_objects_v2(Bucket=source)
            """, "sync_buckets"),
            ("go", """
            package main

            import "fmt"

            func main() {
                fmt.Println("ok")
            }
            """, "main.main"),
            ("bash", """
            #!/usr/bin/env bash
            set -euo pipefail
            kubectl rollout status deployment/api --timeout=120s
            """, "kubectl rollout status"),
            ("bash", """
            kubectl get pods -o jsonpath='{.items[*].metadata.name}'
            helm upgrade --install api ./chart
            """, "kubectl get pods"),
            ("dockerfile", """
            FROM golang:1.22-alpine
            WORKDIR /src
            COPY . .
            RUN go build -o /bin/api ./cmd/api
            """, "Dockerfile · golang:1.22-alpine"),
            ("sql", """
            CREATE TABLE deployments (
              id uuid PRIMARY KEY,
              service text NOT NULL
            );
            """, "create deployments"),
            ("makefile", """
            build:
            \tgo build ./...

            test:
            \tgo test ./...
            """, "make build"),
            ("groovy", """
            pipeline {
              agent any
              stages {
                stage('build') {
                  steps { sh 'make build' }
                }
              }
            }
            """, "stage build"),
            ("toml", """
            [tool.poetry]
            name = "platform"
            version = "0.1.0"
            """, "tool.poetry"),
            ("xml", """
            <project>
              <groupId>com.acme</groupId>
            </project>
            """, "<project>"),
        ]

        for (language, snippet, expectedTitle) in snippets {
            await Runner.test("recognises \(language): \(expectedTitle)") { c in
                let found = Code.detect(snippet)
                c.equal(found?.language, language,
                        "detected \(found?.language ?? "nothing")")
                c.equal(found?.title, expectedTitle, "title was \(found?.title ?? "nothing")")
            }
        }

        // The other half, and the one that matters more: pasting writing must
        // not fence it. A false positive turns a note you were writing into a
        // grey box; a false negative just leaves you with ⌘E.
        let prose = [
            "Reunión con el equipo de plataforma: quedamos en migrar el cluster el martes.",
            """
            Notes from the incident review

            The rollout went out at 14:20 and the error rate climbed for eleven
            minutes before anyone noticed. We agreed on three follow-ups.
            """,
            """
            - comprar café
            - reservar la sala
            - mandar la agenda
            """,
            """
            # Semana 12

            Pendiente: revisar el presupuesto y hablar con finanzas.
            """,
            """
            To do: escribir el postmortem
            Owner: yo
            """,
            "https://example.com/a/very/long/link?with=params",
        ]

        for (index, text) in prose.enumerated() {
            await Runner.test("leaves prose alone (\(index + 1))") { c in
                c.expect(Code.detect(text) == nil,
                         "fenced prose as \(Code.detect(text)?.language ?? "code"): \(text.prefix(40))")
            }
        }

        await Runner.test("fences code that itself contains a fence") { c in
            let readme = "```\nsome code\n```"
            let fenced = Code.fenced(readme, language: "markdown")
            c.expect(fenced.hasPrefix("````markdown\n"),
                     "the outer fence has to be longer than the inner one: \(fenced.prefix(20))")
            c.expect(fenced.hasSuffix("\n````"), "and closed with the same length")
        }

        await Runner.test("an unknown language is still recognised as code") { c in
            let rust = """
            fn main() {
                let config = load_config();
                println!("{}", config.region);
            }
            """
            let found = Code.detect(rust)
            c.expect(found != nil, "should be fenced even with no language tag")
            c.equal(found?.language, nil, "and claim no language rather than guess wrong")
        }

        await Runner.test("colours the pieces of a YAML block") { c in
            let yaml = "# comment\nname: api\nreplicas: 3\n"
            let tokens = Code.tokens(in: yaml, language: "yaml")
            func role(of word: String) -> Code.Role? {
                guard let range = yaml.range(of: word) else { return nil }
                let location = yaml.distance(from: yaml.startIndex, to: range.lowerBound)
                return tokens.first { NSLocationInRange(location, $0.range) }?.role
            }
            c.equal(role(of: "# comment"), .comment)
            c.equal(role(of: "name"), .key)
            c.equal(role(of: "replicas"), .key)
            c.equal(role(of: "3"), .number)
        }

        await Runner.test("a keyword inside a string is not a keyword") { c in
            let go = "s := \"package main\"\n"
            let tokens = Code.tokens(in: go, language: "go")
            let keywords = tokens.filter { $0.role == .keyword }
            c.equal(keywords.count, 0,
                    "the quoted words were coloured as code: \(keywords.count) keywords")
            c.equal(tokens.filter { $0.role == .string }.count, 1, "the string is one token")
        }

        await Runner.test("a quote inside a comment does not open a string") { c in
            let sh = "# don't do this\necho ok\n"
            let tokens = Code.tokens(in: sh, language: "bash")
            c.equal(tokens.first?.role, .comment)
            c.expect(!tokens.contains { $0.role == .string },
                     "the apostrophe started a string that swallowed the line")
        }

        await Runner.test("tokens never overlap") { c in
            let ts = """
            // build the client
            import { Client } from "@acme/sdk";
            const client = new Client({ retries: 3 });
            """
            let tokens = Code.tokens(in: ts, language: "typescript")
            c.expect(!tokens.isEmpty, "nothing was recognised at all")
            var previous = NSRange(location: -1, length: 0)
            var overlaps = 0
            for token in tokens {
                if NSIntersectionRange(previous, token.range).length > 0 { overlaps += 1 }
                previous = token.range
            }
            c.equal(overlaps, 0, "overlapping tokens paint over each other")
        }

        await Runner.test("SQL keywords are recognised in any case") { c in
            let upper = Code.tokens(in: "SELECT id FROM users", language: "sql")
            let lower = Code.tokens(in: "select id from users", language: "sql")
            c.equal(upper.filter { $0.role == .keyword }.count, 2, "SELECT and FROM")
            c.equal(lower.count, upper.count, "lowercase SQL is the same SQL")
        }

        await Runner.test("every language we claim to support has a grammar") { c in
            for language in ["yaml", "json", "hcl", "bash", "python", "go",
                             "javascript", "typescript", "dockerfile", "sql",
                             "toml", "makefile", "groovy", "xml"] {
                c.expect(Code.grammar(for: language) != nil, "no grammar for \(language)")
                let tokens = Code.tokens(in: "x = 1\n# note\n", language: language)
                _ = tokens        // must not trap on text that is not that language
            }
            c.expect(Code.grammar(for: "brainfuck") == nil, "an unknown language has no grammar")
            c.equal(Code.tokens(in: "anything", language: nil).count, 0,
                    "an untagged block is left plain")
        }

        await Runner.test("detection and grammar agree on every language") { c in
            // A language the detector can produce but the painter cannot colour
            // would be a fence tag that does nothing.
            for (_, snippet, _) in snippets {
                guard let found = Code.detect(snippet), let language = found.language else { continue }
                c.expect(Code.grammar(for: language) != nil,
                         "detected \(language), which has no grammar")
                c.expect(!Code.tokens(in: snippet, language: language).isEmpty,
                         "\(language) produced no tokens at all")
            }
        }
    }
}