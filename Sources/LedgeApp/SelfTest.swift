import AppKit
import LedgeCore
import LedgeIndex
import LedgeStore

/// Drives the deck through its states and checks the geometry it actually
/// produces. It exists because the layout is all hand-computed frames, rotations
/// and overlaps — the kind of thing that looks right in the source and is wrong
/// on screen. Run with `--selftest`.
@MainActor
enum SelfTest {

    private static var failures: [String] = []

    static func check(_ condition: Bool, _ description: String) {
        if condition {
            print("  \u{001B}[32m✓\u{001B}[0m \(description)")
        } else {
            failures.append(description)
            print("  \u{001B}[31m✗\u{001B}[0m \(description)")
        }
    }

    /// Renders a label offscreen with its first glyph in one colour and the
    /// rest in another, then reads the pixels back. It is the only way to prove,
    /// without a screen, that the title reads downward rather than upward —
    /// exactly the bug that shipped in the first build.
    static func checkLabelDirection() {
        let bounds = NSRect(x: 0, y: 0, width: Metrics.Tab.width,
                            height: NoteTabView.naturalHeight(for: "OFFICE"))
        let w = Int(bounds.width), h = Int(bounds.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else {
            check(false, "could not render a label offscreen"); return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Match a flipped NSView exactly: origin top-left, y downward.
        context.cgContext.translateBy(x: 0, y: bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)

        let size = Metrics.Tab.labelSize
        var attributes = VerticalLabel.attributes(size: size, color: .blue)
        let text = "OFFICE" as NSString
        let string = NSMutableAttributedString(string: text as String, attributes: attributes)
        string.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        attributes[.foregroundColor] = NSColor.black
        let measured = text.size(withAttributes: attributes)

        let (translate, _) = VerticalLabel.layout(in: bounds, textSize: measured,
                                                  inset: Metrics.Tab.labelInset)
        let transform = NSAffineTransform()
        transform.translateX(by: translate.x, yBy: translate.y)
        transform.rotate(byDegrees: 90)
        transform.concat()
        string.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()

        var firstRows: [Int] = [], restRows: [Int] = []
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.35 else { continue }
                if c.redComponent > 0.5 && c.blueComponent < 0.4 { firstRows.append(y) }
                if c.blueComponent > 0.5 && c.redComponent < 0.4 { restRows.append(y) }
            }
        }

        guard !firstRows.isEmpty, !restRows.isEmpty else {
            check(false, "the label rendered no ink — the title is not being drawn"); return
        }
        let firstMean = Double(firstRows.reduce(0, +)) / Double(firstRows.count)
        let restMean  = Double(restRows.reduce(0, +)) / Double(restRows.count)
        check(firstMean < restMean,
              String(format: "the title reads downward, not upward (first glyph at y=%.0f, rest at y=%.0f)",
                     firstMean, restMean))

        let inkColumns = Set((0..<w).filter { x in
            (0..<h).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.35 }
        })
        check(inkColumns.allSatisfy { $0 > 0 && $0 < w - 1 },
              "the title has clear air on both sides of the tab")
    }

    /// The geometry has to hold at every size the menu offers, not just at 100%.
    /// Scaling is where hand-computed layout goes wrong.
    /// The highlighter runs on every keystroke over the user's actual note. The
    /// one thing it must never do is change the text.
    /// Formatting must stop at the end of its own line.
    ///
    /// Reported from a real note: a `# Notas` heading followed by a list left
    /// the whole rest of the note set as a heading. Every line rule was compiled
    /// with `dotMatchesLineSeparators`, so `(.+)$` ran to the end of the string.
    static func checkFormattingStaysOnItsLine() {
        let base = NSFont.systemFont(ofSize: 14)
        let source = """
        # Notas
        - primero
        - segundo

        > una cita
        texto normal
        """
        let highlighter = MarkdownHighlighter(baseFont: base, ink: .black, accent: .blue)
        let storage = NSTextStorage(string: source)
        highlighter.highlight(storage)
        let text = source as NSString

        func font(at needle: String) -> NSFont? {
            let range = text.range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        func colour(at needle: String) -> NSColor? {
            let range = text.range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }

        check((font(at: "Notas")?.pointSize ?? 0) > base.pointSize, "the heading is a heading")
        check(font(at: "primero")?.pointSize == base.pointSize,
              String(format: "the line after a heading is not a heading (%.0fpt vs %.0fpt)",
                     font(at: "primero")?.pointSize ?? 0, base.pointSize))
        check(font(at: "segundo")?.pointSize == base.pointSize,
              "…nor is the one after that")
        check(font(at: "texto normal")?.pointSize == base.pointSize,
              "…nor anything further down the note")

        // and the same for a quote, which had the identical pattern
        let quoted = colour(at: "una cita")?.alphaComponent ?? 1
        let after = colour(at: "texto normal")?.alphaComponent ?? 1
        check(quoted < 1, "a quote is dimmed")
        check(after == 1, "the line after a quote is not, "
              + String(format: "(%.2f vs %.2f)", after, quoted))
    }

    /// How far apart two colours look, ignoring how bright they are.
    ///
    /// Contrast ratio is a luminance measure, and it is the wrong tool here: a
    /// yellow marker on light blue paper is obvious to anyone looking at it and
    /// scores 1.24:1, because both are light. Highlighters are told apart by
    /// hue. This is a plain distance in sRGB, which is crude but measures the
    /// thing that matters.
    static func colourDistance(_ a: NSColor, _ b: NSColor) -> Double {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return 0 }
        return max(abs(x.redComponent - y.redComponent),
                   max(abs(x.greenComponent - y.greenComponent),
                       abs(x.blueComponent - y.blueComponent)))
    }

    /// A highlighter that vanishes into the page is not a highlighter.
    static func checkHighlightReadsOnPaper() {
        for note in NoteColor.allCases {
            for dark in [false, true] {
                let paper = Palette.paper(note, dark: dark)
                let stroke = MarkerStroke.colour(for: note, dark: dark)
                // what the eye actually sees: the pen composited onto the paper
                let over = paper.blended(withFraction: stroke.alphaComponent,
                                         of: stroke.withAlphaComponent(1)) ?? paper

                let apart = colourDistance(over, paper)
                check(apart >= 0.10,
                      String(format: "a %@ note's %@ highlight is visibly not its paper (%.2f apart)",
                             note.rawValue, MarkerStroke.pen(for: note).rawValue, apart))

                let ink = Palette.ink(dark: dark)
                check(contrastRatio(ink, over) >= 4.5,
                      String(format: "…and the words stay readable through it (%.1f:1)",
                             contrastRatio(ink, over)))
            }
        }
    }

    /// Highlighting only the changed lines has to give the same answer as
    /// highlighting everything — including when the edit lands inside a fenced
    /// block, which spans lines and is the reason this was not done sooner.
    static func checkScopedHighlighting() {
        let documents = [
            "plain text\nmore text",
            "# Heading\n- a\n- b",
            "before\n```swift\nlet a = 1\nlet b = 2\n```\nafter",
            "~~~\nfenced\n~~~\n\n    indented\n",
            "a ==mark== and `code`\n- [ ] task\n[[link]] #tag",
        ]

        for (index, document) in documents.enumerated() {
            let text = document as NSString

            let full = NSTextStorage(string: document)
            MarkdownHighlighter(baseFont: .systemFont(ofSize: 14), ink: .black, accent: .blue)
                .highlight(full)

            // Now the same document, brought up to date one line at a time, the
            // way typing does it.
            let scoped = NSTextStorage(string: document)
            let piecemeal = MarkdownHighlighter(baseFont: .systemFont(ofSize: 14),
                                                ink: .black, accent: .blue)
            // Walk it a line at a time, the way typing does. Stepping character
            // by character and skipping newlines leaves a blank line in no range
            // at all, which is a flaw in the simulation and not in the code.
            var cursor = 0
            while cursor < text.length {
                let line = text.lineRange(for: NSRange(location: cursor, length: 0))
                let dirty = MarkdownHighlighter.dirtyRange(for: line, in: text)
                piecemeal.highlight(scoped, in: dirty)
                cursor = max(line.upperBound, cursor + 1)
            }

            var differences = 0
            var where_ = ""
            full.enumerateAttributes(in: NSRange(location: 0, length: full.length)) { attrs, range, _ in
                let other = scoped.attributes(at: range.location, effectiveRange: nil)
                let fontDiffers = (attrs[.font] as? NSFont) != (other[.font] as? NSFont)
                let backDiffers = (attrs[.backgroundColor] as? NSColor) != (other[.backgroundColor] as? NSColor)
                if fontDiffers || backDiffers {
                    differences += 1
                    if where_.isEmpty {
                        where_ = " — at \(text.substring(with: range).debugDescription): "
                            + (fontDiffers ? "font \((attrs[.font] as? NSFont)?.fontName ?? "-") vs "
                               + "\((other[.font] as? NSFont)?.fontName ?? "-") " : "")
                            + (backDiffers ? "background \(attrs[.backgroundColor] == nil ? "none" : "set") vs "
                               + "\(other[.backgroundColor] == nil ? "none" : "set")" : "")
                    }
                }
            }
            check(differences == 0,
                  "document \(index + 1) highlights the same line by line as all at once"
                  + (differences == 0 ? "" : where_))
        }
    }

    /// Find inside a note.
    static func checkFind() {
        var note = Note(title: "Groceries", color: .green)
        note.body = "apple and Apple and pineapple\nbread"
        let record = NoteRecord(note: note, filename: "Groceries.md", mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: note.body)
        card.frame = NSRect(x: 0, y: 0, width: 340, height: 260)
        card.layoutSubtreeIfNeeded()

        var edits = 0
        card.onEdit = { _ in edits += 1 }
        let before = card.textView.string

        check(card.textView.find("apple") == 3,
              "finds every occurrence, whatever the case: \(card.textView.find("apple"))")
        check(card.textView.find("BREAD") == 1, "and is not fussy about case going the other way")
        check(card.textView.find("zebra") == 0, "and finds nothing that is not there")

        // The one that matters: searching a note is not editing it.
        check(card.textView.string == before, "searching does not change a single character")
        check(edits == 0,
              "searching does not report an edit — otherwise every search would "
              + "start the save timer and rewrite the file")

        _ = card.textView.find("apple")
        check(card.textView.stepMatch(1) == 1, "next goes to the second match")
        check(card.textView.stepMatch(1) == 2, "and the third")
        check(card.textView.stepMatch(1) == 0, "and wraps round to the first")
        check(card.textView.stepMatch(-1) == 2, "previous wraps the other way")

        card.textView.clearFind()
        check(card.textView.findMatches.isEmpty, "closing find forgets the matches")

        // The result pen has to be told apart from a real highlight.
        for paper in NoteColor.allCases {
            let find = MarkerStroke.findPen(for: paper)
            let highlight = MarkerStroke.pen(for: paper)
            check(find != highlight && find != paper,
                  "on \(paper.rawValue) paper, a result (\(find.rawValue)) is neither the "
                  + "highlighter (\(highlight.rawValue)) nor the page")
        }
    }

    static func checkMarkdown() {
        let source = """
        # Heading
        - a list item
        Some **bold** and `code` and https://example.com
        [a link](https://example.com/x)

        ```swift
        let answer = 42
        ```
        """
        let base = NSFont.systemFont(ofSize: 14)
        let highlighter = MarkdownHighlighter(baseFont: base, ink: .black, accent: .blue)
        let storage = NSTextStorage(string: source)
        highlighter.highlight(storage)

        check(storage.string == source,
              "highlighting never alters a single character of the note")

        let text = source as NSString
        func attribute(_ key: NSAttributedString.Key, at needle: String, offset: Int = 0) -> Any? {
            let range = text.range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(key, at: range.location + offset, effectiveRange: nil)
        }

        let headingFont = attribute(.font, at: "Heading") as? NSFont
        check((headingFont?.pointSize ?? 0) > base.pointSize,
              "a # heading is set larger than the body")

        let hashColor = attribute(.foregroundColor, at: "# Heading") as? NSColor
        check((hashColor?.alphaComponent ?? 1) < 0.5,
              "the # itself recedes instead of shouting")

        let markerColor = attribute(.foregroundColor, at: "- a list") as? NSColor
        check((markerColor?.alphaComponent ?? 1) < 0.6, "a list marker dims")

        let boldFont = attribute(.font, at: "bold") as? NSFont
        check(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true,
              "**bold** is actually bold")

        let codeFont = attribute(.font, at: "code") as? NSFont
        check(codeFont?.isFixedPitch == true,
              "`code` drops to a monospace so it stays exactly readable")

        check(attribute(.link, at: "https://example.com") != nil,
              "a bare URL becomes a real link")
        check(attribute(.link, at: "a link") != nil,
              "a [labelled](url) link becomes a real link")

        // tasks and links
        let tasks = NSTextStorage(string: "- [ ] milk\n- [x] bread\nsee [[Office]]")
        highlighter.highlight(tasks)
        let taskText = tasks.string as NSString
        func taskAttribute(_ key: NSAttributedString.Key, at needle: String) -> Any? {
            let range = taskText.range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return tasks.attribute(key, at: range.location, effectiveRange: nil)
        }
        check((taskAttribute(.foregroundColor, at: "- [ ]") as? NSColor)?.alphaComponent ?? 1 < 0.6,
              "an unticked box recedes")
        check(taskAttribute(.strikethroughStyle, at: "bread") != nil,
              "a finished task is struck through")
        check(taskAttribute(.strikethroughStyle, at: "milk") == nil,
              "…and an unfinished one is not")
        check(taskAttribute(.underlineStyle, at: "Office") != nil,
              "a [[link]] is underlined so it looks like one")

        let blockFont = attribute(.font, at: "let answer = 42") as? NSFont
        check(blockFont?.isFixedPitch == true, "a ``` block is monospaced")
        check(attribute(.backgroundColor, at: "let answer = 42") != nil,
              "a ``` block gets a background so it reads as a block")
        check(attribute(.backgroundColor, at: "```swift") != nil,
              "the fences are part of the block, not three separate lines")
        let blockParagraph = attribute(.paragraphStyle, at: "let answer = 42") as? NSParagraphStyle
        check((blockParagraph?.headIndent ?? 0) > 0, "a ``` block is indented")
    }

    /// Squeezes the controls row at every width down to absurd, without needing
    /// a small display to do it. CI found this on a runner whose screen is a
    /// fraction of the size of the machine it was written on.
    /// Pressing a control must not move anything, and laying the row out twice
    /// must give the same answer both times.
    static func checkPressAndSettle() {
        let bar = NoteChromeBar(color: .blue)
        bar.frame = NSRect(x: 0, y: 0, width: bar.minimumWidth + 30, height: NoteChromeBar.height)
        bar.isInert = false
        bar.layoutSubtreeIfNeeded()
        bar.layout()

        let before = bar.controlFrames
        bar.flashPress()
        bar.layout()
        let after = bar.controlFrames

        check(before == after,
              "pressing a control leaves every control exactly where it was")
        if let layer = bar.layer {
            check(layer.anchorPoint == CGPoint(x: 0, y: 0),
                  String(format: "the press does not move the layer's anchor (%.2f, %.2f) — "
                         + "changing it shifts the view by half its size and leaves it there",
                         layer.anchorPoint.x, layer.anchorPoint.y))
        }

        // laying out repeatedly must converge, not drift
        var frames = [bar.controlFrames]
        for _ in 0..<4 {
            bar.layout()
            frames.append(bar.controlFrames)
        }
        check(Set(frames.map { "\($0)" }).count == 1,
              "laying the row out repeatedly settles instead of drifting")
    }

    static func checkChromeDegradation() {
        let bar = NoteChromeBar(color: .blue)
        let natural = bar.minimumWidth
        var narrowest = natural

        // 150 pt is below anything the deck can actually produce: the card is
        // floored well above it. Going lower only proves that three buttons and
        // five swatches cannot fit in a matchbox.
        for width in stride(from: natural + 40, through: 150, by: -5) {
            bar.frame = NSRect(x: 0, y: 0, width: width, height: NoteChromeBar.height)
            bar.layoutSubtreeIfNeeded()
            bar.layout()
            if bar.hasOverlappingControls {
                check(false, String(format: "controls overlap once the row is %.0f pt wide", width))
                return
            }
            narrowest = width
        }
        check(true, String(format: "the controls row survives being squeezed from %.0f pt to %.0f",
                           natural + 40, narrowest))
    }

    static func checkCodeFormatting() {
        func editor(_ text: String, selection: NSRange) -> NSTextView {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.string = text
            view.setSelectedRange(selection)
            return view
        }

        let inline = editor("call foo() here", selection: NSRange(location: 5, length: 5))
        MarkdownEditing.code(inline)
        check(inline.string == "call `foo()` here",
              "one line of code gets backticks: \(inline.string)")

        let block = editor("first line\nsecond line", selection: NSRange(location: 0, length: 22))
        MarkdownEditing.code(block)
        check(block.string == "```\nfirst line\nsecond line\n```",
              "more than one line gets a fenced block, because a backtick cannot "
              + "span lines: \(block.string.debugDescription)")

        // and the fenced form is one the highlighter actually recognises
        let highlighter = MarkdownHighlighter(baseFont: .systemFont(ofSize: 14), ink: .black, accent: .blue)
        let storage = NSTextStorage(string: block.string)
        highlighter.highlight(storage)
        let range = (block.string as NSString).range(of: "first line")
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        check(font?.isFixedPitch == true,
              "…and what the button produces is what the highlighter renders")

        MarkdownEditing.code(block)
        check(block.string == "first line\nsecond line",
              "pressing it again unfences: \(block.string.debugDescription)")

        // Markdown's other two ways of writing code, and the thing that looks
        // like one of them and is not.
        func attributesOf(_ source: String, at needle: String) -> (NSFont?, Any?) {
            let h = MarkdownHighlighter(baseFont: .systemFont(ofSize: 14), ink: .black, accent: .blue)
            let storage = NSTextStorage(string: source)
            h.highlight(storage)
            let range = (source as NSString).range(of: needle)
            guard range.location != NSNotFound else { return (nil, nil) }
            return (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                    storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
        }

        let tilde = attributesOf("~~~\nlet a = 1\n~~~", at: "let a = 1")
        check(tilde.0?.isFixedPitch == true && tilde.1 != nil,
              "a ~~~ fence is a code block too — Markdown's other fence")

        let indented = attributesOf("text\n\n    let b = 2\n", at: "let b = 2")
        check(indented.0?.isFixedPitch == true && indented.1 != nil,
              "four spaces after a blank line is a code block, which is what pasting "
              + "from a terminal gives you")

        let nested = attributesOf("- a\n\n    - nested\n", at: "- nested")
        check(nested.0?.isFixedPitch != true && nested.1 == nil,
              "a nested list item also starts with four spaces and must not become code")
    }

    static func checkMarkdownEditing() {
        func editor(_ text: String, selection: NSRange) -> NSTextView {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.string = text
            view.setSelectedRange(selection)
            return view
        }

        let bold = editor("make this loud", selection: NSRange(location: 10, length: 4))
        MarkdownEditing.wrap(bold, with: "**")
        check(bold.string == "make this **loud**", "⌘B wraps the selection: \(bold.string)")

        MarkdownEditing.wrap(bold, with: "**")
        check(bold.string == "make this loud", "⌘B again takes it back off: \(bold.string)")

        let list = editor("one\ntwo", selection: NSRange(location: 0, length: 7))
        MarkdownEditing.togglePrefix(list, "- ")
        check(list.string == "- one\n- two", "list prefixes every selected line: \(list.string)")
        MarkdownEditing.togglePrefix(list, "- ")
        check(list.string == "one\ntwo", "and toggles back off")

        let bullets = editor("- apple", selection: NSRange(location: 7, length: 0))
        check(MarkdownEditing.continueList(bullets), "Enter in a list is handled")
        check(bullets.string == "- apple\n- ", "Enter continues the bullet: \(bullets.string.debugDescription)")

        let numbered = editor("3. third", selection: NSRange(location: 8, length: 0))
        _ = MarkdownEditing.continueList(numbered)
        check(numbered.string == "3. third\n4. ", "numbered lists count on: \(numbered.string.debugDescription)")

        let ending = editor("- apple\n- ", selection: NSRange(location: 10, length: 0))
        _ = MarkdownEditing.continueList(ending)
        check(ending.string == "- apple\n" && ending.selectedRange().location == 8,
              "Enter on an empty item drops the marker without adding a line: \(ending.string.debugDescription)")

        let plain = editor("just words", selection: NSRange(location: 10, length: 0))
        check(!MarkdownEditing.continueList(plain), "Enter outside a list is left alone — this is what broke it before")

        // ---- tasks
        let task = editor("- [ ] milk", selection: NSRange(location: 10, length: 0))
        check(MarkdownEditing.continueList(task), "Enter in a task list is handled")
        check(task.string == "- [ ] milk\n- [ ] ",
              "a checklist continues as a checklist, not as a plain bullet: \(task.string.debugDescription)")

        let taskEnding = editor("- [ ] milk\n- [ ] ", selection: NSRange(location: 17, length: 0))
        _ = MarkdownEditing.continueList(taskEnding)
        check(taskEnding.string == "- [ ] milk\n", "an empty task ends the list")

        let promote = editor("milk\nbread", selection: NSRange(location: 0, length: 10))
        MarkdownEditing.toggleTask(promote)
        check(promote.string == "- [ ] milk\n- [ ] bread",
              "⌘⇧T turns lines into tasks: \(promote.string.debugDescription)")
        MarkdownEditing.toggleTask(promote)
        check(promote.string == "milk\nbread", "and turns them back")

        let fromBullets = editor("- milk", selection: NSRange(location: 0, length: 6))
        MarkdownEditing.toggleTask(fromBullets)
        check(fromBullets.string == "- [ ] milk",
              "an existing bullet keeps its bullet: \(fromBullets.string.debugDescription)")

        // ---- the three things a text editor is expected to do

        // A real NoteTextView, so the key handling is exercised and not just the
        // transformation underneath it.
        func note(_ text: String, selection: NSRange) -> NoteTextView {
            let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.string = text
            view.setSelectedRange(selection)
            return view
        }
        func optionArrow(_ up: Bool) -> NSEvent {
            let key = String(UnicodeScalar(UInt32(up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey))!)
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: key, charactersIgnoringModifiers: key,
                                    isARepeat: false, keyCode: up ? 126 : 125)!
        }

        let moving = note("alpha\nbeta\ngamma", selection: NSRange(location: 0, length: 0))
        moving.keyDown(with: optionArrow(false))
        check(moving.string == "beta\nalpha\ngamma",
              "⌥↓ moves the line down: \(moving.string.debugDescription)")
        check(moving.selectedRange().location == 5 && moving.selectedRange().length == 5,
              "the moved line stays selected, so ⌥↓ can be pressed again")
        moving.keyDown(with: optionArrow(true))
        check(moving.string == "alpha\nbeta\ngamma", "⌥↑ brings it back")

        let stuck = note("only\nline", selection: NSRange(location: 0, length: 0))
        stuck.keyDown(with: optionArrow(true))
        check(stuck.string == "only\nline", "⌥↑ on the first line does nothing rather than eating it")

        let renumbered = note("1. a\n2. b\n3. c", selection: NSRange(location: 0, length: 0))
        renumbered.keyDown(with: optionArrow(false))
        check(renumbered.string == "1. b\n2. a\n3. c",
              "moving a numbered item renumbers the list: \(renumbered.string.debugDescription)")

        // Typing a bracket over a selection.
        let wrapping = note("call me maybe", selection: NSRange(location: 5, length: 2))
        wrapping.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(wrapping.string == "call (me) maybe",
              "typing ( with a selection wraps it: \(wrapping.string.debugDescription)")
        check(wrapping.selectedRange() == NSRange(location: 6, length: 2),
              "and the same words stay selected, so you can wrap again")

        let replacing = note("call me maybe", selection: NSRange(location: 5, length: 2))
        replacing.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(replacing.string == "call x maybe",
              "an ordinary character still replaces the selection: \(replacing.string.debugDescription)")

        let multiline = note("one\ntwo", selection: NSRange(location: 0, length: 7))
        multiline.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(multiline.string == "\"", "several lines are a block, not a phrase to quote")

        // Pasting a link over a selection. A private pasteboard, so running the
        // self test does not touch what you had copied.
        let board = NSPasteboard(name: NSPasteboard.Name("ledge.selftest"))
        board.clearContents()
        board.setString("https://example.com/a", forType: .string)

        let linking = note("read the docs here", selection: NSRange(location: 9, length: 4))
        check(MarkdownEditing.pasteLink(linking, from: board), "pasting a URL over words is handled")
        check(linking.string == "read the [docs](https://example.com/a) here",
              "the selection becomes the link text: \(linking.string.debugDescription)")

        let noSelection = note("nothing selected", selection: NSRange(location: 4, length: 0))
        check(!MarkdownEditing.pasteLink(noSelection, from: board),
              "with no selection a URL is pasted as a URL")

        board.clearContents()
        board.setString("some copied prose", forType: .string)
        let prose = note("read the docs here", selection: NSRange(location: 9, length: 4))
        check(!MarkdownEditing.pasteLink(prose, from: board),
              "pasting text that is not a URL is an ordinary paste")
        board.clearContents()
    }

    /// Pasting source code: the whole point is that it happens by itself, so
    /// what is checked here is the paste, not the functions under it.
    static func checkPastedCode() {
        func note(_ text: String, selection: NSRange) -> NoteTextView {
            let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.configureForNotes()
            view.string = text
            view.setSelectedRange(selection)
            return view
        }
        let board = NSPasteboard(name: NSPasteboard.Name("ledge.selftest.code"))
        func put(_ text: String) {
            board.clearContents()
            board.setString(text, forType: .string)
        }

        let manifest = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: api
        """
        put(manifest)

        let empty = note("", selection: NSRange(location: 0, length: 0))
        let pasted = MarkdownEditing.pasteCode(empty, from: board)
        check(pasted.did, "a manifest pasted into a note is fenced")
        check(empty.string.hasPrefix("```yaml\n"),
              "…with its language on the fence: \(empty.string.prefix(12).debugDescription)")
        check(empty.string.hasSuffix("\n```"), "…and closed")
        check(pasted.title == "Deployment/api",
              "…and it names the note: \(pasted.title ?? "nothing")")

        // The fence has to start a line of its own, or it is not a fence.
        let midLine = note("see this: ", selection: NSRange(location: 10, length: 0))
        _ = MarkdownEditing.pasteCode(midLine, from: board)
        check(midLine.string.contains("\n```yaml\n"),
              "a fence pasted mid-line gets a line of its own: \(midLine.string.prefix(20).debugDescription)")

        // Pasting code into code must not close the block it lands in.
        let inside = note("```yaml\nexisting: true\n```", selection: NSRange(location: 22, length: 0))
        let nested = MarkdownEditing.pasteCode(inside, from: board)
        check(!nested.did, "pasting into a block leaves it alone — a second fence would end the first")

        // And the half that matters more.
        put("Quedamos en migrar el cluster el martes, después del deploy.")
        let prose = note("", selection: NSRange(location: 0, length: 0))
        check(!MarkdownEditing.pasteCode(prose, from: board).did,
              "pasting a sentence is an ordinary paste")
        check(prose.string.isEmpty, "and it changed nothing")

        put("una sola línea de texto")
        let single = note("", selection: NSRange(location: 0, length: 0))
        check(!MarkdownEditing.pasteCode(single, from: board).did,
              "one line is never worth a code block")

        board.clearContents()

        // Nothing in a block is a spelling mistake.
        let checked = note("kubectl\n\n```bash\nkubectl get pods\n```", selection: NSRange(location: 0, length: 0))
        let prose_ = (checked.string as NSString).range(of: "kubectl")
        let code_ = (checked.string as NSString).range(of: "kubectl get")
        checked.setSpellingState(NSAttributedString.SpellingState.spelling.rawValue, range: prose_)
        checked.setSpellingState(NSAttributedString.SpellingState.spelling.rawValue, range: code_)
        // Spelling marks are temporary attributes on the layout manager, not
        // attributes of the text — reading the storage finds nothing either way.
        let marked = { (r: NSRange) in
            checked.layoutManager?.temporaryAttribute(.spellingState, atCharacterIndex: r.location,
                                                      effectiveRange: nil) != nil
        }
        check(marked(prose_), "a misspelling in prose is still marked")
        check(!marked(code_), "the same word inside a code block is not")

        // The substitutions that would rewrite what you pasted.
        check(!checked.isAutomaticTextReplacementEnabled && !checked.isAutomaticSpellingCorrectionEnabled
              && !checked.isAutomaticQuoteSubstitutionEnabled && !checked.isAutomaticDashSubstitutionEnabled,
              "a text view that rewrites what you type cannot hold a shell command")

        // The colouring, read back off the attributes rather than asserted.
        let source = "```yaml\nname: api\n# note\n```"
        let highlighter = MarkdownHighlighter(baseFont: .systemFont(ofSize: 14),
                                              ink: .black, accent: .blue)
        let storage = NSTextStorage(string: source)
        highlighter.highlight(storage)
        func colour(of needle: String) -> NSColor? {
            let range = (source as NSString).range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.foregroundColor, at: range.location,
                                     effectiveRange: nil) as? NSColor
        }
        func weight(of needle: String) -> NSFont.Weight? {
            let range = (source as NSString).range(of: needle)
            guard range.location != NSNotFound,
                  let font = storage.attribute(.font, at: range.location,
                                               effectiveRange: nil) as? NSFont
            else { return nil }
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? NSNumber).map { NSFont.Weight($0.doubleValue) }
        }

        let key = colour(of: "name")
        let value = colour(of: "api")
        let comment = colour(of: "# note")
        check(key != nil && value != nil && comment != nil, "the block was not coloured at all")
        check(key != value, "a YAML key and its value are the same colour — nothing was painted")
        check(comment != key, "the comment is not set apart from the keys")
        check((weight(of: "name") ?? .regular) > (weight(of: "api") ?? .regular),
              "keys should carry more weight than values")
        check((comment?.alphaComponent ?? 1) < (key?.alphaComponent ?? 0),
              "the comment should be the faintest thing in the block")
    }

    /// The copy mark on a code block. None of this can be seen from here, so
    /// the position is read back off the view and the drawing off its pixels.
    static func checkCodeCopy() {
        let text = """
        antes

        ```bash
        kubectl get pods
        helm upgrade --install api ./chart
        ```

        después
        """
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.configureForNotes()
        view.isVerticallyResizable = true
        view.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.string = text
        guard let layoutManager = view.layoutManager, let container = view.textContainer else {
            check(false, "the text view has no layout")
            return
        }
        layoutManager.ensureLayout(for: container)

        func rect(_ needle: String) -> NSRect {
            let range = (text as NSString).range(of: needle)
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var r = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            r.origin.x += view.textContainerOrigin.x
            r.origin.y += view.textContainerOrigin.y
            return r
        }

        let block = rect("kubectl get pods")
        let outside = rect("después")

        view.updateCodeCopy(at: NSPoint(x: block.midX, y: block.midY))
        check(view.codeCopyFrameForTesting != nil, "hovering a code block shows the copy mark")

        if let mark = view.codeCopyFrameForTesting, let whole = view.codeBlockRectForTesting {
            check(mark.maxX <= whole.maxX && mark.minX > whole.midX,
                  "the mark sits at the right-hand end of the block: \(mark.minX) in \(whole)")
            check(abs(mark.minY - whole.minY) < 12,
                  "…at its top, not floating in the middle: \(mark.minY) vs \(whole.minY)")
            check(mark.maxX <= container.size.width + view.textContainerOrigin.x,
                  "…and inside the note, not off its right edge")
        }

        view.updateCodeCopy(at: NSPoint(x: outside.midX, y: outside.midY))
        check(view.codeCopyFrameForTesting == nil, "hovering ordinary text hides it again")

        // Below the last line there is no text, but asking which character is
        // under the pointer still answers with the last one — which is inside
        // the block when the block ends the note. Only the rectangle knows.
        let ending = NoteTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        ending.configureForNotes()
        ending.isVerticallyResizable = true
        ending.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        ending.textContainer?.widthTracksTextView = false
        ending.string = "nota\n\n```bash\nkubectl get pods\n```"
        if let lm = ending.layoutManager, let tc = ending.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            ending.updateCodeCopy(at: NSPoint(x: 40, y: used.maxY + 60))
            check(ending.codeCopyFrameForTesting == nil,
                  "the empty space under a note is not part of the block that ends it")
            ending.updateCodeCopy(at: NSPoint(x: 40, y: used.maxY - 8))
            check(ending.codeCopyFrameForTesting != nil, "…while the block itself still shows it")
        }

        // What it puts on the clipboard.
        let board = NSPasteboard(name: NSPasteboard.Name("ledge.selftest.copy"))
        view.updateCodeCopy(at: NSPoint(x: block.midX, y: block.midY))
        let before = view.string
        let copied = view.copyHoveredBlock(to: board)
        check(copied == "kubectl get pods\nhelm upgrade --install api ./chart",
              "the block is copied without its fences: \(copied?.debugDescription ?? "nothing")")
        check(board.string(forType: .string) == copied, "…and it is on the clipboard")
        check(!(copied?.contains("```") ?? true), "no backticks: pasting this into a shell must just run")
        check(view.string == before, "copying does not change a single character")

        // ⌘⇧C takes the block the caret is in, and only then.
        let caret = (text as NSString).range(of: "helm upgrade")
        view.setSelectedRange(NSRange(location: caret.location, length: 0))
        check(view.copyBlockAtCaret(to: board) == copied, "⌘⇧C takes the block the caret is in")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        check(view.copyBlockAtCaret(to: board) == nil,
              "with the caret outside a block it does nothing, so ⌘⇧C stays ⌘⇧C")
        board.clearContents()

        // The drawing, read back as pixels: the two states have to look
        // different, or the tick is not feedback.
        func pixels(of button: CodeCopyButton) -> [UInt8] {
            guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return [] }
            button.cacheDisplay(in: button.bounds, to: rep)
            guard let data = rep.bitmapData else { return [] }
            return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
        }
        let button = CodeCopyButton()
        button.ink = .black
        button.isHidden = false
        let resting = pixels(of: button)
        check(resting.contains { $0 != 0 }, "the copy mark draws something at all")

        // Compared as shapes, not as pixels: the two states are drawn at
        // different alphas, so any two renderings differ and a pixel comparison
        // would pass even with the tick never drawn.
        let sheets = button.markPath(confirmed: false)
        let tick = button.markPath(confirmed: true)
        check(sheets.elementCount != tick.elementCount,
              "the tick is the same shape as the copy mark — no feedback at all")
        check(tick.elementCount == 3, "the tick is three points: \(tick.elementCount)")
        check(tick.bounds.height < sheets.bounds.height,
              "the tick should sit inside the space the sheets used")

        button.confirm()
        check(button.showingConfirmation, "clicking leaves the tick showing")
        check(pixels(of: button) != resting, "and the button redraws")
        button.forget()
        check(pixels(of: button) == resting, "and it goes back to the copy mark afterwards")
    }

    /// The bug this was built for: a note open on screen while an agent writes
    /// to it. End to end, through the real card, the real debounce and the real
    /// file — the pieces each behaved correctly on their own, which is why it
    /// took a note on screen to see it.
    static func checkConcurrentWriters(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let record = deck.recordsForTesting.first else {
            check(false, "no note to write to"); return
        }
        let url = folder.appendingPathComponent(record.filename)

        deck.fanOut(takingFocus: false)
        deck.previewForTesting(record.id)
        deck.expand(record.id)
        guard deck.debugCardBody() != nil else { check(false, "the card did not open"); return }

        // You are typing in it.
        let typed = "lo que estaba escribiendo \(Int(Date().timeIntervalSince1970))"
        deck.debugTypeIntoCard("\n" + typed)

        // The agent adds nine tasks, exactly as the command does.
        let feed = FeedStore(folder: folder)
        guard let entry = try? feed.find(record.id) else {
            check(false, "the command cannot find the note"); return
        }
        var note = entry.note
        for n in 1...9 { note.body = FeedEdit.addingTask("tarea \(n)", to: note.body) }
        _ = try? feed.write(note, to: entry.url)

        // Deliberately no refresh in between.
        //
        // That is the reported case: the card is the key window's first
        // responder, so the update is refused on the way in — quite rightly,
        // nothing should yank text out from under a caret — and the save then
        // goes out carrying text that predates the agent. Driving it this way
        // reproduces it without needing a key window, which a self test running
        // without a display does not have.
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(900))

        let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(onDisk.contains(typed), "your own typing must survive the agent's write")
        check(Checkbox.items(in: onDisk).count >= 9,
              "all nine of the agent's tasks must survive yours — this is the bug: "
              + "found \(Checkbox.items(in: onDisk).count)")

        // And the other half: a change arriving while the note is open has to
        // show up on screen, not wait for you to touch something.
        var later = Frontmatter.parse(onDisk, fallbackTitle: "", fallbackID: record.id)
        later.body = FeedEdit.appending("una entrada más del agente", to: later.body)
        _ = try? feed.write(later, to: url)
        await deck.reconcileForTesting([record.filename])

        check(deck.debugCardBody()?.contains("una entrada más del agente") == true,
              "…and it appears on screen without waiting for anything")
        check(deck.debugCardBody()?.contains(typed) == true,
              "…with your text still in the card")
    }

    /// The half tick on a task in progress. Read off the attributes and then
    /// off the pixels, because neither one alone says it was drawn.
    /// The highlighter is handed a range that no longer exists.
    ///
    /// It highlights a turn of the run loop after the edit that caused it, so
    /// by then more keys may have been pressed. Setting attributes past the end
    /// of the text throws an NSException, which is not a caught error in Swift:
    /// it takes the whole app down. Four quick backspaces did it.
    ///
    /// If this ever comes back, this check does not print a failure — the
    /// process dies here and the rest of the suite never runs, which is its own
    /// kind of loud.
    static func checkStaleHighlightRange() {
        let highlighter = MarkdownHighlighter(baseFont: .systemFont(ofSize: 14),
                                              ink: .black, accent: .blue)
        let storage = NSTextStorage(string: "una línea\notra línea")
        highlighter.highlight(storage, in: NSRange(location: 0, length: storage.length + 200))
        highlighter.highlight(storage, in: NSRange(location: storage.length + 10, length: 5))
        highlighter.highlight(storage, in: NSRange(location: storage.length, length: 0))
        check(storage.string == "una línea\notra línea",
              "a range that outlived its text must be clipped, not obeyed")

        // And the real path: a burst of edits, each one leaving a range behind.
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.configureForNotes()
        view.string = "una línea que se va a borrar"
        view.textStorage?.delegate = highlighter
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        for _ in 0..<12 { view.deleteBackward(nil) }
        check(view.string.count < 28, "the deletions happened: \(view.string.debugDescription)")
    }

    static func checkProgressTick() {
        let source = "- [ ] todo\n- [/] en curso\n- [x] hecho"
        let highlighter = MarkdownHighlighter(baseFont: .systemFont(ofSize: 14),
                                              ink: .black, accent: .systemBlue)
        let storage = NSTextStorage(string: source)
        highlighter.highlight(storage)

        let slash = (source as NSString).range(of: "/")
        let tick = storage.attribute(ProgressTick.attribute, at: slash.location, effectiveRange: nil)
        check(tick != nil, "an in-progress box is marked for the tick to be drawn on")
        let glyph = storage.attribute(.foregroundColor, at: slash.location,
                                      effectiveRange: nil) as? NSColor
        check(glyph?.alphaComponent == 0,
              "the slash itself is painted out — the tick replaces it, it does not sit on top of it")

        // The other two lines must not be marked.
        let plain = (source as NSString).range(of: "- [ ]")
        check(storage.attribute(ProgressTick.attribute, at: plain.location + 3,
                                effectiveRange: nil) == nil,
              "an ordinary task carries no tick")

        let content = (source as NSString).range(of: "en curso")
        let ink = storage.attribute(.foregroundColor, at: content.location,
                                    effectiveRange: nil) as? NSColor
        let doneContent = (source as NSString).range(of: "hecho")
        let doneInk = storage.attribute(.foregroundColor, at: doneContent.location,
                                        effectiveRange: nil) as? NSColor
        check((ink?.alphaComponent ?? 0) > (doneInk?.alphaComponent ?? 1),
              "a task in progress leans forward while a finished one recedes")

        // And that something is actually drawn.
        let box = NSRect(x: 0, y: 0, width: 12, height: 16)
        let blank = NSImage(size: box.size)
        blank.lockFocus(); blank.unlockFocus()
        let drawn = NSImage(size: box.size)
        drawn.lockFocus()
        ProgressTick.draw(in: box, colour: .black)
        drawn.unlockFocus()
        func pixels(_ image: NSImage) -> [UInt8] {
            guard let data = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: data), let bytes = rep.bitmapData
            else { return [] }
            return Array(UnsafeBufferPointer(start: bytes, count: rep.bytesPerRow * rep.pixelsHigh))
        }
        let empty = pixels(blank), marked = pixels(drawn)
        check(!marked.isEmpty && marked != empty, "the tick draws nothing at all")

        // Half a tick, not a whole one: it must stay in the left half of the box.
        var rightmost = 0
        if let data = drawn.tiffRepresentation, let rep = NSBitmapImageRep(data: data) {
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.1 {
                        rightmost = max(rightmost, x)
                    }
                }
            }
            check(rightmost > 0 && rightmost < rep.pixelsWide * 3 / 4,
                  "the mark has to read as unfinished — it reaches \(rightmost) of \(rep.pixelsWide)")
        }
    }

    /// Changing the size while a note is open.
    ///
    /// Everything else on the deck follows the zoom immediately; the note you
    /// are reading is the one thing you would notice, and it was the one thing
    /// that did not.
    static func checkZoomWithNoteOpen(deck: DeckController) async {
        let saved = Settings.zoom
        defer { Settings.zoom = saved }

        await deck.refresh()
        guard let record = deck.recordsForTesting.first else {
            check(false, "no note to open"); return
        }
        Settings.zoom = 1.0
        deck.fanOut(takingFocus: false)
        deck.previewForTesting(record.id)
        guard let before = deck.debugCardFrame(), let beforeFont = deck.debugCardFontSize() else {
            check(false, "no card is open"); return
        }

        Settings.zoom = 1.45
        guard let after = deck.debugCardFrame(), let afterFont = deck.debugCardFontSize() else {
            check(false, "the card disappeared when the size changed"); return
        }

        check(after.width > before.width,
              "the open note has to grow with everything else: \(before.width) → \(after.width)")
        check(afterFont > beforeFont,
              "and so does its text: \(beforeFont) pt → \(afterFont) pt")

        Settings.zoom = 1.0
        guard let back = deck.debugCardFrame() else { check(false, "no card"); return }
        check(abs(back.width - before.width) < 0.5,
              "and it goes back down again: \(back.width) vs \(before.width)")

        // The same, with the caret in it — which is how a note is usually open.
        deck.beginEditingForTesting(record.id)
        let editingBefore = deck.debugCardFrame()?.width ?? 0
        Settings.zoom = 1.45
        let editingAfter = deck.debugCardFrame()?.width ?? 0
        check(editingAfter > editingBefore,
              "a note being written in follows the size too: \(editingBefore) → \(editingAfter)")
        Settings.zoom = 1.0

        // And a note the user has dragged to a size of its own. Its size is
        // remembered in points, so without scaling it is the one note on the
        // deck that ignores the setting entirely.
        try? await deck.setGeometryForTesting(id: record.id, width: 420, height: 300)
        await deck.refresh()
        deck.previewForTesting(record.id)
        let resizedBefore = deck.debugCardFrame()?.width ?? 0
        Settings.zoom = 1.45
        let resizedAfter = deck.debugCardFrame()?.width ?? 0
        check(resizedAfter > resizedBefore,
              "a note you resized still has to follow the zoom: \(resizedBefore) → \(resizedAfter)")
        Settings.zoom = 1.0
        try? await deck.setGeometryForTesting(id: record.id, width: nil, height: nil)
        await deck.refresh()

        // The full editor is a window of its own, so nothing was going to tell
        // it. Its body size was a hard-coded 20 pt: reopening it did not help
        // either, it simply never followed the setting.
        deck.previewForTesting(record.id)
        deck.expand(record.id)
        guard let editor = deck.debugEditor(record.id) else {
            check(false, "the editor did not open"); return
        }
        let editorBefore = editor.textView.font?.pointSize ?? 0
        Settings.zoom = 1.45
        let editorAfter = editor.textView.font?.pointSize ?? 0
        check(editorAfter > editorBefore,
              "the full editor follows the size too: \(editorBefore) pt → \(editorAfter) pt")
        Settings.zoom = 1.0

        // And a note on the desk. Checked through the card rather than through
        // a real floating panel: making one here hung the suite, and what the
        // desk actually calls is this.
        let desk = NoteCardView(record: record, body: "una nota en el escritorio")
        desk.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let deskBefore = desk.textView.font?.pointSize ?? 0
        Settings.zoom = 1.45
        desk.applySizeSettings()
        let deskAfter = desk.textView.font?.pointSize ?? 0
        check(deskAfter > deskBefore,
              "a note on the desk follows it as well: \(deskBefore) pt → \(deskAfter) pt")
        Settings.zoom = 1.0
    }

    /// ⌘+ on keyboards that are not this one.
    ///
    /// The previous version of this check synthesised the US spelling, passed,
    /// and shipped a ⌘+ that did nothing on a Spanish keyboard. Reading the
    /// event instead of declaring a key equivalent is what makes the layouts
    /// below answerable at all.
    static func checkZoomKeys() {
        func event(_ characters: String, _ ignoring: String,
                   _ modifiers: NSEvent.ModifierFlags, code: UInt16 = 0) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                             charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)
        }

        let bigger: [(String, String, NSEvent.ModifierFlags, String)] = [
            ("+", "=", [.command, .shift], "US — ⌘⇧="),
            ("+", "+", [.command], "Spanish — + is its own key"),
            ("=", "=", [.command], "US — ⌘= with no shift"),
            ("+", "*", [.command], "a layout where ⇧ gives * and + is unshifted"),
            ("＋", "+", [.command], "an odd layout, as long as one of the two says +"),
        ]
        for (characters, ignoring, modifiers, layout) in bigger {
            guard let event = event(characters, ignoring, modifiers) else { continue }
            check(ZoomKeys.command(for: event) == .bigger, "⌘+ makes things bigger on \(layout)")
        }

        for (characters, layout) in [("-", "the usual minus"), ("_", "a layout that reports _")] {
            guard let event = event(characters, characters, [.command]) else { continue }
            check(ZoomKeys.command(for: event) == .smaller, "⌘- makes things smaller on \(layout)")
        }
        if let event = event("0", "0", [.command]) {
            check(ZoomKeys.command(for: event) == .actualSize, "⌘0 goes back to normal")
        }
        // The keypad, where the characters are right but the position is not.
        if let event = event("+", "+", [.command, .numericPad]) {
            check(ZoomKeys.command(for: event) == .bigger, "the keypad + counts too")
        }

        // And what must be left alone.
        for (characters, modifiers, what) in [
            ("+", NSEvent.ModifierFlags([.command, .option]), "⌥⌘+ belongs to something else"),
            ("+", NSEvent.ModifierFlags([]), "a plain + is text, not a shortcut"),
            ("b", NSEvent.ModifierFlags([.command]), "⌘B is bold"),
            ("1", NSEvent.ModifierFlags([.command]), "⌘1 opens the first note"),
        ] {
            guard let event = event(characters, characters, modifiers) else { continue }
            check(ZoomKeys.command(for: event) == nil, what)
        }

        // End to end, through the same function the monitor calls.
        let saved = (zoom: Settings.zoom, tab: Settings.tabScale,
                     card: Settings.cardScale, length: Settings.tabMaxLength)
        defer {
            Settings.zoom = saved.zoom; Settings.tabScale = saved.tab
            Settings.cardScale = saved.card; Settings.tabMaxLength = saved.length
        }
        Settings.zoom = 1.0
        if let spanish = event("+", "+", [.command]) {
            check(ZoomKeys.handle(spanish), "the monitor takes the event")
            check(Settings.zoom > 1.0, "…and the deck is bigger: \(Settings.zoom)")
        }
    }

    /// The keys, pressed rather than declared.
    ///
    /// A menu item is a claim that a key does something. The status menu made
    /// that claim about ⌘+ and ⌘- for months and could never have honoured it,
    /// because a status item's menu is not in the key equivalent chain. So these
    /// are checked by handing the event to the menu and watching what changes.
    static func checkShortcuts() {
        let saved = (zoom: Settings.zoom, tab: Settings.tabScale,
                     card: Settings.cardScale, length: Settings.tabMaxLength)
        defer {
            Settings.zoom = saved.zoom; Settings.tabScale = saved.tab
            Settings.cardScale = saved.card; Settings.tabMaxLength = saved.length
        }
        MainMenu.install()
        guard let menu = NSApp.mainMenu else { check(false, "no main menu"); return }

        func event(_ characters: String, _ ignoring: String,
                   _ modifiers: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                             charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: 0)
        }

        // The zoom keys are pressed for real: they only move a setting, and this
        // one has to be end to end, because what was wrong with ⌘+ was that the
        // item existed and AppKit still would not match it.
        func press(_ characters: String, _ ignoring: String,
                   _ modifiers: NSEvent.ModifierFlags = [.command]) -> Bool {
            guard let event = event(characters, ignoring, modifiers) else { return false }
            return menu.performKeyEquivalent(with: event)
        }

        // Every way a keyboard can send ⌘+. Checking only the one this machine
        // has is how the last version shipped a ⌘+ that worked here and did
        // nothing on a Spanish keyboard, where + is not a shifted key at all.
        for (characters, ignoring, modifiers, layout) in [
            ("+", "=", NSEvent.ModifierFlags([.command, .shift]), "US, ⌘⇧="),
            ("+", "+", NSEvent.ModifierFlags([.command]), "Spanish, + unshifted"),
            ("=", "=", NSEvent.ModifierFlags([.command]), "US, ⌘= without shift"),
        ] {
            Settings.zoom = 1.0
            check(press(characters, ignoring, modifiers), "⌘+ is claimed on \(layout)")
            check(Settings.zoom > 1.0, "…and makes things bigger on \(layout): \(Settings.zoom)")
        }

        Settings.zoom = 1.45
        check(press("-", "-"), "⌘- is claimed")
        check(Settings.zoom < 1.45, "…and takes it back down: \(Settings.zoom)")

        // The rest are only inspected. Pressing them would actually create a
        // note, put one away and open the status menu, which then turns up as a
        // mysterious failure three checks later — it did.
        func claims(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> Bool {
            func search(_ menu: NSMenu) -> Bool {
                for item in menu.items {
                    if item.keyEquivalent == key,
                       item.keyEquivalentModifierMask == modifiers { return true }
                    if let submenu = item.submenu, search(submenu) { return true }
                }
                return false
            }
            return search(menu)
        }
        for (key, what) in [("s", "⌘S"), ("w", "⌘W"), ("n", "⌘N"), (",", "⌘,"),
                            ("0", "⌘0"), ("1", "⌘1"), ("9", "⌘9")] {
            check(claims(key), "\(what) is declared in the main menu, where it can fire")
        }
        check(!claims("j"), "a key nothing claims is left alone, so it can reach the note")
    }

    /// Typing, one keystroke at a time, with the note saving between them.
    ///
    /// The merge that lets an agent write to an open note turned every save
    /// into a three-way merge — including against the note's own previous save.
    /// When the baseline was even slightly wrong, that merge saw two writers
    /// where there was one and kept both versions: the line you were typing
    /// appeared again on the line below.
    static func checkTypingDoesNotDuplicate(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let record = deck.recordsForTesting.first else {
            check(false, "no note to type in"); return
        }
        let url = folder.appendingPathComponent(record.filename)

        deck.fanOut(takingFocus: false)
        deck.previewForTesting(record.id)
        deck.expand(record.id)
        guard deck.debugCardBody() != nil else { check(false, "no card"); return }

        // The shape that actually breaks. Typing at the end of the note never
        // did — the first version of this check appended and passed with the
        // bug still in.
        //
        //   press Enter at the end, and the note is saved ending in a newline
        //   the file will not keep. The baseline now says one thing and the file
        //   says another, so the next edit to a line *above* looks like two
        //   people changing it, and both versions are kept.
        let stamp = Int(Date().timeIntervalSince1970)
        let sentence = "una línea \(stamp)"
        deck.debugTypeIntoCard("\n" + sentence)
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(500))

        deck.debugTypeIntoCard("\n")            // Enter: the body now ends in one
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(500))

        // Back up into the sentence and keep writing.
        let caret = ((deck.debugCardBody() ?? "") as NSString).range(of: sentence)
        deck.debugTypeIntoCard(" y más", at: caret.upperBound)
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(700))

        let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(onDisk.contains(sentence + " y más"),
              "the sentence should be on disk in one piece: \(onDisk.suffix(90).debugDescription)")
        let occurrences = onDisk.components(separatedBy: sentence).count - 1
        check(occurrences == 1,
              "typing must not leave a copy of the line behind — found \(occurrences): "
              + "\(onDisk.suffix(90).debugDescription)")

        // And deleting, which produced a line holding everything but the
        // character that was removed.
        deck.debugDeleteBackwardInCard(4)
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(600))
        let afterDelete = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(afterDelete.components(separatedBy: sentence).count - 1 == 1,
              "deleting must not either: \(afterDelete.suffix(120))")
        check(!afterDelete.contains(sentence + " y más"),
              "and the deletion actually happened")
        check(deck.debugCardBody().map { afterDelete.contains($0.trimmingCharacters(in: .newlines)) } == true,
              "the card and the file still agree")
    }

    /// An agent writing to a note you do *not* have open.
    ///
    /// The index picks it up, so All Notes and search are right — and the deck
    /// keeps a cache of note bodies that was only ever refreshed for the one
    /// note on screen. Open the note afterwards and you are looking at what it
    /// said before. Quitting cleared the cache, which is why restarting
    /// "fixed" it.
    static func checkExternalWriteToClosedNote(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let record = deck.recordsForTesting.first else {
            check(false, "no note"); return
        }

        // Make sure it has been read once and is then put away — the state the
        // report describes.
        deck.fanOut(takingFocus: false)
        deck.previewForTesting(record.id)
        deck.closeNote()
        await deck.refresh()

        let stamp = Int(Date().timeIntervalSince1970)
        let addition = "escrito por el agente \(stamp)"
        let feed = FeedStore(folder: folder)
        guard let entry = try? feed.find(record.id) else {
            check(false, "the command cannot find the note"); return
        }

        // Leave the note's text ending in a newline — pressing Enter and
        // stopping, which is an ordinary thing to do. The file will not keep
        // that newline, so from here on the text on screen and the file
        // disagree by one character, permanently.
        deck.previewForTesting(record.id)
        deck.debugTypeIntoCard("\n")
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(700))
        deck.closeNote()
        await deck.refresh()

        var note = (try? feed.find(record.id))?.note ?? entry.note
        note.body = FeedEdit.appending(addition, to: note.body)
        _ = try? feed.write(note, to: entry.url)

        await deck.reconcileForTesting([record.filename])
        try? await Task.sleep(for: .milliseconds(800))

        // The index is the easy half — it reads the file.
        let stored = try? await deck.loadForTesting(id: record.id).body
        check(stored?.contains(addition) == true, "the store should know about it")

        // And a refresh with nothing to do must not schedule a save at all: a
        // save nobody asked for is a save that can land on top of somebody
        // else's write, which is how this reached the file in the first place.
        let settled = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? ""
        for _ in 0..<3 { await deck.refresh() }
        check(!deck.hasPendingSaveForTesting,
              "a refresh with nothing to do must not schedule a save")
        try? await Task.sleep(for: .milliseconds(700))
        let untouched = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? ""
        check(untouched == settled, "…and must not rewrite the file")

        // Opening it is the half that was broken.
        deck.previewForTesting(record.id)
        check(deck.debugCardBody()?.contains(addition) == true,
              "opening the note must show what was written to it while it was closed — "
              + "otherwise it takes a restart, which is what was reported")
        deck.closeNote()
    }

    /// Hovering a tab must not move the strip.
    ///
    /// Reported as tabs flickering when the pointer crosses between two of
    /// them. The flicker is the symptom of this: if opening a note shifts the
    /// stack, the tab under the pointer slides out from under it, the pointer
    /// lands on its neighbour, that one opens, the stack shifts back — and the
    /// two of them trade places for as long as you hold still.
    static func checkHoverDoesNotMoveTheStrip(deck: DeckController) async {
        await deck.refresh()
        let ids = deck.recordsForTesting.map(\.id)
        guard ids.count >= 2 else { check(false, "need two notes"); return }

        deck.fanOut(takingFocus: false)
        let fanned = deck.debugTabScreenFrames()
        check(!fanned.isEmpty, "no tabs to look at")

        deck.previewForTesting(ids[0])
        let firstOpen = deck.debugTabScreenFrames()
        check(fanned == firstOpen,
              "opening a note must leave every tab exactly where it was: "
              + "\(describe(fanned, firstOpen))")

        deck.previewForTesting(ids[1])
        let secondOpen = deck.debugTabScreenFrames()
        check(firstOpen == secondOpen,
              "and moving to the next note must not move them either — this is the "
              + "flicker: \(describe(firstOpen, secondOpen))")

        // The case that makes it worst: a note dragged to a size of its own, so
        // the panel has to be a different length for it than for its neighbour.
        // One note dragged as tall as the screen allows, its neighbour left
        // small. That is what makes the panel a different length for each, and
        // the panel is what the stack is positioned inside.
        try? await deck.setGeometryForTesting(id: ids[0], width: 520, height: 4000)
        try? await deck.setGeometryForTesting(id: ids[1], width: 320, height: 240)
        await deck.refresh()
        deck.previewForTesting(ids[1])
        let beforeBig = deck.debugTabScreenFrames()
        deck.previewForTesting(ids[0])
        let afterBig = deck.debugTabScreenFrames()
        // A tolerance here, not equality, and the reason is worth writing down:
        // there is a sub-pixel drift left when the two notes are wildly
        // different sizes, from rounding in the factor that shrinks tabs to fit
        // the screen. It is under a point, it is not what anyone reported, and
        // an attempt to anchor the stack to the screen instead made it worse —
        // so it is measured and left alone rather than chased.
        let drift = zip(beforeBig, afterBig).map { abs($0.minY - $1.minY) }.max() ?? 0
        check(drift <= 1.5,
              "opening notes of different sizes must not shift the strip visibly: "
              + String(format: "moved %.1f pt", drift))
        for id in ids.prefix(2) {
            try? await deck.setGeometryForTesting(id: id, width: nil, height: nil)
        }
        await deck.refresh()
        deck.closeNote()
    }

    private static func describe(_ a: [NSRect], _ b: [NSRect]) -> String {
        guard a.count == b.count else { return "\(a.count) tabs became \(b.count)" }
        let moved = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }
        guard let first = moved.first else { return "nothing moved" }
        return "\(moved.count) of \(a.count) moved, first by "
            + String(format: "%.1f pt", first.element.1.minY - first.element.0.minY)
    }

    /// What counts as pointing at a tab while a note is open.
    ///
    /// Two mistakes, one in each direction, and the checks below are the two
    /// halves of the line between them.
    ///
    /// The tabs are drawn above the open card. So a visible tab lying over the
    /// card is still a tab you are pointing at, and hovering it must work —
    /// ignoring the card's whole rectangle meant you had to walk almost to the
    /// far end of the next tab before the deck would answer. But the body of
    /// the card, where no tab is drawn, is the note you are reading, and a
    /// point there must not hover whatever the rectangles say is underneath.
    static func checkPointerAgainstAnOpenCard(deck: DeckController) async {
        // The check before this one scrolls, and a tab under the pointer does
        // not open while the wheel is still warm. That is the deck behaving as
        // designed; this check is about hovering, so it waits the window out
        // rather than measuring it.
        try? await Task.sleep(for: .milliseconds(Int(Motion.scrollQuiet * 1000) + 120))
        await deck.refresh()
        let ids = deck.recordsForTesting.map(\.id)
        guard ids.count >= 2 else { check(false, "need two notes"); return }

        deck.fanOut(takingFocus: false)
        deck.previewForTesting(ids[0])
        guard let card = deck.debugCardFrame() else { check(false, "no card"); return }

        let visible = zip(deck.recordsForTesting, deck.debugTabFramesForTesting)
            .filter { $0.0.id != ids[0] }

        // ---- the half that was reported: moving to the next tab must answer
        // where you first touch it, not at its far end.
        let port = deck.viewportFrame
        let reachable = visible.filter { port.contains($0.1) }
        guard let neighbour = reachable.first(where: { $0.1.intersects(card) }) ?? reachable.first else {
            check(false, "no neighbouring tab fully in view"); return
        }
        let near = NSPoint(x: neighbour.1.midX, y: neighbour.1.minY + neighbour.1.height * 0.12)
        deck.debugPointerInside(near)
        try? await Task.sleep(for: .milliseconds(700))
        check(deck.openNoteID == neighbour.0.id,
              "the near end of the next tab opens it — you should not have to travel "
              + "its whole length because the card happens to lie under it")

        // ---- the other half: the body of the card is not a tab.
        deck.previewForTesting(ids[0])
        guard let card = deck.debugCardFrame() else { check(false, "no card"); return }
        let bodyX = card.minX + card.width * 0.25          // well clear of the tab column
        let onBody = NSPoint(x: bodyX, y: card.midY)
        let coveringTab = deck.debugTabFramesForTesting.contains { $0.contains(onBody) }
        if coveringTab {
            check(false, "could not find a point on the card that no tab covers")
        } else {
            let before = deck.openNoteID
            deck.debugPointerInside(onBody)
            try? await Task.sleep(for: .milliseconds(700))
            check(deck.openNoteID == before,
                  "a point on the note you are reading must not open anything else")
        }
        deck.closeNote()
    }

    /// The marker offered on a selection.
    ///
    /// ⌘⇧H has wrapped a selection in `==` since the highlighter was built, and
    /// there was no way to find that out by using the app. What is checked here
    /// is that the affordance produces exactly what the shortcut does — the same
    /// characters in the file — and that reaching for it does not cost you the
    /// selection it acts on.
    static func checkHighlightBar() {
        func note(_ text: String, selection: NSRange) -> NoteTextView {
            let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.configureForNotes()
            view.string = text
            view.setSelectedRange(selection)
            return view
        }

        let view = note("resaltá estas palabras por favor", selection: NSRange(location: 0, length: 0))
        check(view.highlightBar.isHidden, "with nothing selected there is nothing to offer")

        let words = (view.string as NSString).range(of: "estas palabras")
        view.setSelectedRange(words)
        check(!view.highlightBar.isHidden, "selecting words offers the marker")

        // It must sit over the note, near the words, and inside the view.
        let bar = view.highlightBar.frame
        check(bar.minX >= 0 && bar.maxX <= view.bounds.width,
              "the marker stays inside the note: \(bar)")

        // Pressing it writes the same characters ⌘⇧H writes.
        view.highlightBar.onClick?()
        check(view.string == "resaltá ==estas palabras== por favor",
              "the marker writes the markup, not a colour: \(view.string.debugDescription)")

        let shortcut = note("resaltá estas palabras por favor", selection: words)
        MarkdownEditing.wrap(shortcut, with: "==")
        check(view.string == shortcut.string,
              "…exactly what ⌘⇧H produces, or a note would depend on how it was made")

        // And it takes it off again, which is what the shortcut does.
        view.highlightBar.onClick?()
        check(view.string == "resaltá estas palabras por favor",
              "pressing it again lifts the highlight: \(view.string.debugDescription)")

        // The selection has to survive the press, or you could not do it twice.
        check(view.selectedRange().length > 0, "the words stay selected after using it")

        // A click on it must not become a click in the text.
        check(!view.highlightBar.acceptsFirstResponder,
              "the marker must never take focus — that would drop the selection")

        // What it draws is the note's own pen, so the button and the result agree.
        view.setSelectedRange(words)
        view.highlighterPen = .systemPink
        view.updateHighlightBar()
        check(view.highlightBar.pen == .systemPink, "the swipe on the button is the note's own colour")

        // Collapsing the selection puts it away.
        view.setSelectedRange(NSRange(location: 3, length: 0))
        check(view.highlightBar.isHidden, "putting the caret down takes it away again")
    }

    /// A deck longer than the strip.
    ///
    /// Everything above assumes you can see the tab you are reaching for. Past
    /// a handful of notes you cannot, and what used to happen is that the rest
    /// were laid out below the bottom of the display: unreachable, at 34 pt
    /// each, with the plus button among them.
    static func checkScrollingDeck(deck: DeckController) async {
        await deck.refresh()
        let ids = deck.recordsForTesting.map(\.id)
        guard ids.count > 8 else {
            check(true, "this run has \(ids.count) notes; the crowded checks need more "
                  + "(LEDGE_SELFTEST_NOTES=n)")
            return
        }

        deck.fanOut(takingFocus: false)
        let extent = deck.scrollExtent
        check(extent.maximum > 0, "a deck this long has somewhere to scroll to")

        // The peek: at the top, the tab at the far edge is cut by the viewport
        // rather than by the screen. Half a tab is the whole announcement that
        // there is more.
        let port = deck.viewportFrame
        let straddling = deck.debugTabFramesForTesting.filter {
            $0.intersects(port) && $0.maxY > port.maxY + 0.5
        }
        check(!straddling.isEmpty,
              "a tab is cut by the end of the window, so you can see there is more")

        // It stops at both ends rather than running off.
        deck.scrollStack(by: -100_000)
        check(deck.scrollExtent.offset <= extent.maximum + 0.5,
              String(format: "scrolling stops at the end: %.0f of %.0f",
                     deck.scrollExtent.offset, extent.maximum))
        let atEnd = deck.debugTabFramesForTesting.last
        check(atEnd.map { $0.intersects(deck.viewportFrame) } == true,
              "and the last note is there when you arrive")

        deck.scrollStack(by: 100_000)
        check(deck.scrollExtent.offset >= -0.5 && deck.scrollExtent.offset < 1,
              String(format: "and at the start: %.1f", deck.scrollExtent.offset))
        check(deck.debugTabFramesForTesting.first.map { $0.intersects(deck.viewportFrame) } == true,
              "with the first note back in view")

        // Scrolling drags tabs under a pointer that has not moved. Opening
        // whatever goes past would make one flick open every note on the deck.
        deck.closeNote()
        deck.scrollStack(by: -200)
        // Wholly inside, not merely touching: the point used below is the
        // middle of the tab, and the middle of a half-clipped tab is outside
        // the window — which is a fact about this check, not about the deck.
        let arrivals = deck.debugTabFramesForTesting.enumerated()
            .first { deck.viewportFrame.contains($0.element) }
        if let arrivals {
            deck.debugPointerInside(NSPoint(x: arrivals.element.midX, y: arrivals.element.midY))
            try? await Task.sleep(for: .milliseconds(150))
            check(deck.openNoteID == nil,
                  "a tab dragged under the pointer by scrolling does not open itself")
            // …but it opens once the wheel has been still for a moment.
            try? await Task.sleep(for: .milliseconds(400))
            deck.debugPointerInside(NSPoint(x: arrivals.element.midX, y: arrivals.element.midY))
            try? await Task.sleep(for: .milliseconds(400))
            check(deck.openNoteID != nil, "…and opens normally once the scrolling has stopped")
            deck.closeNote()
        }

        // Opening a note off the end brings its tab back into view.
        deck.scrollStack(by: 100_000)
        if let last = ids.last {
            deck.previewForTesting(last)
            let tab = zip(deck.recordsForTesting, deck.debugTabFramesForTesting)
                .first { $0.0.id == last }?.1
            check(tab.map { $0.intersects(deck.viewportFrame) } == true,
                  "opening the last note scrolls its tab into view, so the card has "
                  + "something to grow out of")
            deck.closeNote()
        }

        // And the stripe at rest says "a few notes", not two hundred.
        check(PillView.shown(ids.count) <= PillView.mostDashes,
              "the resting stripe shows at most \(PillView.mostDashes) dashes, "
              + "not \(ids.count)")
    }

    /// The index of a note, and dropping things on the edge.
    static func checkOutlineAndDrops(deck: DeckController) async {
        // ---- the index
        let long = """
        # Primero

        algo

        ## Segundo

        ```bash
        # esto es un comentario, no un título
        echo hola
        ```

        ### Tercero
        """
        let record = NoteRecord(note: Note(title: "Largo"), filename: "l.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: long)
        card.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
        card.layoutSubtreeIfNeeded()

        check(card.debugOutlineOffered, "a note with headings offers its index")
        let listed = Headings.all(in: long).map(\.text)
        check(listed == ["Primero", "Segundo", "Tercero"],
              "the index is the note's headings, and a comment in a code block is not "
              + "one of them: \(listed)")

        // Beside the button that opens the full editor, level with it and not
        // overlapping it: two icons in a row, not a word next to a picture.
        let icon = card.debugOutlineButtonFrame, expand = card.debugExpandButtonFrame
        check(icon.maxX <= expand.minX + 0.5,
              String(format: "the index icon sits before the expand icon (%.0f then %.0f)",
                     icon.maxX, expand.minX))
        check(abs(icon.midY - expand.midY) < 0.5, "level with it")
        check(abs(icon.width - expand.width) < 0.5, "and the same size")
        check(card.debugTitleFrame.maxX <= icon.minX + 0.5,
              "the title stops before the icons rather than running under them")

        let plain = NoteCardView(record: record, body: "una nota corriente\nsin títulos")
        plain.frame = card.frame
        plain.layoutSubtreeIfNeeded()
        check(!plain.debugOutlineOffered,
              "an ordinary note carries no extra chrome for an index it has no use for")

        let one = NoteCardView(record: record, body: "# un solo título\ntexto")
        one.frame = card.frame
        one.layoutSubtreeIfNeeded()
        check(!one.debugOutlineOffered, "one heading is not somewhere to jump between")
        check(plain.debugTitleFrame.width > card.debugTitleFrame.width,
              "and a note without an index gives that room back to its title")

        // Opening it and picking a heading moves the caret there, and changes
        // nothing: an index that edited the note would be a second writer.
        let before = card.textView.string
        card.debugOpenOutline()
        check(card.debugOutlineVisible, "the index opens")
        guard let third = Headings.all(in: long).last else { check(false, "no headings"); return }
        card.debugPickOutline(third)
        check(card.textView.string == before, "picking a heading writes nothing")
        check(card.textView.selectedRange().location == third.line.location,
              "…and puts the caret on it")
        check(!card.debugOutlineVisible, "and the index closes behind you")

        // ---- an index longer than the room for it
        let many = (1...24).map { "## Sección \($0)\n\ntexto\n" }.joined()
        let big = NoteCardView(record: record, body: "# Cabeza\n\n" + many)
        big.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
        big.layoutSubtreeIfNeeded()
        big.debugOpenOutline()
        big.layoutSubtreeIfNeeded()
        let list = big.debugOutline
        check(list.scrollRoom > 0,
              String(format: "an index of 25 headings has somewhere to scroll (%.0f pt)",
                     list.scrollRoom))

        // The rows and the hit testing move together, or you scroll to a
        // heading and clicking it takes you to a different one.
        let row = NSPoint(x: list.bounds.midX, y: list.bounds.midY)
        let atTop = big.debugOutlineHit(at: row)
        list.scroll(by: -list.bounds.height)
        big.layoutSubtreeIfNeeded()
        list.displayIfNeeded()
        let after = big.debugOutlineHit(at: row)
        check(atTop != nil && after != nil && atTop != after,
              "scrolling changes which heading is under a given point: "
              + "\(atTop.map(String.init) ?? "none") then \(after.map(String.init) ?? "none")")

        // And it stops at both ends rather than running off.
        list.scroll(by: -100_000)
        list.displayIfNeeded()
        check(abs(list.scrollOffset - list.scrollRoom) < 0.5,
              String(format: "the index stops at its end: %.0f of %.0f",
                     list.scrollOffset, list.scrollRoom))
        list.scroll(by: 100_000)
        list.displayIfNeeded()
        check(list.scrollOffset < 0.5, "and at its start")
        check(big.debugOutlineHit(at: row) == atTop, "…with the same heading back under the pointer")

        // A short index does not scroll at all. Opened and laid out first: a
        // panel that has never been given a size has no room for anything.
        card.debugOpenOutline()
        card.layoutSubtreeIfNeeded()
        check(card.debugOutline.scrollRoom == 0,
              String(format: "an index that fits has nowhere to scroll (%.0f pt of room)",
                     card.debugOutline.scrollRoom))

        // ---- dropping on the edge
        let board = NSPasteboard(name: NSPasteboard.Name("ledge.selftest.drop"))
        board.clearContents()
        board.setString("una selección arrastrada", forType: .string)
        check(DeckRootView.droppable.contains(.string) && DeckRootView.droppable.contains(.fileURL),
              "the strip takes a selection and a file")

        let before2 = deck.recordsForTesting.count
        deck.debugDrop("texto soltado en el borde \(Int(Date().timeIntervalSince1970))")
        try? await Task.sleep(for: .milliseconds(900))
        await deck.refresh()
        check(deck.recordsForTesting.count == before2 + 1,
              "dropping text on the edge makes a note")

        // And it goes through the same reading as a paste, so a dropped
        // manifest is fenced rather than turned into headings and bullets.
        deck.debugDrop("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: caido")
        try? await Task.sleep(for: .milliseconds(900))
        await deck.refresh()
        let dropped = deck.recordsForTesting.first { $0.title == "Deployment/caido" }
        check(dropped != nil,
              "a dropped manifest is read as code, like a pasted one: titles are "
              + "\(deck.recordsForTesting.map(\.title).prefix(4))")
    }

    /// A table, drawn over the text that defines it.
    ///
    /// The file has to keep saying pipes and dashes: whatever is on screen, the
    /// note is still Markdown, and a table made here has to be the same file as
    /// one typed by hand or written by the command.
    static func checkDrawnTables() {
        let note = """
        Antes de la tabla.

        | Concepto | Primitiva IDP | Notas de implementación |
        |---|---|---|
        | Servicio **Bedrock Inference** | `service_specification` tipo `dependency` | dimensiones y acciones |
        | Link **Invoke** | `link_specification` con `assignable_to` | el único vínculo que el dev ve |

        Después de la tabla.
        """
        let record = NoteRecord(note: Note(title: "Con tabla"), filename: "t.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: note)
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 460)
        card.layoutSubtreeIfNeeded()
        let view = card.textView

        check(view.string == note, "drawing a table changes not one character of the note")
        check(view.debugTableCount == 1, "one table, one drawing: \(view.debugTableCount)")

        guard let drawn = view.debugTableView else { check(false, "no table view"); return }
        check(drawn.contentSize.height > 0 && drawn.contentSize.width > 0,
              "the drawing has a size")

        // Where it lands, which is the half that matters and the half the first
        // version of these checks left out: the attributes were right, the
        // drawing had a size, and 81% of a real document went invisible with
        // nothing over it.
        let frame = drawn.frame
        check(frame.width > 40 && frame.height > 20,
              String(format: "the drawing has a frame, not a point (%.0f×%.0f)",
                     frame.width, frame.height))
        check(abs(frame.height - drawn.contentSize.height) < 3,
              String(format: "as tall as what it draws (%.0f vs %.0f)",
                     frame.height, drawn.contentSize.height))
        check(frame.minY >= 0 && frame.minY < view.bounds.height,
              String(format: "and somewhere you can see (y = %.0f in %.0f)",
                     frame.minY, view.bounds.height))
        check(!drawn.isHidden && drawn.superview === view, "…and on screen")

        // The room is reserved by the text underneath, so the note lays out
        // around the table rather than the table covering what follows.
        guard let storage = view.textStorage,
              let table = Tables.all(in: note).first else { check(false, "no table"); return }
        let colour = storage.attribute(.foregroundColor, at: table.range.location,
                                       effectiveRange: nil) as? NSColor
        check(colour?.alphaComponent == 0,
              "the pipes are invisible rather than deleted — they are still in the file")
        let style = storage.attribute(.paragraphStyle, at: table.range.location,
                                      effectiveRange: nil) as? NSParagraphStyle
        let lines = CGFloat((note as NSString).substring(with: table.range)
            .components(separatedBy: "\n").count)
        let reserved = (style?.minimumLineHeight ?? 0) * lines
        check(abs(reserved - drawn.contentSize.height) < 2,
              String(format: "the hidden text reserves the drawing's height (%.0f vs %.0f)",
                     reserved, drawn.contentSize.height))
        check(style?.lineBreakMode == .byClipping,
              "and does not wrap, or the count of lines stops matching the room taken")

        // Locked: a click is not an edit.
        check(!view.isTableUnlocked(table), "a table starts locked")
        view.unlockTable(containing: table.range.location)
        check(view.isTableUnlocked(table), "unlocking it says so")
        check(view.debugTableCount == 0, "…and the drawing goes away, leaving the text")
        if let storage = view.textStorage {
            let after = storage.attribute(.foregroundColor, at: table.range.location,
                                          effectiveRange: nil) as? NSColor
            check((after?.alphaComponent ?? 0) > 0.5,
                  "the pipes are visible again, which is the point of unlocking")
        }
        // …and there has to be a way back, or unlocking is a door that only
        // opens: the padlock that closes a table is drawn on the drawing.
        check(view.debugLockMarkVisible,
              "an unlocked table shows the mark that puts it back")
        let mark = view.debugLockMarkFrame
        check(mark.width > 8 && mark.minY >= 0 && mark.maxX <= view.bounds.width + 1,
              String(format: "…somewhere you can press it (%.0f, %.0f)", mark.minX, mark.minY))
        view.debugPressLockMark()
        check(view.debugTableCount == 1, "pressing it draws the table again")
        check(!view.debugLockMarkVisible, "and the mark goes away with the raw text")

        view.lockTables()
        check(view.debugTableCount == 1, "and locking it draws it again")

        // ---- a real document, rather than a table written to pass this
        //
        // Cut from the one this was built against: two tables of three columns
        // of sentences, with bold and backticks in the cells, and prose around
        // them. It is written out here rather than read from disk — a check
        // that quietly skips itself when a file is missing is a check that does
        // not run in CI, which is the only place it would have caught anything.
        let real = """
        # Bedrock en el IDP

        - **Card**: PLATSD-1946 (Story) + subtareas
        - **Estado**: borrador para discusión

        ## 2. Mapeo del diseño a primitivas reales

        | Concepto en la propuesta | Primitiva IDP | Notas de implementación |
        |---|---|---|
        | Servicio **Bedrock Inference** | `service_specification` tipo `dependency` | `dimensions`: `country` + `environment`. |
        | Servicio **Guardrail Overlay** | `service_specification`, disponibilizado solo en seguridad | Sin links. Se referencia desde el form. |
        | Link **Invoke** (Inference → Scope) | `link_specification` con `assignable_to: "scope"` | El único vínculo que el dev ve como tal. |

        Texto entre las dos tablas, que tiene que seguir siendo visible.

        ## 5. Propuesta de implementación

        | Componente | Estrategia | Detalle |
        |---|---|---|
        | **Guardrail Overlay** | Estrategia 1 — Terraform Puro | TF crea `aws_bedrock_guardrail` + versión. |
        | **Bedrock Inference** | Estrategia 7 — Multi-Stage | Stage 1: resolver la instancia por NP API. |

        Y texto después.
        """
        do {
            let big = NoteCardView(record: record, body: real)
            big.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
            big.layoutSubtreeIfNeeded()
            let text = big.textView

            check(text.debugTableCount == 2,
                  "both tables in the document are drawn: \(text.debugTableCount)")
            check(text.debugTableFrames.allSatisfy { $0.width > 40 && $0.height > 20 },
                  "each with a frame you could see: \(text.debugTableFrames.map { Int($0.width) })")

            // The invariant the report was about: nothing is hidden without
            // something drawn in its place.
            let hidden = text.debugHiddenRuns.reduce(0) { $0 + $1.length }
            let tabled = Tables.all(in: real).reduce(0) { $0 + $1.range.length }
            check(hidden <= tabled,
                  "only tables are made invisible — \(hidden) characters hidden, "
                  + "\(tabled) of table")
            let covered = text.debugHiddenRuns.allSatisfy { run in
                Tables.all(in: real).contains { NSIntersectionRange($0.range, run).length > 0 }
            }
            check(covered, "and every hidden run belongs to a table that is drawn over it")
        }

        // A table wider than the note scrolls sideways rather than being cut.
        let heads: String = (1...8).map { "Columna con un título largo \($0)" }.joined(separator: " | ")
        let cells: String = (1...8).map { "celda \($0)" }.joined(separator: " | ")
        let rule: String = "|" + String(repeating: "---|", count: 8)
        let wide: String = "| " + heads + " |\n" + rule + "\n| " + cells + " |"
        let wideCard = NoteCardView(record: record, body: wide)
        wideCard.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        wideCard.layoutSubtreeIfNeeded()
        guard let wideView = wideCard.textView.debugTableView else {
            check(false, "no wide table"); return
        }
        check(wideView.scrollRoom > 0,
              String(format: "a table wider than the note has somewhere to scroll (%.0f pt)",
                     wideView.scrollRoom))
        // At the start: more to the right, nothing to the left. The gesture
        // works — two fingers sideways, or shift and the wheel — but nobody
        // would guess it was there without the edge saying so.
        check(wideView.showsMoreToTheRight && !wideView.showsMoreToTheLeft,
              "a table with more to the right says so at its edge, and says nothing "
              + "at the edge it starts from")

        wideView.debugScroll(by: -100_000)
        check(abs(wideView.scrollOffset - wideView.scrollRoom) < 0.5,
              "and it stops at the far edge rather than running off")
        check(wideView.showsMoreToTheLeft && !wideView.showsMoreToTheRight,
              "at the far end the cue is on the other side")

        wideView.debugScroll(by: 100_000)
        check(wideView.scrollOffset < 0.5, "and comes back to the first column")

        // A table that fits says nothing, because there is nowhere to go.
        let narrowCard = NoteCardView(record: record, body: "| a | b |\n|---|---|\n| 1 | 2 |")
        narrowCard.frame = NSRect(x: 0, y: 0, width: 460, height: 240)
        narrowCard.layoutSubtreeIfNeeded()
        if let narrow = narrowCard.textView.debugTableView {
            check(narrow.scrollRoom == 0 && !narrow.showsMoreToTheRight,
                  String(format: "a table that fits shows no cue (%.0f pt of room)",
                         narrow.scrollRoom))
        }
    }

    /// Notes something else is writing to.
    ///
    /// The point of the whole feature is that this happens while you are doing
    /// something else, so what is checked is that it does *not* disturb what you
    /// are doing: same tab views, no teardown, and a mark small enough to ignore.
    static func checkFeeds(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let first = deck.recordsForTesting.first else {
            check(false, "no note to put on a feed"); return
        }
        let before = deck.tabsForTesting
        guard !before.isEmpty else { check(false, "no tabs"); return }

        // An agent writes to the note: the file changes, the deck refreshes.
        let url = folder.appendingPathComponent(first.filename)
        var note = Frontmatter.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "",
                                     fallbackTitle: "", fallbackID: first.id)
        note.feed = "self-test"
        note.body = FeedEdit.appending("una entrada del agente", to: note.body)
        note.updated = Date().addingTimeInterval(5)
        try? Frontmatter.serialize(note).write(to: url, atomically: true, encoding: .utf8)

        // Exactly what the folder watcher does when something else writes.
        await deck.reconcileForTesting([first.filename])
        let after = deck.tabsForTesting
        check(after.count == before.count, "the deck still has the same number of tabs")
        check(zip(before, after).allSatisfy { $0 === $1 },
              "a note changing must reuse its tab view — rebuilding tears down the view "
              + "under the pointer, which is what used to close the deck mid-click")
        check(after.first?.record.feed == "self-test", "…and the tab knows about the feed")
        check(after.first?.hasUnseen == true, "a note written to since you looked is unseen")

        // Looking at it is what clears the mark.
        deck.fanOut(takingFocus: false)
        deck.previewForTesting(first.id)
        check(deck.tabsForTesting.first?.hasUnseen == false, "opening the note clears the mark")
        await deck.refresh()
        check(deck.tabsForTesting.first?.hasUnseen == false, "…and it stays cleared across a refresh")

        // The dot itself, read off the pixels.
        func ink(_ tab: NoteTabView) -> [UInt8] {
            tab.frame = NSRect(x: 0, y: 0, width: 40, height: 120)
            guard let rep = tab.bitmapImageRepForCachingDisplay(in: tab.bounds) else { return [] }
            tab.cacheDisplay(in: tab.bounds, to: rep)
            guard let data = rep.bitmapData else { return [] }
            return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
        }
        // The same note three ways. It has to be the same *id*: the paper tint
        // is jittered from it, so three separate notes differ by more than the
        // mark and the comparison would be measuring the wrong thing.
        let base = Note(title: "sin feed")
        var connected = base
        connected.feed = "agent"
        func tab(_ note: Note) -> NoteTabView {
            NoteTabView(record: NoteRecord(note: note, filename: "a.md",
                                           mtime: 0, size: 0, hash: ""))
        }
        let plain = tab(base), quiet = tab(connected), loud = tab(connected)
        loud.hasUnseen = true

        // How far each one departs from a tab with no mark at all. Summing the
        // raw channel would depend on which channel and which way ink moves it;
        // the distance from the unmarked tab does not.
        func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
            guard a.count == b.count else { return -1 }
            return zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        let none = ink(plain), ring = ink(quiet), filled = ink(loud)
        let ringInk = distance(ring, none), filledInk = distance(filled, none)
        check(ringInk > 0, "a note on a feed is marked and one without is not")
        check(filledInk > ringInk,
              "a filled dot must lay down more ink than a hollow one: ring \(ringInk), filled \(filledInk)")

        // The self test's own ids should not linger in your preferences.
        Settings.forgetSeen(keeping: [])
    }

    /// The editor writes through the same debounced path as the cards. This
    /// drives it end to end and then reads the file back off disk.
    static func checkSaving(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let record = deck.recordsForTesting.first else {
            check(false, "no note to edit"); return
        }
        let marker = "edited by the self test \(Int(Date().timeIntervalSince1970))"
        deck.debugEdit(id: record.id, body: marker)

        // longer than the 250 ms debounce
        try? await Task.sleep(for: .milliseconds(1500))

        let url = folder.appendingPathComponent(record.filename)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(text.contains(marker),
              "an edit reaches the .md file on disk within the debounce")
        check(text.hasPrefix("---"), "the file still has its frontmatter after an edit")
        check(text.contains("id: \(record.id)"), "the note kept its identity through the edit")

        // ---- the editor as the app actually opens it, not a stand-in
        deck.fanOut(takingFocus: false)
        deck.debugPreviewFirst()
        deck.expand(record.id)
        if let real = deck.debugEditor(record.id) {
            let typed = "typed into the real editor \(Int(Date().timeIntervalSince1970))"
            real.textView.selectAll(nil)
            real.textView.insertText(typed, replacementRange: real.textView.selectedRange())
            try? await Task.sleep(for: .milliseconds(1500))

            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check(text.contains(typed),
                  "an edit in the editor the app opens reaches the file")
            check(deck.debugCardBody() == real.textView.string,
                  "…and the small card follows along live")

            // The failure this really guards against: the card holding stale
            // text and overwriting the editor's work the moment it is touched.
            deck.debugTypeIntoCard(" and then in the card")
            try? await Task.sleep(for: .milliseconds(1500))
            let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check(after.contains(typed),
                  "typing in the card afterwards does not throw away what the editor wrote")
            check(after.contains("and then in the card"), "…and keeps the new text too")
            check(real.textView.string == deck.debugCardBody(),
                  "the editor follows the card as well, not only the other way round")

            real.close()
        } else {
            check(false, "expand() actually opens an editor")
        }
        deck.collapse()

        // ---- and the same trip through a stand-in window
        var reachedController = false
        let editor = NoteEditorWindow(record: record, title: record.displayTitle, body: marker)
        editor.onEdit = { text in
            reachedController = true
            deck.debugEdit(id: record.id, body: text)
        }
        let typed = marker + "\ntyped into the editor"
        editor.textView.selectAll(nil)
        editor.textView.insertText(typed, replacementRange: editor.textView.selectedRange())

        check(reachedController, "typing in the editor reaches the controller at all")
        check(editor.textView.isEditable, "the editor's text view accepts typing")

        try? await Task.sleep(for: .milliseconds(1500))
        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(after.contains("typed into the editor"),
              "an edit made in the editor window reaches the file")
    }

    /// A tab's title is small bold text on a pastel. If any of these pairs is
    /// short of 4.5:1 the deck is pretty and unreadable.
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent)
                 + 0.7152 * channel(c.greenComponent)
                 + 0.0722 * channel(c.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func checkContrast() {
        func luminance(_ color: NSColor) -> Double {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent)
                 + 0.7152 * channel(c.greenComponent)
                 + 0.0722 * channel(c.blueComponent)
        }
        func ratio(_ a: NSColor, _ b: NSColor) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }

        for color in NoteColor.allCases {
            let onPaper = ratio(Palette.labelInk(color), Palette.paper(color, dark: false))
            check(onPaper >= 4.5,
                  String(format: "%@ label on its paper reads at %.1f:1", color.rawValue, onPaper))
            let bodyLight = ratio(Palette.ink(dark: false), Palette.paper(color, dark: false))
            let bodyDark = ratio(Palette.ink(dark: true), Palette.paper(color, dark: true))
            check(bodyLight >= 7 && bodyDark >= 7,
                  String(format: "%@ body text reads at %.1f:1 light, %.1f:1 dark",
                         color.rawValue, bodyLight, bodyDark))
        }
    }

    /// A label must land inside the rectangle it was handed — including a
    /// rectangle that does not start at the origin, which is every band on a
    /// bottom card.
    static func checkLabelPlacement() {
        let size = Metrics.Tab.labelSize
        let inset = Metrics.Tab.labelInset

        let atOrigin = NSRect(x: 0, y: 0, width: 40, height: 140)
        let vertical = VerticalLabel.box(for: "GROCERIES", in: atOrigin, inset: inset, size: size)
        check(atOrigin.insetBy(dx: -0.5, dy: -0.5).contains(vertical),
              "a vertical title sits inside its tab")

        // the band along the bottom of a horizontal card
        let band = NSRect(x: 0, y: 310, width: 300, height: 30)
        let horizontal = VerticalLabel.horizontalBox(for: "GROCERIES", in: band,
                                                     inset: inset, size: size)
        check(band.insetBy(dx: -0.5, dy: -0.5).contains(horizontal),
              String(format: "a horizontal title sits inside its band, not elsewhere on the card "
                     + "(y %.0f, band %.0f–%.0f)", horizontal.minY, band.minY, band.maxY))

        // and an offset vertical band, as on a mirrored card
        let offsetBand = NSRect(x: 270, y: 0, width: 30, height: 340)
        let mirrored = VerticalLabel.box(for: "GROCERIES", in: offsetBand, inset: inset, size: size)
        check(offsetBand.insetBy(dx: -0.5, dy: -0.5).contains(mirrored),
              "a mirrored title sits inside its band too")
    }

    /// Renders a card and counts the ink.
    ///
    /// Every earlier check on this asked whether the *colours* were right, and
    /// the report from a real Mac was that the caret moved over nothing at all.
    /// Colours being right is not the requirement. The requirement is that
    /// characters appear, so this looks at pixels.
    static func checkTextRenders() {
        for (name, appearance) in [("light", NSAppearance(named: .aqua)),
                                   ("dark", NSAppearance(named: .darkAqua))] {
            var note = Note(title: "Groceries", color: .green)
            note.body = "- apple\n- 4x banana\n- dry fruits\n- peanuts"
            let record = NoteRecord(note: note, filename: "Groceries.md",
                                    mtime: 0, size: 0, hash: "")

            let card = NoteCardView(record: record, body: note.body)
            card.appearance = appearance
            card.frame = NSRect(x: 0, y: 0, width: 340, height: 260)
            card.layoutSubtreeIfNeeded()
            card.applyColors()
            card.layoutSubtreeIfNeeded()
            card.displayIfNeeded()

            guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
                check(false, "the card could not be rendered"); continue
            }
            card.cacheDisplay(in: card.bounds, to: rep)

            let paper = Palette.paper(.green, dark: appearance == NSAppearance(named: .darkAqua),
                                      tint: Jitter(id: record.id).paperTint)
            // the body area: past the coloured strip, below the title, above the chrome
            var ink = 0
            for x in stride(from: 60, to: 320, by: 2) {
                for y in stride(from: 55, to: 200, by: 2) {
                    guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                    if !pixel.isCloseTo(paper, tolerance: 0.10) { ink += 1 }
                }
            }
            check(ink > 200,
                  "a note's text is actually drawn in \(name) — \(ink) ink pixels "
                  + "(the caret moving over nothing is what this exists to catch)")
        }
    }

    static func run(deck: DeckController) async {
        print("\n\u{001B}[1mContrast\u{001B}[0m")
        checkContrast()
        checkTextRenders()

        print("\n\u{001B}[1mMarkdown\u{001B}[0m")
        checkMarkdown()
        checkFormattingStaysOnItsLine()
        checkHighlightReadsOnPaper()
        checkScopedHighlighting()
        checkFind()
        checkMarkdownEditing()
        checkPastedCode()
        checkStaleHighlightRange()
        checkProgressTick()
        checkHighlightBar()
        checkDrawnTables()
        checkZoomKeys()
        checkShortcuts()
        checkCodeCopy()
        checkCodeFormatting()
        checkChromeDegradation()
        checkPressAndSettle()

        print("\n\u{001B}[1mLabel rendering\u{001B}[0m")
        checkLabelDirection()
        checkLabelPlacement()

        print("\n\u{001B}[1mSaving\u{001B}[0m")
        await checkSaving(deck: deck, folder: deck.notesFolder)
        await checkFeeds(deck: deck, folder: deck.notesFolder)
        await checkTypingDoesNotDuplicate(deck: deck, folder: deck.notesFolder)
        await checkExternalWriteToClosedNote(deck: deck, folder: deck.notesFolder)
        await checkZoomWithNoteOpen(deck: deck)
        await checkHoverDoesNotMoveTheStrip(deck: deck)
        await checkScrollingDeck(deck: deck)
        await checkPointerAgainstAnOpenCard(deck: deck)
        await checkConcurrentWriters(deck: deck, folder: deck.notesFolder)

        let saved = (zoom: Settings.zoom, tab: Settings.tabScale, card: Settings.cardScale)
        defer {
            Settings.zoom = saved.zoom
            Settings.tabScale = saved.tab
            Settings.cardScale = saved.card
        }

        let combinations: [(name: String, zoom: CGFloat, tab: CGFloat, card: CGFloat)] = [
            ("default",            1.00, 1.00, 1.00),
            ("smallest offered",   0.80, 0.85, 0.85),
            ("largest offered",    1.75, 1.45, 1.45),
            ("big tabs, small card", 1.00, 1.45, 0.85),
            ("small tabs, big card", 1.15, 0.85, 1.45),
        ]

        // The checks must not read the user's saved layout: a strip they left
        // pinned would keep the deck fanned and fail every "starts at rest".
        guard !NSScreen.screens.isEmpty else {
            print("\n\u{001B}[33mno display available — geometry checks skipped\u{001B}[0m")
            summarise()
            return
        }

        let savedStrips = Settings.strips
        let savedStrip = deck.strip
        defer {
            Settings.strips = savedStrips
            deck.strip = savedStrip
        }
        deck.strip = StripConfig(id: StripConfig.primaryID, name: "Deck", edge: .right,
                                 screenID: NSScreen.screens.first?.ledgeDisplayID ?? 0,
                                 offset: 0, pinned: false)

        for combination in combinations {
            Settings.zoom = combination.zoom
            Settings.tabScale = combination.tab
            Settings.cardScale = combination.card
            deck.collapse()
            print("\n\u{001B}[1mDeck geometry — \(combination.name)"
                  + " (\(Int(combination.zoom * 100))% · tabs \(Int(combination.tab * 100))%"
                  + " · card \(Int(combination.card * 100))%)\u{001B}[0m")
            await checkGeometry(deck: deck)
        }

        // ---- and the whole thing again, mirrored onto a left edge
        Settings.zoom = 1; Settings.tabScale = 1; Settings.cardScale = 1
        if let screen = NSScreen.screens.first {
            // pinned: false explicitly — these checks are about folding away,
            // and pinning is the default now.
            deck.strip = StripConfig(id: StripConfig.primaryID, name: "Deck", edge: .left,
                                     screenID: screen.ledgeDisplayID, offset: 0, pinned: false)
            deck.collapse()
            print("\n\u{001B}[1mDeck geometry — mirrored onto the left edge\u{001B}[0m")
            await checkGeometry(deck: deck, mirrored: true)
            deck.strip = StripConfig.primary()
        }

        // ---- a dragged note has to be able to reach every strip
        print("\n\u{001B}[1mDrag reach\u{001B}[0m")
        checkDragReach()

        // ---- moving a note from one strip to another
        print("\n\u{001B}[1mMoving notes between strips\u{001B}[0m")
        await checkStripHandover(deck: deck)

        // ---- strips that follow an app
        print("\n\u{001B}[1mStrips that follow an app\u{001B}[0m")
        checkFollowing()

        // ---- the fan has to come from the edge the strip is on, whichever it is
        if let screen = NSScreen.screens.first {
            print("\n\u{001B}[1mFan direction\u{001B}[0m")
            await checkFanDirection(deck: deck, screen: screen)
        }

        // ---- and along the bottom, where the axes swap over
        if let screen = NSScreen.screens.first {
            print("\n\u{001B}[1mDeck geometry — along the bottom edge\u{001B}[0m")
            await checkBottomStrip(deck: deck, screen: screen)
        // Last: it makes notes, and every check above reads the first one.
        await checkOutlineAndDrops(deck: deck)
            deck.strip = StripConfig.primary()
        }

        summarise()
    }

    /// The clamp that keeps a dragged note on screen must not also fence it out
    /// of the Dock's band, where a bottom strip lives.
    static func checkDragReach() {
        guard let screen = NSScreen.screens.first else { return }
        let size = NSSize(width: 300, height: 340)
        let room = FloatingNote.shadowRoom

        // dragged hard against the bottom of the screen
        let low = FloatingNote.clamped(
            origin: NSPoint(x: screen.frame.midX, y: screen.frame.minY - 500),
            panelSize: size, screen: screen)
        check(low.y <= screen.frame.minY - room + 0.5,
              "a note can be dragged all the way to the bottom of the screen")
        check(low.y + room <= screen.visibleFrame.minY,
              "…which means past the top of the Dock's band, "
              + String(format: "where a bottom strip lives (%.0f vs %.0f)",
                       low.y + room, screen.visibleFrame.minY))

        // dragged up into the menu bar
        let high = FloatingNote.clamped(
            origin: NSPoint(x: screen.frame.midX, y: screen.frame.maxY + 500),
            panelSize: size, screen: screen)
        check(high.y + size.height <= screen.visibleFrame.maxY + 0.5,
              "but it is still kept out of the menu bar, where it would be lost")

        // and out to the sides
        let right = FloatingNote.clamped(
            origin: NSPoint(x: screen.frame.maxX + 900, y: screen.frame.midY),
            panelSize: size, screen: screen)
        check(right.x + size.width - room <= screen.frame.maxX + 0.5,
              "it cannot be pushed off the right of the screen")
        check(right.x + size.width >= screen.frame.maxX - 1,
              "…but it can reach the right edge, where a strip is")

        check(DeckPanel.aboveDock.rawValue > Int(CGWindowLevelForKey(.dockWindow)),
              "a bottom strip is layered above the Dock, not behind it")
        check(DeckPanel.aboveDock.rawValue < Int(CGWindowLevelForKey(.mainMenuWindow)),
              "…and still below the menu bar")
    }

    /// Dropping a note near a strip has to pick *that* strip — measured against
    /// where the strip actually is, not against the edge of its screen. A strip
    /// parked to the left of the Dock must not claim a note dropped at the far
    /// right of the same edge.
    private static func checkStripHandover(deck: DeckController) async {
        guard let screen = NSScreen.screens.first else { return }
        let workspace = deck.workspace
        let saved = Settings.strips

        Settings.strips = [
            StripConfig(id: StripConfig.primaryID, name: "Deck", edge: .right,
                        screenID: screen.ledgeDisplayID, offset: 0, pinned: true),
            StripConfig(id: "test-left", name: "Left", edge: .left,
                        screenID: screen.ledgeDisplayID, offset: 0, pinned: true),
            StripConfig(id: "test-bottom", name: "Bottom", edge: .bottom,
                        screenID: screen.ledgeDisplayID, offset: -0.5, pinned: true),
        ]
        workspace.rebuildDecks()
        try? await Task.sleep(for: .milliseconds(400))

        check(workspace.decks.count == 3, "three strips exist at once (\(workspace.decks.count))")
        check(workspace.stripChoices.count == 3, "and all three are offered as destinations")

        for target in workspace.decks {
            let dock = target.dockingRect
            check(dock.width > 0 && dock.height > 0,
                  "the \(target.strip.name) strip has a real docking area")
            // the pointer let go right over that strip
            let chosen = workspace.strip(near: NSPoint(x: dock.midX, y: dock.midY))
            check(chosen?.id == target.strip.id,
                  "a note dropped on the \(target.strip.name) strip goes to that one, "
                  + "not \(chosen?.name ?? "nowhere")")
        }

        // ---- the case that sent notes back where they came from: a card wide
        // enough to still be touching the strip it was dragged off, while the
        // pointer is clearly over another one.
        if let source = workspace.decks.first(where: { $0.strip.edge == .right }),
           let destination = workspace.decks.first(where: { $0.strip.edge == .bottom }) {
            let pointer = NSPoint(x: destination.dockingRect.midX,
                                  y: destination.dockingRect.midY)
            // where a 300 pt card would sit under that pointer — still overlapping
            // the right-hand strip it came from
            let card = NSRect(x: pointer.x - 60, y: pointer.y - 40, width: 300, height: 340)
            let touchesSource = card.ledgeDistance(to: source.dockingRect) < FloatingNote.snapDistance

            let chosen = workspace.strip(near: pointer)
            check(chosen?.id == destination.strip.id,
                  "a note aimed at the bottom strip lands there"
                  + (touchesSource ? " even though the card still overlaps the strip it left" : ""))
        }

        // and a note dropped in open space belongs to no strip at all
        let middle = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        check(workspace.strip(near: middle) == nil,
              "a note left in the middle of the screen stays floating")

        // the far end of the bottom edge must not be claimed by a strip parked
        // at the near end of it
        if let bottom = workspace.decks.first(where: { $0.strip.edge == .bottom }) {
            let farEnd = NSPoint(x: screen.frame.maxX - 80, y: screen.frame.minY + 20)
            let chosen = workspace.strip(near: farEnd)
            check(chosen?.id != bottom.strip.id || bottom.dockingRect.maxX > screen.frame.maxX - 200,
                  "a strip parked at one end of the bottom edge does not claim the other end")
        }

        // ---- an edit and a move must not race each other
        if let record = deck.recordsForTesting.first,
           let bottom = workspace.stripChoices.first(where: { $0.edge == .bottom }) {
            let marker = "typed just before the move \(Int(Date().timeIntervalSince1970))"
            deck.debugEdit(id: record.id, body: marker)
            deck.debugMoveWithPendingEdit(id: record.id, to: bottom)
            try? await Task.sleep(for: .milliseconds(1500))

            let url = deck.notesFolder.appendingPathComponent(record.filename)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check(text.contains(marker),
                  "an edit made just before a move is not lost by the move")
            check(text.contains("strip: \(bottom.id)"),
                  "…and the move is not lost by the edit, either")
        }

        Settings.strips = saved
        workspace.rebuildDecks()
        // rebuildDecks brings home anything left on the temporary strips
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// A strip told to follow an app has to answer for that app and stay out of
    /// the way otherwise — including keeping its hands off strips that were
    /// never given a rule.
    static func checkFollowing() {
        var plain = StripConfig.primary()
        check(plain.wantsToShow(whenFrontmost: "com.apple.dt.Xcode") == nil,
              "a strip with no rule never answers — it stays however you left it")
        check(plain.wantsToShow(whenFrontmost: nil) == nil,
              "…not even when nothing is in front")

        plain.showsWith = ["com.apple.dt.Xcode", "com.apple.Terminal"]
        check(plain.wantsToShow(whenFrontmost: "com.apple.dt.Xcode") == true,
              "it comes out for an app it was told about")
        check(plain.wantsToShow(whenFrontmost: "com.apple.Terminal") == true,
              "…for any of them, not just the first")
        check(plain.wantsToShow(whenFrontmost: "com.apple.Safari") == false,
              "and folds away for one it was not")
        check(plain.wantsToShow(whenFrontmost: nil) == false,
              "and when nothing is in front at all")

        check(plain.subtitle.contains("follows 2 apps"),
              "the menu says what a following strip is following: \(plain.subtitle)")
    }

    /// The deck must fold away towards its own edge. A bottom strip that slid
    /// out sideways would read as the wrong object entirely.
    private static func checkFanDirection(deck: DeckController, screen: NSScreen) async {
        let cases: [(StripEdge, String, (NSPoint, NSRect) -> Bool)] = [
            (.right,  "off the right", { point, panel in point.x > panel.width }),
            (.left,   "off the left",  { point, _ in point.x < 0 }),
            (.bottom, "below the bottom", { point, panel in point.y > panel.height }),
        ]

        for (edge, description, isHidden) in cases {
            deck.strip = StripConfig(id: StripConfig.primaryID, name: "Deck", edge: edge,
                                     screenID: screen.ledgeDisplayID, offset: 0, pinned: false)
            await deck.refresh()
            deck.fanOut(takingFocus: false)
            deck.collapse()

            let geometry = deck.debugGeometry()
            guard let centre = deck.debugHiddenTabCentre() else {
                check(false, "a tab exists to hide on the \(edge.rawValue) edge"); continue
            }
            check(isHidden(centre, geometry.panel),
                  "on the \(edge.rawValue) edge the tabs hide \(description), "
                  + String(format: "not somewhere else (centre %.0f, %.0f in %.0f × %.0f)",
                           centre.x, centre.y, geometry.panel.width, geometry.panel.height))

            let direction = deck.debugHideDirection()
            switch edge {
            case .right:  check(direction.dx > 0 && direction.dy == 0, "right fans in from the right")
            case .left:   check(direction.dx < 0 && direction.dy == 0, "left fans in from the left")
            case .bottom: check(direction.dy > 0 && direction.dx == 0, "bottom fans in from below")
            }

            // The band with the title rides the edge that travelled outward —
            // the far end from the screen edge, in every orientation.
            deck.fanOut(takingFocus: false)
            deck.debugPreviewFirst()
            if let (band, card) = deck.debugCardStripRect() {
                let onLeadingEdge: Bool
                let described: String
                switch edge {
                case .right:  onLeadingEdge = band.minX < 1; described = "the left of the card"
                case .left:   onLeadingEdge = band.maxX > card.width - 1; described = "the right of the card"
                case .bottom: onLeadingEdge = band.minY < 1; described = "the top of the card"
                }
                check(onLeadingEdge,
                      "on the \(edge.rawValue) edge the title band is on \(described), "
                      + "where the note grew to — not where the tab was")
            } else {
                check(false, "a card exists to check on the \(edge.rawValue) edge")
            }
            deck.collapse()
        }
        deck.strip = StripConfig.primary()
        deck.collapse()
    }

    /// A bottom strip runs across the screen, sits inside the Dock's band so it
    /// can be placed to either side of the Dock, and grows upward.
    private static func checkBottomStrip(deck: DeckController, screen: NSScreen) async {
        func configure(offset: Double, pinned: Bool = false) {
            deck.strip = StripConfig(id: StripConfig.primaryID, name: "Deck", edge: .bottom,
                                     screenID: screen.ledgeDisplayID, offset: offset, pinned: pinned)
        }

        configure(offset: 0)
        deck.collapse()
        await deck.refresh()

        let rest = deck.debugGeometry()
        check(abs(rest.panel.minY - screen.frame.minY) < 0.5,
              "the strip sits in the Dock's band, not above it — that is what puts it beside the Dock")
        check(abs(rest.panel.midX - screen.frame.midX) < 1, "centred along the bottom by default")

        deck.fanOut(takingFocus: false)
        let fan = deck.debugGeometry()
        check(fan.tabs.allSatisfy { abs($0.maxY - fan.panel.height) < 0.5 },
              "every tab is flush with the bottom of the screen")
        let widths = fan.tabs.map(\.width)
        check(Set(widths.map { Int($0) }).count > 1,
              "a longer title still makes a longer tab, sideways: "
              + widths.map { String(format: "%.0f", $0) }.joined(separator: ", "))
        let gaps = zip(fan.tabs, fan.tabs.dropFirst()).map { $0.maxX - $1.minX }
        check(gaps.allSatisfy { $0 >= 2 && $0 <= 6 },
              "tabs still bite into each other: " + gaps.map { String(format: "%.1f", $0) }.joined(separator: ", "))
        // As with a side strip: past a few notes the row is longer than the
        // screen and scrolls, so what has to hold is that the window onto it is
        // inside the panel and something is in view.
        let rowPort = deck.viewportFrame
        check(rowPort.minX >= -0.5 && rowPort.maxX <= fan.panel.width + 0.5,
              "the window onto the row is inside the panel")
        check(fan.tabs.contains { $0.intersects(rowPort) }, "at least one tab is in view")

        let labels = deck.debugLabelBoxes()
        check(labels.allSatisfy { $0.box.maxX <= $0.bounds.width + 0.5 && $0.box.minX >= -0.5 },
              "no title runs out the side of its tab")
        check(labels.allSatisfy { $0.box.maxY <= $0.bounds.height + 0.5 },
              "titles read across, inside the tab")

        deck.debugPreviewFirst()
        let open = deck.debugGeometry()
        if let card = open.card {
            check(abs(card.maxY - open.panel.height) < Metrics.Card.overhang + 1,
                  "the note grows upward out of its tab and stays flush with the bottom")
            check(card.minX >= -0.5 && card.maxX <= open.panel.width + 0.5,
                  "the note is inside the panel")
            check(open.chromeAlpha == 0, "still no buttons until you click it")

            // The case that collapsed the buttons: docked here the band runs
            // along the top and costs no width; pulled onto the desk it moves to
            // the side and does.
            if let widths = deck.debugDetachedWidths() {
                check(widths.detached > widths.docked,
                      String(format: "a note taken off a bottom strip needs more width than it "
                             + "did docked (%.0f → %.0f), and gets it",
                             widths.docked, widths.detached))
                check(card.width >= widths.docked - 0.5,
                      "and docked it is already wide enough for its controls")
            }
        } else {
            check(false, "a note opens on a bottom strip")
        }
        deck.collapse()

        // ---- placement to either side of the Dock
        configure(offset: -0.5)
        deck.collapse()
        let left = deck.debugGeometry()
        check(abs(left.panel.minX - screen.frame.minX) < 1,
              "position Left puts the strip against the left of the screen, clear of a centred Dock")

        configure(offset: 0.5)
        deck.collapse()
        let right = deck.debugGeometry()
        check(abs(right.panel.maxX - screen.frame.maxX) < 1,
              "position Right puts it against the other side")

        // ---- pinning
        configure(offset: 0, pinned: true)
        await deck.refresh()
        deck.fanOut(takingFocus: false)
        deck.collapse()
        check(deck.debugGeometry().state != "rest",
              "a pinned strip keeps its tabs out instead of folding away")

        configure(offset: 0, pinned: false)
        deck.collapse()
        check(deck.debugGeometry().state == "rest",
              "unpinned, it folds back to a stripe again")
    }

    private static func checkGeometry(deck: DeckController, mirrored: Bool = false) async {
        await deck.refresh()

        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame

        // ---- at rest
        let rest = deck.debugGeometry()
        check(rest.state == "rest", "starts at rest")
        let outerEdge = mirrored ? rest.panel.minX : rest.panel.maxX
        let screenEdge = mirrored ? visible.minX : visible.maxX
        check(abs(outerEdge - screenEdge) < 0.5,
              "the pill is flush with the \(mirrored ? "left" : "right") edge of the visible screen")
        check(abs(rest.panel.width - Metrics.Pill.panelWidth) < 0.5,
              "the resting panel is \(Int(Metrics.Pill.panelWidth)) pt — "
              + "\(Int(Metrics.Pill.visibleWidth)) painted, \(Int(Metrics.Pill.hitMargin)) of hit margin")
        check(abs(rest.pill.width - Metrics.Pill.visibleWidth) < 0.5,
              "the pill paints \(Int(Metrics.Pill.visibleWidth)) pt")
        check(abs(rest.panel.midY - visible.midY) < 1, "the deck is vertically centred")
        check(rest.tabAlpha.allSatisfy { $0 < 0.01 }, "no tabs are visible at rest")

        // ---- fanned
        deck.fanOut(takingFocus: false)
        let fan = deck.debugGeometry()
        check(fan.state == "fanned", "reaching over fans the deck")
        check(fan.tabs.count == deck.recordsForTesting.count,
              "one tab per note (\(fan.tabs.count))")
        check(fan.tabs.count > 1, "the demo folder has a deck to fan")
        check(fan.tabs.allSatisfy { mirrored ? abs($0.minX) < 0.5 : abs($0.maxX - fan.panel.width) < 0.5 },
              "every tab is flush with the screen edge")
        check(fan.tabs.allSatisfy { $0.width >= Metrics.Tab.width && $0.width <= Metrics.Tab.width + Metrics.t(CGFloat(Jitter.maxProtrusion)) + 0.5 },
              "tabs are \(Int(Metrics.Tab.width)) pt wide, plus their own protrusion")
        let lengths = fan.tabs.map(\.height)
        let floor = Metrics.Tab.width * 0.9
        let allAtFloor = lengths.allSatisfy { $0 <= floor + 0.5 }
        if allAtFloor {
            // Enough notes and there is simply no room left to be proportional.
            check(true, "with \(lengths.count) notes every tab is squeezed to the minimum")
        } else {
            check(Set(lengths.map { Int($0) }).count > 1,
                  "a longer title makes a longer tab: "
                  + lengths.map { String(format: "%.0f", $0) }.joined(separator: ", "))
            // Against the length the title actually asks for, not against how
            // many characters it has. That worked while the labels were set in
            // a typewriter face, where every letter is the same width; with a
            // proportional one "WWW" is half again as long as "III" and the
            // count predicts nothing.
            let wanted = deck.debugTitles().map { NoteTabView.naturalHeight(for: $0) }
            let off = zip(lengths, wanted).map { abs($0 - $1) }.max() ?? 0
            check(off < 0.5,
                  String(format: "each tab is the length its own title asks for (worst gap %.1f pt)", off))
        }
        check(lengths.allSatisfy { $0 <= Metrics.Tab.maxHeight + 0.5 },
              "no tab grows past the configured limit")
        check(fan.panel.height <= visible.height + 0.5,
              "the deck never grows taller than the screen it lives on")

        let overlaps = zip(fan.tabs, fan.tabs.dropFirst()).map { $0.maxY - $1.minY }
        check(overlaps.allSatisfy { $0 >= 2 && $0 <= 5 },
              "tabs bite 2–5 pt into each other rather than sitting in a rhythm: "
              + overlaps.map { String(format: "%.1f", $0) }.joined(separator: ", "))
        check(Set(overlaps.map { String(format: "%.2f", $0) }).count > 1,
              "no two gaps are identical")
        check(fan.rotations.allSatisfy { abs($0) > 0.2 && abs($0) <= 0.6 },
              "every tab leans, none sits square: "
              + fan.rotations.map { String(format: "%.2f°", $0) }.joined(separator: ", "))
        // The stack is longer than the strip as soon as you have a few notes,
        // so what has to hold is not that all of it fits but that all of it is
        // *reachable*: the window it is seen through is inside the panel, and
        // nothing is laid out somewhere scrolling cannot bring it back.
        let viewport = deck.viewportFrame
        check(viewport.minY >= 0 && viewport.maxY <= fan.panel.height + 0.5,
              "the window onto the stack is inside the panel")
        let inView = fan.tabs.filter { $0.intersects(viewport) }
        check(!inView.isEmpty, "at least one tab is in view")
        check(inView.allSatisfy { $0.maxY <= viewport.maxY + $0.height },
              "no tab is laid out past the end of the window it is seen through")
        check(fan.plus.minY >= viewport.maxY - 0.5,
              "the + sits after the window, where scrolling cannot take it away")
        // Reported: the pin came out half off the end. The viewport subtracts
        // the room these need, so if either one lands outside the panel the two
        // sums have drifted apart again.
        check(fan.plus.maxY <= fan.panel.height + 0.5 && fan.pin.maxY <= fan.panel.height + 0.5,
              String(format: "both controls fit on the strip: + ends at %.0f, pin at %.0f, panel is %.0f",
                     fan.plus.maxY, fan.pin.maxY, fan.panel.height))
        check(fan.liveRegion.contains(fan.plus.insetBy(dx: 1, dy: 1)),
              "reaching down to the + does not fall outside the deck and collapse it")

        // opening the *last* tab is the case that used to yank the card upward
        deck.debugPreviewLast()
        if let lastCard = deck.debugGeometry().card, let lastTab = deck.debugGeometry().tabs.last {
            // Centred on its tab where there is room; clamped into view where
            // there is not. Either way the note has to still come *out of* its
            // tab, which means the two must overlap.
            let centred = abs(lastCard.midY - lastTab.midY) < 6
            let stillAttached = lastCard.intersects(lastTab)
            check(centred || stillAttached,
                  String(format: "a note opened off the bottom tab grows from where you are "
                         + "pointing, or is clamped into view still touching it "
                         + "(card %.0f–%.0f, tab %.0f–%.0f)",
                         lastCard.minY, lastCard.maxY, lastTab.minY, lastTab.maxY))
        }

        // ---- a note open
        deck.debugPreviewFirst()
        let open = deck.debugGeometry()
        check(open.state.hasPrefix("open"), "hovering a tab opens that note")
        guard let card = open.card else {
            check(false, "a card exists once a note is open"); return
        }
        check(abs((mirrored ? open.panel.minX : open.panel.maxX)
                  - (mirrored ? visible.minX : visible.maxX)) < 0.5,
              "the panel still hugs its edge once it widens")
        check(mirrored ? card.minX <= 0.5 : card.maxX >= open.panel.width - 0.5,
              "the card runs to the screen edge, so its lean never opens a corner gap")
        check(mirrored ? card.maxX < open.panel.width : card.minX > 0,
              "the card's leading strip is inside the panel")
        check(open.hiddenTabs == 1,
              "the open note's own tab is not drawn beside its card — the card is that tab")
        check(open.otherTabsVisible,
              "the rest of the deck stays on the edge, above and below the open note")
        check(card.minY >= 0 && card.maxY <= open.panel.height,
              "the card is not clipped top or bottom")
        let widthCeiling = max(Metrics.Card.width, deck.debugCardMinimumWidth() ?? 0)
        check(card.width <= widthCeiling + 0.5 && card.height <= Metrics.Card.height + 0.5,
              "the card is \(Int(card.width)) × \(Int(card.height)), within the size asked for "
              + "or the floor its controls set")
        // The nominal minimum scales with the size preference; the display does
        // not. On a screen too small to honour it, being clamped to the screen is
        // the right answer, so the floor is whichever is smaller.
        let floorWidth = min(Metrics.Card.minWidth, visible.width * 0.42)
        let floorHeight = min(Metrics.Card.minHeight, open.panel.height - Metrics.panelPadding * 2)
        check(card.width >= floorWidth - 0.5 && card.height >= floorHeight - 0.5,
              String(format: "the card is never smaller than the room allows (%.0f × %.0f, "
                     + "floor %.0f × %.0f)", card.width, card.height, floorWidth, floorHeight))
        // The requirement is not "wide enough" but "nothing overlaps" — on a
        // small screen the row gives way instead, and that is still correct.
        check(deck.debugChromeOverlaps() == false,
              String(format: "no two controls overlap at %.0f pt wide "
                     + "(the row wants %.0f and shrinks to fit)",
                     card.width, deck.debugCardMinimumWidth() ?? 0))
        check(open.liveRegion.contains(card.insetBy(dx: 1, dy: 1)),
              "the card counts as inside, so reading it does not collapse the deck")
        check(card.height <= open.panel.height && card.maxY <= open.panel.height + 0.5,
              "the card fits the panel even at the largest card size")
        check(card.width < (NSScreen.screens.first?.visibleFrame.width ?? 1440) / 2,
              "the card never takes over half the screen")
        check(abs(open.cardRotation) > 0.4,
              String(format: "the open card leans %.2f° while you read it", open.cardRotation))

        // labels must not be sliced off by the screen edge
        let labels = deck.debugLabelBoxes()
        check(!labels.isEmpty, "every tab draws a title")
        check(labels.allSatisfy { $0.box.minX >= -0.5 && $0.box.maxX <= $0.bounds.width + 0.5 },
              "no title is clipped by the edge of its tab: "
              + labels.map { String(format: "%.1f–%.1f in %.0f", $0.box.minX, $0.box.maxX, $0.bounds.width) }
                      .joined(separator: ", "))
        check(labels.allSatisfy { $0.box.maxY <= $0.bounds.height + 0.5 },
              "no title runs off the bottom of its tab")

        check(open.chromeAlpha == 0,
              "a note you are only reading shows no buttons at all")

        // Recolouring has to repaint the paper you are looking at, not only the
        // tab behind it — the change used to arrive on the card only after you
        // closed the note and opened it again.
        if let id = deck.debugOpenNoteID(), let before = deck.debugPaintedColors() {
            let current = deck.recordsForTesting.first { $0.id == id }?.color
            let target: NoteColor = current == .coral ? .blue : .coral
            deck.debugRecolor(id, to: target)
            let after = deck.debugPaintedColors()

            check(after?.tabColor == target, "the tab takes the new colour at once")
            check(after?.card != nil && before.card != nil, "the card is painted at all")
            check(after?.card?.isCloseTo(before.card!) == false,
                  "recolouring repaints the open note immediately, not on next open")

            // and putting it back returns the original paper exactly
            if let original = current {
                deck.debugRecolor(id, to: original)
                check(deck.debugPaintedColors()?.card?.isCloseTo(before.card!) == true,
                      "…and changing it back restores the paper it had")
            }
        }

        // Text has to be readable on the paper it is actually painted on, in
        // either appearance. The highlighter repaints every character on each
        // keystroke and used to keep the ink it was constructed with, so a card
        // built under one appearance and shown under the other wrote near-white
        // on a pastel: a caret moving over text nobody could see.
        for (name, appearance) in [("light", NSAppearance(named: .aqua)),
                                   ("dark", NSAppearance(named: .darkAqua))] {
            if let painted = deck.debugInkOnPaper(forcing: appearance) {
                let ratio = contrastRatio(painted.text, painted.paper)
                check(ratio >= 4.5,
                      String(format: "note text is readable on its paper in %@ (%.1f:1)", name, ratio))
            }
        }
        _ = deck.debugInkOnPaper(forcing: nil)

        deck.debugBeginEditingFirst()
        check(abs(deck.debugGeometry().cardRotation) < 0.001,
              "the card levels out the moment the caret lands")
        check(deck.debugGeometry().chromeAlpha > 0.99,
              "clicking into a note brings its controls out")

        // ---- back to rest
        deck.collapse()
        check(deck.debugGeometry().state == "rest", "it settles back to a stripe")
    }

    private static func summarise() {
        print("")
        if failures.isEmpty {
            print("\u{001B}[32mgeometry checks all passing\u{001B}[0m")
            exit(0)
        }
        print("\u{001B}[31m\(failures.count) geometry checks failing\u{001B}[0m")
        exit(1)
    }
}


extension NSColor {
    /// Colours make a round trip through CGColor, so compare with a tolerance.
    func isCloseTo(_ other: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }
}
