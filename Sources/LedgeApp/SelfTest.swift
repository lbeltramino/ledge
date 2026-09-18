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
        [relative](./otra-nota.md)
        ![a picture](resources/img/x.png)
        ![a remote picture](https://example.com/x.png)

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

        // Clicking a link hands the URL to LaunchServices, so only something it
        // can open is allowed to look like one. A relative path is not: that is
        // "the application can't be opened, -50", which is what an image
        // reference gave when its alt text was linkified.
        check(attribute(.link, at: "a picture") == nil,
              "the alt text of a picture is not a link to follow")
        // The one the scheme check alone does not save: a remote picture's URL
        // *is* openable, so only refusing to match after a `!` keeps its alt
        // text from becoming a link.
        check(attribute(.link, at: "a remote picture") == nil,
              "…nor a remote picture's, which is a perfectly good URL")
        check(attribute(.underlineStyle, at: "a picture") == nil,
              "…and is not underlined as though it were")
        check(attribute(.link, at: "relative") == nil,
              "a link to a relative path is not handed to LaunchServices either")
        check(attribute(.foregroundColor, at: "relative") != nil,
              "…though it still reads as a link in the note")

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

    /// Una nota en el escritorio es la misma nota.
    ///
    /// `FloatingNote` reenvía los callbacks de la card uno por uno, y esa lista
    /// se separa de la del deck en silencio: pasó con los botones de fuente y
    /// volvió a pasar con los enlaces, que no hacían nada al sacar la nota
    /// afuera. Esto pregunta por todos, incluidos los del text view — donde
    /// vive `onOpenLink`, que es justo el que se escapó la segunda vez.
    static func checkTheDeskGetsEverything() {
        let record = NoteRecord(note: Note(title: "Prueba"), filename: "f.md",
                                mtime: 0, size: 0, hash: "")
        let float = FloatingNote(record: record, title: "Prueba", body: "ver [[Otra]]",
                                 size: NSSize(width: 420, height: 300))

        // Lo que el deck decide por sí mismo, y una nota suelta no necesita.
        let propios = [
            "onBeginEditing",   // foco y tabs del deck; la flotante tiene su ventana
            "onSuggestedTitle", // el título lo pone el deck al pegar código
            "onFind",           // ⌘F lo maneja la ventana flotante
            "onChange",         // la card lo usa internamente
            "onUnlockTable",    // lo cablea la propia card
        ]
        let sueltos = unwired(float.cardView) + unwired(float.cardView.textView)
        let faltantes = sueltos.filter { !propios.contains($0) }
        check(faltantes.isEmpty,
              "una nota en el escritorio pierde: \(faltantes.isEmpty ? "nada" : faltantes.joined(separator: ", "))")
    }

    /// Los `on…` que nadie escucha.
    private static func unwired(_ object: Any) -> [String] {
        Mirror(reflecting: object).children.compactMap { child in
            guard let label = child.label, label.hasPrefix("on") else { return nil }
            let value = Mirror(reflecting: child.value)
            guard value.displayStyle == .optional, value.children.isEmpty else { return nil }
            return label
        }
    }

    /// Pegar un JSON minificado en una nota.
    static func checkPastingMinifiedJSON() {
        let record = NoteRecord(note: Note(title: "Pegar"), filename: "j.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: "antes\n")
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        card.layoutSubtreeIfNeeded()
        let view = card.textView

        let scratch = NSPasteboard(name: .init("ledge.selftest.json"))
        scratch.clearContents()
        let json = #"{"id":"3b5a951b","event":"service:action:create","notification":{"slug":"update-trottle-hybrid","parameters":{"throttling_rate_limit":15,"endpoints":[{"path":"/test","method":"GET"}]}}}"#
        scratch.setString(json, forType: .string)
        view.pasteboard = scratch
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.paste(nil)

        check(view.string.contains("```json"),
              "un json de una línea llega como código: \(view.string.prefix(40))")
        check(view.string.contains("\"throttling_rate_limit\": 15"),
              "sin perder nada de lo pegado")
        check(view.string.components(separatedBy: "\n").count > 8,
              "y acomodado, no una pared de una línea: \(view.string.components(separatedBy: "\n").count) líneas")
        check(view.string.contains("  \"event\": \"service:action:create\""),
              "con la sangría de jq")
        scratch.releaseGlobally()

        // Y una frase suelta sigue siendo una frase.
        //
        // Preguntado a la decisión, no al texto resultante: si dejo que
        // `paste` siga de largo cae en `super.paste`, que lee el portapapeles
        // real de la máquina — y entonces el check mide lo que vos tengas
        // copiado en vez de medir Ledge.
        let prosa = NSPasteboard(name: .init("ledge.selftest.prosa"))
        prosa.clearContents()
        prosa.setString("me acordé de revisar el throttling del gateway", forType: .string)
        check(!MarkdownEditing.pasteCode(view, from: prosa).did,
              "una frase no se encierra en un fence")
        prosa.releaseGlobally()
    }

    /// Las teclas de navegación, como las espera alguien que viene de VS Code.
    ///
    /// macOS manda Home, End y las de página a los scrollers: la página se
    /// mueve y el caret se queda. Es la convención del sistema, y es la única
    /// que esta app rompe a propósito.
    static func checkEditorKeys() {
        let cuerpo = "primera línea\n    - una tarea indentada\nuna línea más larga para probar\n"
            + (4...20).map { "línea \($0)" }.joined(separator: "\n")
        let record = NoteRecord(note: Note(title: "Teclas"), filename: "k.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: cuerpo)
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.layoutSubtreeIfNeeded()
        let view = card.textView
        window.makeFirstResponder(view)
        let ns = view.string as NSString

        func press(_ code: UInt16, _ scalar: Int, shift: Bool = false, command: Bool = false) {
            var flags: NSEvent.ModifierFlags = []
            if shift { flags.insert(.shift) }
            if command { flags.insert(.command) }
            let chars = String(UnicodeScalar(UInt32(scalar))!)
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
            view.keyDown(with: e)
        }
        let HOME: (UInt16, Int) = (115, 0xF729)
        let END: (UInt16, Int) = (119, 0xF72B)
        let PGUP: (UInt16, Int) = (116, 0xF72C)
        let PGDN: (UInt16, Int) = (121, 0xF72D)

        // Home, en una línea indentada: dos paradas.
        let tarea = ns.range(of: "una tarea")
        let tinta = ns.range(of: "- una tarea").location
        let cero = ns.range(of: "    - una").location
        view.setSelectedRange(NSRange(location: tarea.location + 4, length: 0))
        press(HOME.0, HOME.1)
        check(view.selectedRange().location == tinta,
              "Home va al primer carácter con tinta, no al principio de la nota")
        press(HOME.0, HOME.1)
        check(view.selectedRange().location == cero, "y de ahí a la columna cero")

        // End, en su propia línea.
        view.setSelectedRange(NSRange(location: tarea.location + 4, length: 0))
        press(END.0, END.1)
        check(view.selectedRange().location == NSMaxRange(ns.range(of: "una tarea indentada")),
              "End va al final de la línea, no al de la nota")

        // Con Shift, seleccionan en vez de saltar.
        view.setSelectedRange(NSRange(location: tarea.location + 4, length: 0))
        press(HOME.0, HOME.1, shift: true)
        let sel = view.selectedRange()
        check(sel.length == tarea.location + 4 - tinta && sel.location == tinta,
              "⇧Home selecciona hasta el inicio de la línea: \(sel)")
        view.setSelectedRange(NSRange(location: tarea.location + 4, length: 0))
        press(END.0, END.1, shift: true)
        check(view.selectedRange().location == tarea.location + 4
                && view.selectedRange().length > 0,
              "⇧End selecciona hasta el final de la línea: \(view.selectedRange())")

        // ⌘Home y ⌘End: la nota entera.
        view.setSelectedRange(NSRange(location: tarea.location + 4, length: 0))
        press(HOME.0, HOME.1, command: true)
        check(view.selectedRange().location == 0, "⌘Home va al principio de la nota")
        press(END.0, END.1, command: true)
        check(view.selectedRange().location == ns.length, "⌘End al final")

        // Página: mueve el caret, que es lo que macOS no hace.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        press(PGDN.0, PGDN.1)
        let trasPagina = view.selectedRange().location
        check(trasPagina > 0, "PageDown mueve el caret, no sólo la vista: quedó en \(trasPagina)")
        check(trasPagina < ns.length, "…una pantalla, no hasta el final")
        press(PGUP.0, PGUP.1)
        check(view.selectedRange().location < trasPagina, "y PageUp lo trae de vuelta")

        // Lo que ya andaba bien no se tocó.
        view.setSelectedRange(NSRange(location: tarea.location + 4, length: 0))
        view.moveToLeftEndOfLine(nil)
        check(view.selectedRange().location == cero, "⌘← sigue yendo al inicio de la línea")
    }

    /// Un enlace se abre apretándolo.
    static func checkLinkOpensOnClick() {
        let record = NoteRecord(note: Note(title: "Madre"), filename: "m.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: "ver [[Modelo de permisos]] y seguir")
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        card.layoutSubtreeIfNeeded()
        let view = card.textView
        var abiertos: [String] = []
        view.onOpenLink = { abiertos.append($0) }

        guard let manager = view.layoutManager, let container = view.textContainer else {
            check(false, "sin layout"); return
        }
        manager.ensureLayout(for: container)
        let nombre = (view.string as NSString).range(of: "Modelo de permisos")
        let glyphs = manager.glyphRange(forCharacterRange: nombre, actualCharacterRange: nil)
        var caja = manager.boundingRect(forGlyphRange: glyphs, in: container)
        caja.origin.x += view.textContainerOrigin.x
        caja.origin.y += view.textContainerOrigin.y
        let dentro = NSPoint(x: caja.midX, y: caja.midY)

        func click(_ point: NSPoint, option: Bool = false) {
            guard let e = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
                                             modifierFlags: option ? .option : [], timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return }
            view.mouseDown(with: e)
        }

        click(dentro)
        check(abiertos == ["Modelo de permisos"],
              "un click sobre el enlace abre la nota: \(abiertos)")

        // Pero se tiene que poder editar el nombre a mano: los corchetes
        // siguen siendo texto común, y ahí se pone el caret.
        abiertos = []
        let corchetes = (view.string as NSString).range(of: "[[")
        let g0 = manager.glyphRange(forCharacterRange: corchetes, actualCharacterRange: nil)
        var caja0 = manager.boundingRect(forGlyphRange: g0, in: container)
        caja0.origin.x += view.textContainerOrigin.x
        caja0.origin.y += view.textContainerOrigin.y
        click(NSPoint(x: caja0.minX + 2, y: caja0.midY))
        check(abiertos.isEmpty, "apretar los corchetes no lo abre: deja editar el nombre")

        // Y el texto común sigue siendo texto común.
        abiertos = []
        let fuera = (view.string as NSString).range(of: "y seguir")
        let g2 = manager.glyphRange(forCharacterRange: fuera, actualCharacterRange: nil)
        var caja2 = manager.boundingRect(forGlyphRange: g2, in: container)
        caja2.origin.x += view.textContainerOrigin.x
        caja2.origin.y += view.textContainerOrigin.y
        click(NSPoint(x: caja2.midX, y: caja2.midY))
        check(abiertos.isEmpty, "apretar el resto de la nota no abre nada")
    }

    /// Saca del folder lo que un check dejó, y deja el deck como estaba.
    ///
    /// Los checks comparten una carpeta de notas. Uno que agrega notas y no las
    /// saca le cambia el deck a todos los que corren después — esta suite ya se
    /// contaminó a sí misma tres veces de esta forma, y la respuesta es que
    /// cada check limpie lo suyo.
    static func cleanUp(_ titles: [String], deck: DeckController, folder: URL) async {
        let manager = FileManager.default
        var removed: [String] = []
        for title in titles {
            let url = folder.appendingPathComponent("\(title).md")
            if manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
                removed.append("\(title).md")
            }
        }
        guard !removed.isEmpty else { return }
        await deck.reconcileForTesting(removed)
        await deck.refresh()
    }

    /// Borrar un bloque grande y que se quede borrado.
    ///
    /// Reportado: pegar un JSON de cuatrocientas líneas, querer borrarlo, y que
    /// "se repita". Es la forma del bug que ya tuvimos una vez — el merge
    /// re-insertando lo que sacaste porque la línea base y el archivo no
    /// coinciden — así que vale medirlo con un bloque de ese tamaño y no con
    /// tres líneas.
    static func checkDeletingABigBlockSticks(deck: DeckController, folder: URL) async {
        // Pegado, no escrito en el archivo: es el camino que se reportó, y el
        // pegado reformatea, fencea y mueve el caret — todo antes de que nadie
        // haya guardado nada.
        var minificado = "{"
        for i in 0..<380 { minificado += "\"clave\(i)\":\"valor \(i)\"," }
        minificado += "\"ultima\":true}"

        let feed = FeedStore(folder: folder)
        var nota = Note(title: "Con un json grande", color: .butter)
        nota.body = "antes del json\n\ndespués del json"
        _ = try? feed.write(nota, to: folder.appendingPathComponent("Con un json grande.md"))
        await deck.reconcileForTesting(["Con un json grande.md"])
        await deck.refresh()

        deck.fanOut(takingFocus: false)
        deck.previewForTesting(nota.id)
        try? await Task.sleep(for: .milliseconds(400))
        guard let card = deck.debugCard, card.record.id == nota.id else {
            check(false, "no se abrió la nota del json"); return
        }
        let view = card.textView

        // Un Enter al principio, que es lo que lo disparaba: el cuerpo pasa a
        // empezar con una línea en blanco, `parse` se la comía, y desde ahí la
        // línea base y el archivo diferían en un carácter.
        card.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("\n", replacementRange: view.selectedRange())
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(700))

        // Medido acá, que es donde nacía la diferencia. Más adelante el merge
        // ya reconcilió y la invariante vuelve a cerrar sola — un check puesto
        // al final pasa con el bug puesto.
        let trasElEnter = await deck.debugFileBody(of: nota.id)
        check(deck.debugBaseline(of: nota.id) == trasElEnter,
              "un Enter al principio no corre la línea base "
              + "(\(deck.debugBaseline(of: nota.id)?.count ?? -1) vs \(trasElEnter?.count ?? -1))")

        // Pegar donde la nota lo pondría: al final.
        let clip = NSPasteboard(name: .init("ledge.selftest.jsongrande"))
        clip.clearContents()
        clip.setString(minificado, forType: .string)
        view.pasteboard = clip
        card.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.paste(nil)
        check(view.string.contains("```json"), "el json pegado entra como código")
        let antes = (view.string as NSString).length
        check(antes > 6000, "el bloque es grande de verdad: \(antes) caracteres")

        // Y guardado, como pasa en la vida real antes de que lo borres.
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(1000))

        // Seleccionar el bloque entero y borrarlo, que es lo que se hace.
        let ns = view.string as NSString
        let desde = ns.range(of: "```json")
        let hasta = ns.range(of: "```", options: .backwards)
        guard desde.location != NSNotFound, hasta.location > desde.location else {
            check(false, "no encontré el bloque"); return
        }
        let bloque = NSRange(location: desde.location,
                             length: NSMaxRange(hasta) - desde.location)
        card.window?.makeFirstResponder(view)
        view.setSelectedRange(bloque)
        view.delete(nil)

        check(!view.string.contains("clave200"),
              "en pantalla el bloque se fue")
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(1200))

        // Y la invariante que lo causaba, dicha en el idioma del deck.
        let enElArchivo = await deck.debugFileBody(of: nota.id)
        check(deck.debugBaseline(of: nota.id) == enElArchivo,
              "la línea base y el archivo dicen lo mismo "
              + "(\(deck.debugBaseline(of: nota.id)?.count ?? -1) vs \(enElArchivo?.count ?? -1))")

        let enDisco = (try? String(contentsOf: folder.appendingPathComponent("Con un json grande.md"),
                                   encoding: .utf8)) ?? ""
        check(!enDisco.contains("clave200"),
              "y se fue del archivo, sin volver")
        check(enDisco.contains("antes del json") && enDisco.contains("después del json"),
              "sin llevarse lo que estaba alrededor")
        let repeticiones = view.string.components(separatedBy: "antes del json").count - 1
        check(repeticiones == 1,
              "y nada quedó duplicado: «antes del json» aparece \(repeticiones) vez/veces")

        clip.releaseGlobally()
        deck.closeNote()
        await cleanUp(["Con un json grande"], deck: deck, folder: folder)
    }

    /// Apretar un enlace a una nota que todavía no existe.
    ///
    /// Por el camino entero, y con la trampa adentro: la nota que se aprieta
    /// *contiene* el texto del enlace. Buscar por contenido la hacía ganar a
    /// ella misma, así que apretar abría la nota en la que ya estabas — que
    /// desde afuera se ve exactamente igual que no hacer nada.
    static func checkPressingALinkThatDoesNotExistYet(deck: DeckController, folder: URL) async {
        let nombre = "Nota inventada \(Int(Date().timeIntervalSince1970) % 10000)"
        let feed = FeedStore(folder: folder)
        var madre = Note(title: "Con un enlace suelto", color: .coral)
        madre.body = "algo\n\n[[ \(nombre) ]]"
        _ = try? feed.write(madre, to: folder.appendingPathComponent("Con un enlace suelto.md"))
        await deck.reconcileForTesting(["Con un enlace suelto.md"])
        await deck.refresh()

        deck.fanOut(takingFocus: false)
        deck.previewForTesting(madre.id)
        try? await Task.sleep(for: .milliseconds(400))
        guard let card = deck.debugCard, card.record.id == madre.id else {
            check(false, "no se abrió la nota del enlace"); return
        }

        card.textView.onOpenLink?(nombre)
        try? await Task.sleep(for: .milliseconds(900))
        await deck.refresh()

        let creada = (try? feed.notes())?.contains { $0.note.title == nombre } ?? false
        check(creada, "apretar un enlace a una nota que no existe la crea: «\(nombre)»")
        check(deck.debugCardBody() != madre.body,
              "y te lleva ahí, no te deja en la nota donde está el enlace")

        deck.closeNote()
        await cleanUp([nombre, "Con un enlace suelto"], deck: deck, folder: folder)
    }

    /// Escribir `[[`, crear la hija, y poder llegar a ella.
    ///
    /// El camino entero, por el deck: el selector inserta, el deck crea el
    /// archivo, y la fila de la madre la ofrece. Los checks anteriores
    /// probaban cada mitad por separado, que es exactamente cómo se cuela un
    /// tramo roto.
    static func checkCreatingAChildByTyping(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let madre = deck.recordsForTesting.first else {
            check(false, "no hay notas"); return
        }
        deck.fanOut(takingFocus: false)
        deck.previewForTesting(madre.id)
        try? await Task.sleep(for: .milliseconds(300))
        guard let card = deck.debugCard else { check(false, "no se abrió la card"); return }
        let view = card.textView

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        for ch in "\nver [[Una hija por tipeo" {
            view.insertText(String(ch), replacementRange: view.selectedRange())
        }
        check(view.linkPicker.isOpen, "el selector aparece al escribir en una card de verdad")
        check(view.linkPicker.debugRows.last?.contains("Una hija por tipeo") == true,
              "ofrece crearla: \(view.linkPicker.debugRows)")

        view.linkPicker.take()
        check(view.string.contains("[[Una hija por tipeo]]"),
              "el enlace queda escrito: \(view.string.suffix(30))")

        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(900))
        await deck.refresh()

        // El archivo existe, con su madre.
        let feed = FeedStore(folder: folder)
        let hija = (try? feed.notes())?.first { $0.note.title == "Una hija por tipeo" }
        check(hija != nil, "la nota hija se creó en el disco")
        check(hija?.note.parent == madre.id,
              "y pertenece a la madre: \(hija?.note.parent ?? "sin madre")")

        // Y la madre la ofrece, que es cómo se llega.
        check(!deck.recordsForTesting.contains { $0.title == "Una hija por tipeo" },
              "no ocupa la tira")
        try? await Task.sleep(for: .milliseconds(400))
        check(deck.debugCard?.family.debugLabels.contains("Una hija por tipeo") == true,
              "la fila de la madre la lista: \(deck.debugCard?.family.debugLabels ?? [])")

        deck.closeNote()
        await cleanUp(["Una hija por tipeo"], deck: deck, folder: folder)
    }

    /// Apretar el chip de una hija, que es cómo se llega a ella.
    ///
    /// Reportado como "hago click y no me muestra la nota": sí la mostraba,
    /// pero la hija aparecía sin fila de familia — sin camino de vuelta y sin
    /// nada que dijera dónde estabas. Con una hija vacía, eso se ve idéntico a
    /// que no hubiera pasado nada.
    static func checkFamilyChipOpensTheChild(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let madre = deck.recordsForTesting.first else { check(false, "no hay notas"); return }
        let feed = FeedStore(folder: folder)
        var hija = Note(title: "Hija del chip", color: .blue)
        hija.parent = madre.id
        hija.body = "lo que hay en la hija"
        _ = try? feed.write(hija, to: folder.appendingPathComponent("Hija del chip.md"))
        await deck.reconcileForTesting(["Hija del chip.md"])
        await deck.refresh()

        deck.fanOut(takingFocus: false)
        deck.previewForTesting(madre.id)
        try? await Task.sleep(for: .milliseconds(600))
        guard let card = deck.debugCard, card.record.id == madre.id else {
            check(false, "no se abrió la madre"); return
        }
        card.layoutSubtreeIfNeeded()
        check(card.family.debugLabels.contains("Hija del chip"),
              "la madre lista a su hija: \(card.family.debugLabels)")

        guard let chip = card.family.debugChips.first(where: { $0.2 == "Hija del chip" }) else {
            check(false, "no encuentro el chip"); return
        }
        card.family.press(at: NSPoint(x: chip.1.midX, y: chip.1.midY))
        try? await Task.sleep(for: .milliseconds(800))
        check(deck.debugCardBody()?.contains("lo que hay en la hija") == true,
              "apretar el chip abre la hija: \(deck.debugCardBody()?.prefix(24) ?? "nada")")

        // Y —lo que faltaba— en algún lado donde se vea. La card se posiciona
        // contra el tab de su nota, y una hija no tiene tab: se construía con
        // la hija adentro y se quedaba en cero por cero. Desde afuera eso es
        // idéntico a que el click no hiciera nada, que es como se reportó.
        let marco = deck.cardFrame ?? .zero
        check(marco.width > 100 && marco.height > 60,
              String(format: "y la card de la hija tiene tamaño (%.0f×%.0f)", marco.width, marco.height))
        check(marco.maxX > 0 && marco.maxY > 0 && marco.minY < deck.panelFrame.height,
              "y está dentro del panel, no en una esquina invisible: \(marco)")

        if let abierta = deck.debugCard {
            abierta.layoutSubtreeIfNeeded()
            check(abierta.family.debugLabels.contains(where: { $0.hasPrefix("‹") }),
                  "y la hija muestra el camino de vuelta: \(abierta.family.debugLabels)")
        }

        // Y se la puede tratar como a cualquier nota: arrastrarla fuera de la
        // tira. `detach` buscaba la ficha en `records`, donde una hija nunca
        // está, así que quedaba pegada al borde sin poder moverse ni
        // agrandarse — reportado exactamente así.
        check(deck.debugCanDetach(hija.id),
              "una hija se puede sacar de la tira como cualquier otra nota")

        // Volver a la madre desde la hija abre la madre, no una segunda copia
        // de ella: `visiting` sólo es para notas que la tira no tiene.
        deck.visit(madre.id)
        try? await Task.sleep(for: .milliseconds(700))
        check(deck.debugVisiting == nil,
              "volver a una nota con tab no la deja marcada como visitada: \(deck.debugVisiting ?? "nil")")
        check(deck.debugCardBody() != nil && deck.debugCardTitle() == madre.displayTitle,
              "y la card abierta es la madre: \(deck.debugCardTitle() ?? "ninguna")")

        deck.closeNote()
        await cleanUp(["Hija del chip"], deck: deck, folder: folder)
    }

    /// Abrir una hija, que no tiene tab.
    ///
    /// El riesgo entero de que un proyecto cueste un solo tab: la card se arma
    /// desde `records`, y una hija no está ahí. Sin esto, el chip y el
    /// ⌘-click no hacen nada — la función existe y el camino hasta ella no.
    static func checkOpeningAChild(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let madre = deck.recordsForTesting.first else {
            check(false, "no hay notas"); return
        }
        let store = FeedStore(folder: folder)
        guard let entrada = try? store.find(madre.id) else {
            check(false, "no encuentro la madre"); return
        }
        var hija = Note(title: "Hija sin tab", color: .blue)
        hija.parent = madre.id
        hija.body = "lo que hay adentro"
        _ = try? store.write(hija, to: folder.appendingPathComponent("Hija sin tab.md"))
        _ = entrada
        await deck.reconcileForTesting(["Hija sin tab.md"])
        await deck.refresh()

        check(!deck.recordsForTesting.contains { $0.id == hija.id },
              "la hija no ocupa la tira")
        check(deck.tabsForTesting.count == deck.recordsForTesting.count,
              "ni tiene tab: \(deck.tabsForTesting.count) tabs, \(deck.recordsForTesting.count) notas")

        deck.fanOut(takingFocus: false)
        deck.visit(hija.id)
        try? await Task.sleep(for: .milliseconds(600))
        check(deck.debugCardBody()?.contains("lo que hay adentro") == true,
              "y aun así se abre: \(deck.debugCardBody()?.prefix(30) ?? "nada")")
        deck.closeNote()
        await deck.refresh()

        // Y no la cierra el guard que saca las cards huérfanas.
        deck.visit(hija.id)
        try? await Task.sleep(for: .milliseconds(600))
        await deck.refresh()
        check(deck.debugCardBody()?.contains("lo que hay adentro") == true,
              "un refresco no la echa de la pantalla")
        deck.closeNote()
        await cleanUp(["Hija sin tab"], deck: deck, folder: folder)
    }

    /// An agent writing a diagram into the note you are looking at.
    ///
    /// The whole way through: the command writes the file, the folder watcher
    /// brings it in, and the open note has to *draw* it. Checked here rather
    /// than only against `syncBody`, because the last two times something did
    /// not appear on screen the mechanism was fine and the path to it was not.
    static func checkAgentDiagramArrives(deck: DeckController, folder: URL) async {
        await deck.refresh()
        guard let record = deck.recordsForTesting.first else {
            check(false, "no note"); return
        }
        deck.fanOut(takingFocus: false)
        deck.previewForTesting(record.id)
        await deck.refresh()
        let before = deck.debugCardDrawings()

        let feed = FeedStore(folder: folder)
        guard let entry = try? feed.find(record.id) else {
            check(false, "the command cannot find the note"); return
        }
        var note = entry.note
        // At the very end, which is where an agent appends.
        note.body = FeedEdit.appending("```mermaid\ngraph TD\n    A[Build] --> B[Deploy]\n```",
                                       to: note.body)
        _ = try? feed.write(note, to: entry.url)

        await deck.reconcileForTesting([record.filename])
        try? await Task.sleep(for: .milliseconds(800))

        check(deck.debugCardBody()?.contains("mermaid") == true,
              "the text an agent appended reaches the open note")
        check(deck.debugCardDrawings() == before + 1,
              "…and it is drawn, without anyone touching the keyboard: "
              + "\(before) → \(deck.debugCardDrawings())")
        deck.closeNote()
        await deck.refresh()
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
    /// Pictures and diagrams: that they are drawn, that they land under their
    /// markdown instead of over it, and that a photograph does not arrive in
    /// memory at its own size.
    static func checkDrawnMedia() {
        let note = """
        Antes.

        ![una chica](resources/img/small.png)

        Entre las dos.

        ![una grande](resources/img/big.png)

        ![no existe](resources/img/nope.png)

        ![remota](https://example.com/x.png)

        ```mermaid
        graph TD
            A[Una] --> B[Otra]
        ```

        Después de todo.
        """
        let record = NoteRecord(note: Note(title: "Con dibujos"), filename: "m.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: note)
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 900)
        card.layoutSubtreeIfNeeded()
        let view = card.textView

        check(view.string == note, "drawing a picture changes not one character of the note")

        // Three drawings: two pictures and a diagram. The missing file is a
        // fourth view that says so, and the remote one is not drawn at all.
        check(view.debugMediaCount == 4,
              "four references drawn, the remote one left alone: \(view.debugMediaCount)")
        let pictures = view.debugMediaViews.filter(\.debugIsPicture)
        check(pictures.count == 3, "two pictures and a diagram: \(pictures.count)")
        let missing = view.debugMediaViews.compactMap(\.debugMissingReason)
        check(missing.count == 1 && missing[0].contains("nope.png"),
              "and the one that is not there says so: \(missing)")

        // Where they land. A drawing over the text would be the tables bug
        // again, from the other side.
        for frame in view.debugMediaFrames {
            check(frame.width > 40 && frame.height > 10,
                  String(format: "a drawing has a frame, not a point (%.0f×%.0f)",
                         frame.width, frame.height))
        }
        let frames = view.debugMediaFrames.sorted { $0.minY < $1.minY }
        check(!frames.isEmpty && frames.allSatisfy { $0.minY >= 0 },
              "every drawing is somewhere you can see")
        for (i, frame) in frames.enumerated() where i > 0 {
            check(frame.minY >= frames[i - 1].maxY - 1,
                  String(format: "drawings do not stack on each other (%.0f then %.0f)",
                         frames[i - 1].maxY, frame.minY))
        }

        // The invariant: the room under the markdown is reserved, so the text
        // that follows starts after the drawing rather than under it.
        guard let manager = view.layoutManager, let container = view.textContainer,
              let after = (view.string as NSString).range(of: "Después de todo.") as NSRange?,
              after.location != NSNotFound else {
            check(false, "no closing line to measure against"); return
        }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: after, actualCharacterRange: nil)
        let tail = manager.boundingRect(forGlyphRange: glyphs, in: container)
        if let last = frames.last {
            check(tail.minY >= last.maxY - 2,
                  String(format: "the text after the last drawing clears it (%.0f vs %.0f)",
                         tail.minY, last.maxY))
        }

        // And the whole point of the feature: a 2000×1500 picture is 11.4 MB of
        // pixels, and a note this wide must not be holding them.
        let available = max(80, container.size.width - 4)
        guard let url = MediaStore.url(for: "resources/img/big.png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = MediaStore.pixelSize(of: source) else {
            check(false, "no big picture to measure"); return
        }
        check(full.width >= 2000, "the fixture really is big: \(Int(full.width))px")
        guard let drawn = MediaStore.image(at: url, available: available, scale: 2) else {
            check(false, "the big picture did not decode"); return
        }
        // The decoded bitmap itself, not the size in points the image reports:
        // asking the representation gave a number that did not move when the
        // downsampling was taken out, which is a check that passes for the
        // wrong reason.
        var proposed = NSRect(origin: .zero, size: drawn.size)
        let bitmap = drawn.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        let pixels = (bitmap?.width ?? 0) * (bitmap?.height ?? 0)
        let megabytes = Double(pixels * 4) / 1_048_576
        check(pixels > 0, "there is a decoded bitmap to measure")
        check(megabytes < 2,
              String(format: "the big picture costs %.1f MB, not %.1f",
                     megabytes, Double(Int(full.width) * Int(full.height) * 4) / 1_048_576))
        check(drawn.size.width <= available + 1,
              String(format: "and is drawn at the note's width (%.0f in %.0f)",
                     drawn.size.width, available))

        // Never upscaled: the small one keeps its own size.
        guard let small = MediaStore.url(for: "resources/img/small.png"),
              let smallImage = MediaStore.image(at: small, available: available, scale: 2) else {
            check(false, "no small picture"); return
        }
        check(smallImage.size.width == 80,
              "a small picture is not blown up to fill the note: \(smallImage.size.width)")
    }

    /// The same invariant as `checkDrawnMedia`, after typing.
    ///
    /// Every check about drawings measured a note nobody had touched, which is
    /// how this was reported instead of caught: editing a reference left the
    /// text after it behind the drawing until you put blank lines in by hand.
    static func checkMediaSurvivesTyping() {
        let note = """
        Antes.

        ![una grande](resources/img/big.png)

        ```mermaid
        graph TD
            A[Una] --> B[Otra]
        ```

        Después de todo.
        """
        let record = NoteRecord(note: Note(title: "Editando"), filename: "e.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: note)
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 900)
        card.layoutSubtreeIfNeeded()
        let view = card.textView

        /// Does the text after the drawings still start below them?
        ///
        /// Pumps the run loop first, on purpose: the highlighter re-runs on a
        /// `DispatchQueue.main.async` after an edit, so anything that asserts
        /// straight after typing is measuring a note the highlighter has not
        /// touched yet — which is how this whole class of bug stayed invisible.
        func tailClearsDrawings(_ when: String) {
            for _ in 0..<3 {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            card.layoutSubtreeIfNeeded()
            guard let manager = view.layoutManager, let container = view.textContainer else {
                check(false, "no layout manager"); return
            }
            manager.ensureLayout(for: container)
            let tail = (view.string as NSString).range(of: "Después de todo.")
            guard tail.location != NSNotFound else {
                check(false, "the closing line went missing \(when)"); return
            }
            let glyphs = manager.glyphRange(forCharacterRange: tail, actualCharacterRange: nil)
            let box = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let frames = view.debugMediaFrames.sorted { $0.minY < $1.minY }
            guard let last = frames.last else { check(false, "nothing drawn \(when)"); return }
            check(box.minY >= last.maxY - 2,
                  String(format: "the text clears the drawings %@ (%.0f vs %.0f)",
                         when, box.minY, last.maxY))
        }

        tailClearsDrawings("before any typing")

        // Typing inside the image's path — the reference is briefly not one.
        let path = (view.string as NSString).range(of: "big.png")
        view.setSelectedRange(NSRange(location: path.location, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        tailClearsDrawings("while the path is being edited")

        view.insertText("", replacementRange: NSRange(location: path.location, length: 1))
        tailClearsDrawings("and once it is a picture again")

        // And inside the diagram.
        let inside = (view.string as NSString).range(of: "A[Una]")
        view.setSelectedRange(NSRange(location: NSMaxRange(inside), length: 0))
        view.insertText(" --> C[Tercera]", replacementRange: view.selectedRange())
        tailClearsDrawings("after adding a node to the diagram")

        // The highlighter, run the way the app runs it after an edit.
        //
        // Called straight rather than waited for: it goes out on a
        // `DispatchQueue.main.async`, so it always lands *after* the media has
        // reserved its room, and its fenced-code rule sets a paragraph style
        // over the whole block — closing fence included. That deleted the
        // reservation and put the text behind the diagram. A check that types
        // and measures without letting it run sees none of this, which is why
        // four of them passed while the bug was on screen.
        let ns = view.string as NSString
        let fence = ns.range(of: "```", options: .backwards)
        if let storage = view.textStorage,
           let highlighter = storage.delegate as? MarkdownHighlighter,
           fence.location != NSNotFound {
            highlighter.highlight(storage,
                                  in: MarkdownHighlighter.dirtyRange(for: ns.range(of: "A[Una]"),
                                                                     in: ns))
            let style = storage.attribute(.paragraphStyle, at: fence.location,
                                          effectiveRange: nil) as? NSParagraphStyle
            check((style?.paragraphSpacing ?? 0) > 40,
                  String(format: "the room survives a highlighting pass (%.0f pt)",
                         style?.paragraphSpacing ?? 0))
            // And the highlighter's own work survives the room being put back.
            check((style?.headIndent ?? 0) == 10,
                  String(format: "…and the fence is still indented like code (%.0f)",
                         style?.headIndent ?? 0))
        }
        tailClearsDrawings("after the highlighter has been over it")

        // The same for a picture. It is not only the fenced-code rule: a pass
        // begins by setting every attribute in the range it covers, so any line
        // it touches loses its reservation — which is why this was reported for
        // image references as well as diagrams.
        let reference = ns.range(of: "![una grande]")
        if let storage = view.textStorage,
           let highlighter = storage.delegate as? MarkdownHighlighter,
           reference.location != NSNotFound {
            highlighter.highlight(storage,
                                  in: MarkdownHighlighter.dirtyRange(for: reference, in: ns))
            let style = storage.attribute(.paragraphStyle, at: reference.location,
                                          effectiveRange: nil) as? NSParagraphStyle
            check((style?.paragraphSpacing ?? 0) > 40,
                  String(format: "a picture's room survives it too (%.0f pt)",
                         style?.paragraphSpacing ?? 0))
        }
        tailClearsDrawings("after a pass over the picture")

        // And a line typed above everything, which moves every range below it.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Una línea nueva arriba\n", replacementRange: view.selectedRange())
        tailClearsDrawings("after typing a line above them")
    }

    /// Taking a drawing with you.
    static func checkCopyingADrawing() {
        let note = """
        ![una grande](resources/img/big.png)

        ```mermaid
        graph TD
            A[Una] --> B[Otra]
        ```

        Después.
        """
        let record = NoteRecord(note: Note(title: "Copiando"), filename: "c.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: note)
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        // In a real window, so the pointer can be moved the way a pointer is
        // moved: `mouseMoved` converts from window coordinates, and a check
        // that calls the hover method directly proves nothing about what
        // happens when somebody points at a picture.
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.layoutSubtreeIfNeeded()
        let view = card.textView

        /// Points at a spot in the text view, through `mouseMoved`.
        func point(at spot: NSPoint) {
            let inWindow = view.convert(spot, to: nil)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: inWindow,
                                                 modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 0, pressure: 0)
            else { return }
            view.mouseMoved(with: event)
        }

        let frames = view.debugMediaFrames.sorted { $0.minY < $1.minY }
        check(frames.count == 2, "a picture and a diagram to copy: \(frames.count)")
        guard frames.count == 2 else { return }

        check(view.debugMediaCopyFrame == nil, "no mark until the pointer is on one")

        // Over the picture.
        let onPicture = NSPoint(x: frames[0].minX + 20, y: frames[0].midY)
        point(at: onPicture)
        check(view.debugMediaCopyFrame != nil,
              "pointing at a picture offers the mark")
        guard let mark = view.debugMediaCopyFrame else {
            check(false, "no mark over the picture"); return
        }
        check(frames[0].contains(NSPoint(x: mark.midX, y: mark.midY)),
              "and it sits on the drawing, not beside it")

        // The loupe comes with it: the same offer a form's block makes, on a
        // picture. Asked for as "that icon, to open them in a modal and zoom".
        check(!view.mediaLoupe.isHidden, "a picture offers the loupe as well")
        check(!view.mediaLoupe.frame.intersects(mark),
              "…beside the copy mark, not over it: \(view.mediaLoupe.frame) vs \(mark)")
        check(frames[0].contains(NSPoint(x: view.mediaLoupe.frame.midX,
                                         y: view.mediaLoupe.frame.midY)),
              "…and on the drawing too")
        var askedFor: MediaWindow.Subject?
        view.onOpenDrawing = { askedFor = $0 }
        view.mediaLoupe.onOpen?()
        if case .picture(let url)? = askedFor {
            check(url.lastPathComponent == "big.png", "pressing it asks for this picture: \(url)")
        } else {
            check(false, "pressing the picture's loupe asked for \(String(describing: askedFor))")
        }

        // On top of the drawing, not under it. The mark is made once at set-up
        // and the drawings are added later, so it ends up behind them in the
        // subview order — visible to every check that asks whether it is shown,
        // and invisible to anyone actually looking at the note.
        let order = view.subviews
        if let markIndex = order.firstIndex(of: view.mediaCopy),
           let drawingIndex = order.firstIndex(where: { $0 === view.debugMediaViews.first }) {
            check(markIndex > drawingIndex,
                  "the mark is drawn over the picture, not under it "
                  + "(mark at \(markIndex), picture at \(drawingIndex))")
        } else {
            check(false, "could not find the mark and the picture in the same view")
        }

        // Never the general pasteboard in a check: emptying what somebody had
        // copied is not something a test run should do.
        let scratch = NSPasteboard(name: .init("ledge.selftest.copy"))
        check(view.copyHoveredMedia(to: scratch), "the picture is copied")
        check(scratch.canReadObject(forClasses: [NSImage.self], options: nil),
              "and what lands on the clipboard is a picture")
        check(scratch.canReadObject(forClasses: [NSURL.self], options: nil),
              "…and the file too, for dropping into Finder or a mail")

        // Over the diagram.
        let onDiagram = NSPoint(x: frames[1].minX + 20, y: frames[1].midY)
        point(at: onDiagram)
        check(view.debugMediaCopyFrame != nil, "and pointing at a diagram offers it as well")
        check(view.copyHoveredMedia(to: scratch), "the diagram is copied")
        guard let copied = NSImage(pasteboard: scratch) else {
            check(false, "no diagram on the clipboard"); return
        }
        // Copied at its own size rather than at the size a sticky note drew it,
        // and at twice the density, so pasting it somewhere else gives a
        // diagram worth looking at. Measured against the drawing, not against
        // the view's frame — the frame is the width of the note.
        let drawn = view.debugMediaViews
            .sorted { $0.frame.minY < $1.frame.minY }
            .last?.pictureRect?.width ?? 0
        check(drawn > 0, "the diagram was drawn at some size to compare against")
        check(copied.size.width >= drawn - 1,
              String(format: "the diagram is copied no smaller than drawn (%.0f vs %.0f)",
                     copied.size.width, drawn))
        var proposed = NSRect(origin: .zero, size: copied.size)
        let raster = copied.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        check(Double(raster?.width ?? 0) >= copied.size.width * 1.9,
              String(format: "…and at twice the density (%d px for %.0f pt)",
                     raster?.width ?? 0, copied.size.width))

        // And off the drawings again.
        point(at: NSPoint(x: 10, y: frames[0].minY - 30))
        check(view.debugMediaCopyFrame == nil, "and goes away off the drawing")
        scratch.releaseGlobally()
    }

    /// Pasting a picture into a note.
    /// The loupe on a block that defines a form, and what pressing it asks for.
    ///
    /// Through the pointer and through the mark's own action, because the two
    /// things that have gone wrong before are a mark that is never placed and a
    /// mark that is placed and wired to nothing. Never through the window: a
    /// real panel built inside `--selftest` hangs the run.
    static func checkOpeningAForm() {
        let note = """
        Del IDP:

        ```json
        {
          "properties": { "db_name": { "type": "string", "title": "DB Name" } },
          "uiSchema": { "type": "VerticalLayout", "elements": [
            { "type": "Control", "scope": "#/properties/db_name" } ] }
        }
        ```

        ```bash
        kubectl get pods
        ```

        Después.
        """
        let record = NoteRecord(note: Note(title: "Formulario"), filename: "f.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: note)
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 760)
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.layoutSubtreeIfNeeded()
        let view = card.textView

        // A small form fits, so it is drawn on the paper like a diagram is.
        check(view.debugMediaFrames.count == 1,
              "a form that fits is drawn under its block: \(view.debugMediaFrames.count) drawings")
        check(view.codeLoupe.isHidden, "…and needs no mark on the block, the drawing carries one")

        guard let layoutManager = view.layoutManager, let container = view.textContainer else {
            check(false, "the text view has no layout"); return
        }
        layoutManager.ensureLayout(for: container)

        func rect(_ needle: String) -> NSRect {
            let range = (view.string as NSString).range(of: needle)
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var r = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            r.origin.x += view.textContainerOrigin.x
            r.origin.y += view.textContainerOrigin.y
            return r
        }

        // What the press asks for, caught before it can build a window.
        var asked: MediaWindow.Subject?
        view.onOpenDrawing = { asked = $0 }

        // Now one that cannot fit: a form of twenty fields in the same card.
        // The drawing comes off the paper and the block offers the loupe.
        let many = (1...20).map {
            "\"f\($0)\": { \"type\": \"string\", \"title\": \"Field \($0)\" }"
        }.joined(separator: ",\n            ")
        let controls = (1...20).map {
            "{ \"type\": \"Control\", \"scope\": \"#/properties/f\($0)\" }"
        }.joined(separator: ",\n              ")
        view.string = """
        Del IDP:

        ```json
        {
          "properties": {
            \(many)
          },
          "uiSchema": { "type": "VerticalLayout", "elements": [
              \(controls) ] }
        }
        ```

        ```bash
        kubectl get pods
        ```

        Después.
        """
        card.layoutSubtreeIfNeeded()
        view.refreshMedia()
        check(view.debugMediaFrames.isEmpty,
              "a form that cannot fit is not drawn: \(view.debugMediaFrames.count) drawings")

        let onForm = rect("\"uiSchema\"")
        view.updateCodeCopy(at: NSPoint(x: onForm.midX, y: onForm.midY))
        check(!view.codeLoupe.isHidden, "…and its block offers the loupe instead")
        if let whole = view.codeBlockRectForTesting, !view.codeLoupe.isHidden {
            let mark = view.codeLoupe.frame
            check(mark.maxX <= whole.maxX && mark.minX > whole.midX,
                  "the loupe sits at the right-hand end of the block: \(mark.minX) in \(whole)")
            check(abs(mark.minY - whole.minY) < 12, "…at its top: \(mark.minY) vs \(whole.minY)")
            check(!mark.intersects(view.codeCopy.frame),
                  "…beside the copy mark, not on top of it: \(mark) vs \(view.codeCopy.frame)")
        }

        // Pressed the way it is pressed, rather than by calling the method it
        // happens to be wired to.
        view.codeLoupe.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1) ?? NSEvent())
        if case .form(let source)? = asked {
            check(source.contains("uiSchema"), "pressing it asks for this block's form")
        } else {
            check(false, "pressing the loupe asked for \(String(describing: asked))")
        }

        // An ordinary code block has the copy mark and no loupe.
        asked = nil
        let onBash = rect("kubectl get pods")
        view.updateCodeCopy(at: NSPoint(x: onBash.midX, y: onBash.midY))
        check(view.codeCopyFrameForTesting != nil, "a shell block still offers the copy mark")
        check(view.codeLoupe.isHidden, "…and no loupe, because there is no form in it")

        let outside = rect("Después")
        view.updateCodeCopy(at: NSPoint(x: outside.midX, y: outside.midY))
        check(view.codeLoupe.isHidden, "pointing at prose hides the loupe")

        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
    }

    /// Zooming redraws rather than stretches.
    ///
    /// The view on its own, with no window around it — which is also the check
    /// that it can be built that way, since a panel inside `--selftest` hangs.
    static func checkZoomingADrawing() {
        let source = """
        { "properties": { "a": { "type": "string", "title": "Alpha" } },
          "uiSchema": { "type": "VerticalLayout", "elements": [
            { "type": "Control", "scope": "#/properties/a" } ] } }
        """
        let view = MediaZoomView()
        view.configure(.form(source), ink: .black, paper: .white, dark: false)

        guard let atOne = view.debugContentSize else {
            check(false, "a form drew nothing at 1×"); return
        }
        check(atOne.width > 100 && atOne.height > 40, "the form has a size: \(atOne)")

        view.zoomIn()
        guard let bigger = view.debugContentSize else {
            check(false, "a form drew nothing after zooming in"); return
        }
        check(bigger.width > atOne.width, "zooming in widens it: \(bigger.width) vs \(atOne.width)")
        // Both dimensions, because a form laid out wider at the same type size
        // would grow sideways only — and the complaint that started this was
        // that the text was too small, not that the columns were too narrow.
        check(bigger.height > atOne.height,
              "…and makes it taller, so the type grew too: \(bigger.height) vs \(atOne.height)")
        check(view.frame.size == bigger, "the view takes the size of what it drew")

        view.zoomToActualSize()
        check(view.debugContentSize.map { abs($0.width - atOne.width) < 1 } == true,
              "back to 1× is back to the size it started")

        // The stops hold, so a wheel that runs away cannot ask for a 40000 pt
        // bitmap.
        for _ in 0..<40 { view.zoomIn() }
        check(view.zoom <= MediaZoomView.maximum + 0.001, "zoom stops at \(MediaZoomView.maximum)")
        for _ in 0..<80 { view.zoomOut() }
        check(view.zoom >= MediaZoomView.minimum - 0.001, "…and at \(MediaZoomView.minimum)")

        // The size keys arrive as events read by the key monitor, not as a
        // `keyDown` on this view — so the check hands it the same thing the
        // monitor would, including the `+` a Spanish keyboard actually sends.
        view.zoomToActualSize()
        guard let before = view.debugContentSize else { check(false, "nothing drawn"); return }
        for characters in ["+", "="] {
            view.zoomToActualSize()
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 24)
            else { continue }
            guard let command = ZoomKeys.command(for: event) else {
                check(false, "⌘\(characters) was not read as a size key"); continue
            }
            view.apply(command)
            check((view.debugContentSize?.width ?? 0) > before.width,
                  "⌘\(characters) makes the drawing bigger, not the app")
        }

        // ⌘C in the window takes the drawing, and takes it at a readable size
        // rather than at whatever zoom you happened to be looking at.
        view.zoomOut(); view.zoomOut()
        let scratch = NSPasteboard(name: .init("ledge.selftest.zoom"))
        check(view.copyToClipboard(to: scratch), "⌘C copies the form")
        let copied = NSImage(pasteboard: scratch)
        check(copied != nil, "…as a picture")
        if let copied, let onScreen = view.debugContentSize {
            check(copied.size.width > onScreen.width,
                  "…at a size worth pasting, not the 20% you were looking at: "
                  + "\(copied.size.width) vs \(onScreen.width)")
        }
    }

    static func checkPastingAPicture() {
        let record = NoteRecord(note: Note(title: "Pegando"), filename: "p.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: "una línea\notra línea")
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 400)
        card.layoutSubtreeIfNeeded()
        let view = card.textView

        let scratch = NSPasteboard(name: .init("ledge.selftest.paste"))
        scratch.clearContents()
        let picture = NSImage(size: NSSize(width: 60, height: 40))
        picture.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 60, height: 40).fill()
        picture.unlockFocus()
        scratch.writeObjects([picture])

        // Through the door ⌘V actually uses.
        //
        // It is a menu key equivalent, and an item that does not validate never
        // fires: a plain-text view refuses `paste:` when the clipboard holds no
        // text, so with a screenshot on it `paste(_:)` was never called and
        // nothing happened anywhere. The old check called the paste method
        // itself and saw none of that.
        view.pasteboard = scratch
        // The question AppKit asks before it lets ⌘V fire. A plain-text view
        // answers "text", which is why a screenshot on the clipboard left the
        // menu item disabled and `paste(_:)` uncalled. Asserted on the answer
        // itself rather than on a validation call, which needs a window, a
        // first responder and whatever happens to be on the real clipboard to
        // mean anything at all.
        let readable = view.readablePasteboardTypes
        check(readable.contains(.png) && readable.contains(.tiff),
              "a note says it can be handed a picture")
        check(readable.contains(.fileURL), "…and a file")
        check(view.acceptableDragTypes.contains(.png),
              "…including one dragged onto it")

        // At the end of the first line, so the reference has to make room for
        // itself: this only draws a picture on a line of its own.
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.paste(nil)
        check(view.string.contains("![]("), "a picture on the clipboard is pasted")

        let lines = view.string.components(separatedBy: "\n")
        guard let reference = lines.first(where: { $0.hasPrefix("![](") }) else {
            check(false, "no reference was written: \(view.string)"); return
        }
        check(reference.hasSuffix(".png)"), "and it points at a png: \(reference)")
        check(reference.contains(Media.folder),
              "…kept beside the notes, in \(Media.folder): \(reference)")
        check(lines.contains("una línea") && lines.contains("otra línea"),
              "the lines that were there are still there: \(lines)")

        // The file is really on disk, and the note really draws it.
        let path = String(reference.dropFirst(4).dropLast(1))
        guard let url = MediaStore.url(for: path) else {
            check(false, "the path does not resolve: \(path)"); return
        }
        check(FileManager.default.fileExists(atPath: url.path),
              "the picture was written to disk")
        card.layoutSubtreeIfNeeded()
        check(view.debugMediaViews.contains(where: \.debugIsPicture),
              "and the note draws what was pasted")

        // Twice, in the same second, must not be the same file — the first note
        // would change picture underneath you.
        let firstPath = path
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.paste(nil)
        let both = view.string.components(separatedBy: "\n")
            .filter { $0.hasPrefix("![](") }
        check(Set(both).count == 2,
              "and writes a second file rather than replacing the first: \(both)")
        _ = firstPath

        // Text is still text. A browser puts the picture and the words on the
        // clipboard together, and swallowing the words would be worse than not
        // having this.
        let mixed = NSPasteboard(name: .init("ledge.selftest.paste.mixed"))
        mixed.clearContents()
        mixed.writeObjects([picture])
        mixed.setString("algún texto", forType: .string)
        view.pasteboard = mixed
        check(!view.canTakePicture(from: mixed),
              "a clipboard with words on it is not swallowed as a picture")

        func referenceCount() -> Int {
            view.string.components(separatedBy: "\n").filter { $0.hasPrefix("![](") }.count
        }
        let referencesBefore = referenceCount()
        // Only the picture path is asked. Calling `paste(_:)` here would fall
        // through to `super`, which reads the real clipboard whatever this view
        // is pointed at — so it would be measuring whatever happened to be
        // copied on the machine running the checks, which is not a fact about
        // Ledge.
        check(!view.pasteImage(from: mixed), "…the paste is left to the text")
        check(referenceCount() == referencesBefore,
              "…and no picture is written behind your back")

        scratch.releaseGlobally()
        mixed.releaseGlobally()

        // The ceiling. Not compression: a screenshot is left exactly as it is,
        // and only a photograph nobody will ever see at that size is brought
        // down. Measured on the file, because that is what fills the folder.
        let huge = NSPasteboard(name: .init("ledge.selftest.paste.huge"))
        huge.clearContents()
        let big = NSImage(size: NSSize(width: CGFloat(MediaStore.largestEdge) + 800, height: 900))
        big.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(MediaStore.largestEdge) + 800, height: 900).fill()
        big.unlockFocus()
        huge.writeObjects([big])
        view.pasteboard = huge
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.paste(nil)
        if let line = view.string.components(separatedBy: "\n").first(where: { $0.hasPrefix("![](") }),
           let kept = MediaStore.url(for: String(line.dropFirst(4).dropLast(1))),
           let source = CGImageSourceCreateWithURL(kept as CFURL, nil),
           let size = MediaStore.pixelSize(of: source) {
            check(Int(max(size.width, size.height)) <= MediaStore.largestEdge,
                  String(format: "an enormous picture is brought down to the ceiling (%.0f×%.0f)",
                         size.width, size.height))
            check(size.width > size.height, "…keeping its proportions")
        } else {
            check(false, "the enormous picture was not written")
        }
        huge.releaseGlobally()
    }

    /// The diagrams the skill tells an agent to reach for.
    ///
    /// An agent is told, in `skills/ledge/SKILL.md`, which kinds are drawn and
    /// which three are not. That list is a promise made to something that
    /// cannot check it — it will write the fence, and the user will get a quiet
    /// "could not draw this" where they expected a picture. So the promise is
    /// checked here against the renderer itself.
    static func checkDiagramsTheSkillPromises() {
        let drawn: [(String, String)] = [
            ("graph TD", "graph TD\n    A[Uno] --> B{Decide}\n    B -->|sí| C[Hace]"),
            ("graph LR", "graph LR\n    A[Uno] --> B[Dos] --> C[Tres]"),
            ("flowchart", "flowchart TD\n    A[Uno] --> B[Dos]"),
            ("sequenceDiagram", "sequenceDiagram\n    participant A\n    participant B\n    A->>B: pide"),
            ("stateDiagram-v2", "stateDiagram-v2\n    [*] --> Quieto\n    Quieto --> Corriendo: arranca"),
            ("classDiagram", "classDiagram\n    class Nota {\n      +String titulo\n    }"),
            ("erDiagram", "erDiagram\n    NOTA ||--o{ IMAGEN : tiene"),
            ("pie", "pie title Reparto\n    \"Uno\" : 40\n    \"Dos\" : 60"),
        ]
        for (name, source) in drawn {
            check(MediaStore.canDraw(source), "the skill promises \(name), and it draws")
        }

        // And the three it warns off. If one of these starts working, the
        // warning is now wrong in the other direction — still worth knowing.
        for name in ["gantt\n    title Plan\n    section A\n    Tarea :a1, 2026-01-01, 30d",
                     "mindmap\n  root((idea))\n    rama",
                     "timeline\n    title Historia\n    2024 : algo"] {
            check(!MediaStore.canDraw(name),
                  "the skill warns off \(name.prefix(8)), and it is still not drawn")
        }
    }

    /// A drawing on the last line of a note.
    ///
    /// Reported: an agent appended a mermaid block to the end of a note and it
    /// was not drawn; the same block pasted higher up drew fine. And once a
    /// picture is the last thing in a note there is no way to type after it.
    static func checkDrawingAtTheEnd() {
        // Long enough that the text alone fills the card. On a short note the
        // text view is as tall as the card whatever happens, so a drawing past
        // the end lands inside it by luck and the check proves nothing.
        let filler = (1...40).map { "línea \($0) de relleno" }.joined(separator: "\n")
        for (what, tail) in [("a picture", "![](resources/img/small.png)"),
                             ("a diagram", "```mermaid\ngraph TD\n    A[Uno] --> B[Dos]\n```")] {
            let note = filler + "\n\n" + tail
            let record = NoteRecord(note: Note(title: "Final"), filename: "f.md",
                                    mtime: 0, size: 0, hash: "")
            let card = NoteCardView(record: record, body: note)
            card.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
            card.layoutSubtreeIfNeeded()
            let view = card.textView

            check(view.debugMediaCount == 1, "\(what) at the end is found: \(view.debugMediaCount)")
            guard let frame = view.debugMediaFrames.first else {
                check(false, "\(what) at the end has no drawing"); continue
            }
            check(frame.height > 10,
                  String(format: "%@ at the end is drawn (%.0f×%.0f)", what, frame.width, frame.height))

            // The text view's own height is what can be scrolled to, so that is
            // what has to contain the drawing. Measured against the text as
            // well, to be sure the case is the one that used to break: the
            // drawing really does hang past the end of the words.
            if let manager = view.layoutManager, let container = view.textContainer {
                manager.ensureLayout(for: container)
                let text = manager.usedRect(for: container).maxY
                check(frame.maxY > text,
                      String(format: "%@ really does hang past the text (%.0f vs %.0f)",
                             what, frame.maxY, text))
                check(frame.maxY <= view.frame.height + 1,
                      String(format: "%@ at the end is inside what scrolls (%.0f vs %.0f)",
                             what, frame.maxY, view.frame.height))
            }
        }

        // And somewhere to put the caret afterwards. A note whose last line is a
        // picture has nowhere to type: the file is saved with its trailing
        // newlines stripped, so any line you add is taken away again on save.
        let trailing = Frontmatter.normalizedBody("![](resources/img/small.png)\n")
        check(trailing.hasSuffix("\n"),
              "a note ending in a picture keeps somewhere to type: \(trailing.debugDescription)")
    }

    /// What arrives while you are looking at the note.
    ///
    /// An agent writes to the file, the app pulls the change in, and the note
    /// has to *draw* what arrived — not keep it as text until you happen to
    /// type. Reported as a mermaid block appended by an agent that never
    /// appeared; typing anywhere in the note brought it to life, which is what
    /// made it look like a problem with being last.
    static func checkDrawingsArriveFromOutside() {
        let record = NoteRecord(note: Note(title: "Feed"), filename: "s.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: "el agente está trabajando")
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        card.layoutSubtreeIfNeeded()
        let view = card.textView
        check(view.debugMediaCount == 0, "nothing drawn yet")

        // Exactly what the deck does when the file changes underneath it.
        view.syncBody("""
        el agente está trabajando

        ```mermaid
        graph TD
            A[Build] --> B[Deploy]
        ```

        ![](resources/img/small.png)
        """)
        card.layoutSubtreeIfNeeded()

        check(view.debugMediaCount == 2,
              "what an agent wrote is drawn when it arrives: \(view.debugMediaCount)")
        check(view.debugMediaViews.filter(\.debugIsPicture).count == 2,
              "…both of them, actually drawn")

        // A table written from outside is the same promise.
        let other = NoteCardView(record: record, body: "antes")
        other.frame = card.frame
        other.layoutSubtreeIfNeeded()
        other.textView.syncBody("""
        antes

        | Servicio | Estado |
        |---|---|
        | api | ok |
        """)
        other.layoutSubtreeIfNeeded()
        check(other.textView.debugTableCount == 1,
              "and a table too: \(other.textView.debugTableCount)")
    }

    /// A drawing must not move when you press Enter after it.
    ///
    /// Reported: with a picture as the last thing in a note, pressing Enter at
    /// the end of its line made the picture vanish until the next character was
    /// typed. It had not vanished — it had jumped up by its own height, out of
    /// the part of the note you were looking at.
    ///
    /// `boundingRect` swallows the room reserved after a line when that line is
    /// the last one and leaves it out when anything follows, so the drawing sat
    /// below the room at the end of a note and inside it everywhere else.
    static func checkDrawingStaysPutOnEnter() {
        for (what, tail) in [("a picture", "![](resources/img/big.png)"),
                             ("a diagram", "```mermaid\ngraph TD\n    A[Uno] --> B[Dos]\n```")] {
            let body = "una línea\n\n" + tail + "\n"
            let record = NoteRecord(note: Note(title: "Enter"), filename: "n.md",
                                    mtime: 0, size: 0, hash: "")
            let card = NoteCardView(record: record, body: body)
            card.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
            card.layoutSubtreeIfNeeded()
            let view = card.textView

            guard let before = view.debugMediaFrames.first else {
                check(false, "\(what) was not drawn at all"); continue
            }

            // The caret at the end of the line the drawing hangs from, and Enter.
            let text = view.string as NSString
            let anchor = what == "a picture"
                ? text.range(of: "![](", options: .backwards)
                : text.range(of: "```", options: .backwards)
            let line = text.lineRange(for: anchor)
            view.setSelectedRange(NSRange(location: NSMaxRange(line) - 1, length: 0))
            view.insertText("\n", replacementRange: view.selectedRange())
            card.layoutSubtreeIfNeeded()

            guard let after = view.debugMediaFrames.first else {
                check(false, "\(what) disappeared on Enter"); continue
            }
            check(abs(after.minY - before.minY) < 1,
                  String(format: "%@ stays where it was when you press Enter (%.0f → %.0f)",
                         what, before.minY, after.minY))

            // And it is in the room reserved for it, not below it: the gap is
            // what the note laid out, and a drawing beneath the gap is a
            // drawing with a hole above it.
            if let manager = view.layoutManager, let container = view.textContainer {
                manager.ensureLayout(for: container)
                let glyphs = manager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
                let last = max(glyphs.location, NSMaxRange(glyphs) - 1)
                let textBottom = manager.lineFragmentUsedRect(forGlyphAt: last,
                                                              effectiveRange: nil).maxY
                check(abs(after.minY - textBottom) < 2,
                      String(format: "%@ sits directly under its line (%.0f vs %.0f)",
                             what, after.minY, textBottom))
            }
        }
    }

    /// Copying a fenced block, and what comes off with it.
    static func checkCopyingKeepsWhatMatters() {
        let note = """
        antes

        ```bash
        kubectl get pods
        ```

        ```mermaid
        graph TD
            A[Uno] --> B[Dos]
        ```
        """
        let record = NoteRecord(note: Note(title: "Copiar"), filename: "c.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: note)
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        card.layoutSubtreeIfNeeded()
        let view = card.textView
        let scratch = NSPasteboard(name: .init("ledge.selftest.fence"))

        // The shell block: fences off, ready for a terminal.
        let text = view.string as NSString
        view.setSelectedRange(text.range(of: "kubectl get pods"))
        let shell = view.copyBlockAtCaret(to: scratch)
        check(shell == "kubectl get pods",
              "a snippet is copied without its fences: \(shell?.debugDescription ?? "nil")")

        // The diagram: fences on, or what you paste is a page of arrows.
        view.setSelectedRange(text.range(of: "A[Uno]"))
        let diagram = view.copyBlockAtCaret(to: scratch) ?? ""
        check(diagram.hasPrefix("```mermaid"),
              "a diagram keeps the fence that makes it one: \(diagram.prefix(12).debugDescription)")
        check(diagram.hasSuffix("```"), "…and the one that closes it")

        // And the round trip that matters: copy it, paste it, and it is a
        // diagram again — not a fence wrapped in a longer fence. Reported as
        // "lots of ticks, another set of four wrapping the content", which is
        // what fencing an already-fenced block does.
        let elsewhere = NoteCardView(record: record, body: "antes\n")
        elsewhere.frame = card.frame
        elsewhere.layoutSubtreeIfNeeded()
        elsewhere.textView.pasteboard = scratch
        elsewhere.textView.setSelectedRange(NSRange(location: 6, length: 0))
        elsewhere.textView.paste(nil)
        let landed = elsewhere.textView.string
        check(!landed.contains("````"),
              "pasting a copied diagram does not fence it again: \(landed.debugDescription.prefix(40))")
        check(landed.components(separatedBy: "```").count - 1 == 2,
              "exactly one fence, opened and closed: \(landed.components(separatedBy: "```").count - 1) marks")
        check(Media.all(in: landed).count == 1,
              "…and what landed is a diagram: \(Media.all(in: landed).count)")
        elsewhere.layoutSubtreeIfNeeded()
        check(elsewhere.textView.debugMediaViews.contains(where: \.debugIsPicture),
              "…drawn where it was pasted")

        // The real test of that: what came off the clipboard draws.
        let pasted = Media.all(in: diagram)
        check(pasted.count == 1, "what was copied is a diagram again when pasted: \(pasted.count)")
        if case .diagram(let source)? = pasted.first?.kind {
            check(MediaStore.canDraw(source), "…and it draws")
        } else {
            check(false, "what was copied did not read back as a diagram")
        }
        scratch.releaseGlobally()
    }

    /// La fila que dice a qué pertenece una nota.
    static func checkFamilyRow() {
        let madreID = "01MADRE000000000000000000"
        var hija = Note(title: "Modelo de permisos", color: .blue)
        hija.parent = madreID
        let hijaRec = NoteRecord(note: hija, filename: "h.md", mtime: 0, size: 0, hash: "")

        // Una nota sin familia no gasta una fila de su papel.
        let sola = NoteCardView(record: NoteRecord(note: Note(title: "Sola"), filename: "s.md",
                                                   mtime: 0, size: 0, hash: ""), body: "texto")
        sola.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        sola.layoutSubtreeIfNeeded()
        check(sola.family.isHidden, "una nota sin madre ni hijas no muestra la fila")
        let altoSolo = sola.textView.enclosingScrollView?.frame.height ?? 0

        // Una madre lista a sus hijas.
        let madre = NoteCardView(record: NoteRecord(note: Note(title: "Bedrock en el IDP"),
                                                    filename: "m.md", mtime: 0, size: 0, hash: ""),
                                 body: "el proyecto")
        madre.frame = sola.frame
        madre.family.show(children: [hijaRec], mother: nil, isOnStrip: false)
        madre.layoutSubtreeIfNeeded()
        check(!madre.family.isHidden, "una madre sí la muestra")
        check(madre.family.debugLabels == ["Modelo de permisos"],
              "y lista a su hija: \(madre.family.debugLabels)")
        check(madre.family.debugWords == ["Contiene"],
              "con una palabra que dice qué son, o el chip no se explica solo: \(madre.family.debugWords)")
        let altoConFila = madre.textView.enclosingScrollView?.frame.height ?? 0
        check(altoConFila < altoSolo,
              String(format: "la fila le saca alto al texto, no lo tapa (%.0f vs %.0f)",
                     altoConFila, altoSolo))
        check(madre.family.frame.maxY <= madre.debugChromeFrame.minY + 1,
              String(format: "y va encima de los colores, sin pisarlos (%.0f vs %.0f)",
                     madre.family.frame.maxY, madre.debugChromeFrame.minY))

        // Una hija muestra el camino de vuelta y la salida a la tira.
        let cardHija = NoteCardView(record: hijaRec, body: "quién puede invocar")
        cardHija.frame = sola.frame
        cardHija.family.show(children: [], mother: (madreID, "Bedrock en el IDP"), isOnStrip: false)
        cardHija.layoutSubtreeIfNeeded()
        check(cardHija.family.debugLabels == ["‹ Bedrock en el IDP", "Sacar a la tira"],
              "la hija ofrece la vuelta y la salida: \(cardHija.family.debugLabels)")

        // Y lo que hace cada chip, apretado donde se dibuja.
        var abierto: [String] = []
        var sacada: [Bool] = []
        cardHija.onOpenRelative = { abierto.append($0) }
        cardHija.onToggleOnStrip = { sacada.append($0) }
        let chips = cardHija.family.debugChips
        cardHija.family.press(at: NSPoint(x: chips[0].1.midX, y: chips[0].1.midY))
        check(abierto == [madreID], "el chip de la madre la abre: \(abierto)")
        cardHija.family.press(at: NSPoint(x: chips[1].1.midX, y: chips[1].1.midY))
        check(sacada == [true], "y el otro la saca a la tira: \(sacada)")

        // Ya sacada, el mismo botón la guarda.
        cardHija.family.show(children: [], mother: (madreID, "Bedrock en el IDP"), isOnStrip: true)
        cardHija.layoutSubtreeIfNeeded()
        check(cardHija.family.debugLabels.contains("Guardar en la carpeta"),
              "y una vez afuera ofrece volver: \(cardHija.family.debugLabels)")
    }

    /// Escribir `[[` y que ofrezca.
    static func checkLinkPicker() {
        let record = NoteRecord(note: Note(title: "Bedrock en el IDP"), filename: "m.md",
                                mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: "el proyecto\n")
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.layoutSubtreeIfNeeded()
        let view = card.textView
        view.titlesForLinking = { ["Modelo de permisos", "Permisos de KMS", "Office",
                                   "Bedrock en el IDP"] }
        window.makeFirstResponder(view)

        /// Escribe, letra por letra, como una persona.
        func escribir(_ text: String) {
            for ch in text { view.insertText(String(ch), replacementRange: view.selectedRange()) }
        }

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        check(!view.linkPicker.isOpen, "sin escribir nada, no hay selector")

        escribir("ver [[")
        check(view.linkPicker.isOpen, "al abrir los corchetes aparece")
        check(!view.linkPicker.debugRows.contains("Bedrock en el IDP"),
              "y no se ofrece a sí misma: \(view.linkPicker.debugRows)")

        escribir("perm")
        check(view.linkPicker.debugRows.prefix(2) == ["Permisos de KMS", "Modelo de permisos"],
              "filtra y ordena mientras escribís: \(view.linkPicker.debugRows)")
        check(view.linkPicker.debugRows.last?.hasPrefix("Crear") == true,
              "y siempre ofrece crear lo que estás escribiendo: \(view.linkPicker.debugRows)")

        // Nada se crea por escribir.
        var creadas: [(String, Bool)] = []
        view.onCreateLinked = { creadas.append(($0, $1)) }
        check(creadas.isEmpty, "escribir no crea nada")

        // Elegir una existente cierra los corchetes.
        view.linkPicker.move(by: 0)
        view.linkPicker.take()
        check(view.string.contains("[[Permisos de KMS]]"),
              "elegir una la deja enlazada: \(view.string.debugDescription)")
        check(!view.linkPicker.isOpen, "y cierra el selector")
        check(creadas.isEmpty, "elegir una que existe no crea nada")

        // Y el caret queda después del enlace, listo para seguir escribiendo.
        let esperado = (view.string as NSString).range(of: "[[Permisos de KMS]]")
        check(view.selectedRange().location == NSMaxRange(esperado),
              "el caret sigue después del enlace")

        // Ahora una que no existe.
        escribir(" y [[Pruebas de carga")
        check(view.linkPicker.debugRows == ["Crear “Pruebas de carga”"],
              "sin matches, sólo la fila que crea: \(view.linkPicker.debugRows)")
        view.linkPicker.take()
        check(creadas.count == 1 && creadas[0].0 == "Pruebas de carga" && creadas[0].1,
              "⏎ la crea dentro de esta nota: \(creadas)")
        check(view.string.contains("[[Pruebas de carga]]"), "y queda enlazada igual")

        // ⇧⏎ la crea suelta.
        escribir(" y [[Otra suelta")
        view.linkPicker.take(shift: true)
        check(creadas.count == 2 && !creadas[1].1,
              "⇧⏎ la crea con tab propio: \(creadas)")

        // Las teclas de verdad, por `keyDown`, que es donde vive la
        // intercepción: apretar `take()` a mano no prueba que ⏎ llegue ahí.
        func tecla(_ code: UInt16, _ chars: String, shift: Bool = false) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: shift ? .shift : [],
                                           timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
            view.keyDown(with: e)
        }
        escribir(" y [[perm")
        check(view.linkPicker.isOpen, "el selector está abierto para probar las teclas")
        let primera = view.linkPicker.debugSelection
        tecla(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))   // ↓
        check(view.linkPicker.debugSelection == primera + 1,
              "la flecha baja mueve la selección: \(view.linkPicker.debugSelection)")
        let elegida = view.linkPicker.debugRows[view.linkPicker.debugSelection]
        tecla(36, "\r")                                             // ⏎
        check(!view.linkPicker.isOpen, "⏎ cierra el selector")
        check(view.string.contains("[[\(elegida)]]"),
              "y enlaza la fila que estaba marcada: \(elegida)")

        escribir(" y [[algo")
        tecla(53, String(UnicodeScalar(27)!))                        // esc
        check(!view.linkPicker.isOpen, "esc cierra la oferta")
        check(view.string.hasSuffix("[[algo"), "sin tocar lo que escribiste")

        // Y lo que no puede pasar nunca: ofrecer enlaces mientras escribís bash.
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        escribir("```bash\nif [[ -f \"$f\"")
        check(!view.linkPicker.isOpen,
              "dentro de un bloque de código no se ofrece nada")
    }

    /// Every surface that shows a note shows its pictures.
    ///
    /// The same shape as the check about a note on the desk forwarding its
    /// buttons, and for the same reason: the last feature worked on the deck's
    /// card and silently did nothing on the other two.
    static func checkMediaOnEverySurface() {
        let note = "![una chica](resources/img/small.png)\n\ndespués"
        let record = NoteRecord(note: Note(title: "Dibujos"), filename: "m.md",
                                mtime: 0, size: 0, hash: "")

        let card = NoteCardView(record: record, body: note)
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        card.layoutSubtreeIfNeeded()
        check(card.textView.debugMediaViews.contains(where: \.debugIsPicture),
              "the deck's card draws it")

        let float = FloatingNote(record: record, title: "Dibujos", body: note,
                                 size: NSSize(width: 420, height: 300))
        float.cardView.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        float.cardView.layoutSubtreeIfNeeded()
        check(float.cardView.textView.debugMediaViews.contains(where: \.debugIsPicture),
              "a note pulled onto the desk draws it")

        let editor = NoteEditorWindow(record: record, title: "Dibujos", body: note)
        editor.debugLayout()
        check(editor.textView.debugMediaViews.contains(where: \.debugIsPicture),
              "and the big editor draws it")
    }

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

    /// Coming back to a note you were reading.
    ///
    /// A card is torn down and rebuilt whenever you open a different note, so
    /// the place you had reached went with it — reported on a long note read at
    /// line eighty and returned to at line one.
    static func checkReadingPositionIsKept(deck: DeckController) async {
        await deck.refresh()
        let ids = deck.recordsForTesting.map(\.id)
        guard ids.count >= 2 else { check(false, "need two notes"); return }

        // A note long enough to have somewhere to come back to.
        let long = (1...90).map { "línea número \($0) de una nota larga" }.joined(separator: "\n")
        deck.debugEdit(id: ids[0], body: long)
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(700))
        await deck.refresh()

        deck.fanOut(takingFocus: false)
        deck.previewForTesting(ids[0])
        deck.debugScrollCard(to: 600)
        let left = deck.debugCardScroll ?? 0
        check(left > 100,
              String(format: "the note is long enough to scroll (stopped at %.0f)", left))

        // Away to another note, and back.
        deck.previewForTesting(ids[1])
        check((deck.debugCardScroll ?? -1) == 0, "a different note opens at its own beginning")
        deck.previewForTesting(ids[0])
        try? await Task.sleep(for: .milliseconds(300))
        let back = deck.debugCardScroll ?? 0
        check(abs(back - left) < 2,
              String(format: "coming back puts you where you were (%.0f, was %.0f)", back, left))

        // And a note that got shorter while you were away does not open on
        // blank paper below its own end.
        deck.debugEdit(id: ids[0], body: "ahora es corta")
        deck.debugCommit()
        try? await Task.sleep(for: .milliseconds(700))
        deck.previewForTesting(ids[1])
        deck.previewForTesting(ids[0])
        try? await Task.sleep(for: .milliseconds(300))
        check((deck.debugCardScroll ?? 0) < 2,
              String(format: "a note that shrank opens at its top rather than past its end (%.0f)",
                     deck.debugCardScroll ?? 0))
        deck.closeNote()
    }

    /// A note you cannot put away.
    ///
    /// Reported after switching monitors with a note open: neither Close nor
    /// the strip would fold it back, and only quitting cleared it. The shape of
    /// it is that the deck's state says no note is open while the card is still
    /// on screen — and everything that closes one asks the state first.
    ///
    /// Reproduced through the path that certainly does it: the open note leaves
    /// the deck's records, which is what happens when something else archives
    /// it, moves it to another strip, or when the strip it lived on goes away
    /// with a display.
    static func checkAnOpenNoteCanAlwaysBeClosed(deck: DeckController) async {
        await deck.refresh()
        guard let record = deck.recordsForTesting.first else { check(false, "no note"); return }

        deck.fanOut(takingFocus: false)
        deck.previewForTesting(record.id)
        check(deck.debugHasCard, "the note is open")

        // It goes away underneath you.
        try? await deck.archiveElsewhereForTesting(id: record.id)
        await deck.refresh()

        check(!deck.debugHasCard,
              "a note that left the deck takes its card with it, rather than leaving one "
              + "on screen that nothing can close")

        // And whatever else may put the two out of step in future, closing has
        // to act on what is on screen rather than on what the state believes.
        if let other = deck.recordsForTesting.first?.id {
            deck.previewForTesting(other)
            deck.closeNote()
            check(!deck.debugHasCard, "Close closes it")
        }

        try? await deck.restoreForTesting(id: record.id)
        await deck.refresh()
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
        checkDrawnMedia()
        checkMediaOnEverySurface()
        checkMediaSurvivesTyping()
        checkCopyingADrawing()
        checkOpeningAForm()
        checkZoomingADrawing()
        checkPastingAPicture()
        checkDiagramsTheSkillPromises()
        checkDrawingAtTheEnd()
        checkDrawingsArriveFromOutside()
        checkDrawingStaysPutOnEnter()
        checkCopyingKeepsWhatMatters()
        checkFamilyRow()
        checkLinkPicker()
        checkLinkOpensOnClick()
        checkEditorKeys()
        checkPastingMinifiedJSON()
        checkTheDeskGetsEverything()
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
        await checkDeletingABigBlockSticks(deck: deck, folder: deck.notesFolder)
        await checkPressingALinkThatDoesNotExistYet(deck: deck, folder: deck.notesFolder)
        await checkCreatingAChildByTyping(deck: deck, folder: deck.notesFolder)
        await checkFamilyChipOpensTheChild(deck: deck, folder: deck.notesFolder)
        await checkOpeningAChild(deck: deck, folder: deck.notesFolder)
        await checkAgentDiagramArrives(deck: deck, folder: deck.notesFolder)
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
        await checkReadingPositionIsKept(deck: deck)
        await checkAnOpenNoteCanAlwaysBeClosed(deck: deck)
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
