import AppKit
import LedgeCore
import LedgeIndex

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
        checkMarkdownEditing()
        checkCodeFormatting()
        checkChromeDegradation()
        checkPressAndSettle()

        print("\n\u{001B}[1mLabel rendering\u{001B}[0m")
        checkLabelDirection()
        checkLabelPlacement()

        print("\n\u{001B}[1mSaving\u{001B}[0m")
        await checkSaving(deck: deck, folder: deck.notesFolder)

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
        check(fan.tabs.allSatisfy { $0.minX >= -0.5 && $0.maxX <= fan.panel.width + 0.5 },
              "the whole row fits inside the panel")

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
        check(fan.tabs.allSatisfy { $0.width >= Metrics.Tab.width && $0.width <= Metrics.Tab.width + 2.5 },
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
            check(zip(deck.debugTitles(), lengths).sorted { $0.0.count < $1.0.count }
                    .map(\.1) == lengths.sorted(),
                  "tab length follows title length, in order")
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
        check(fan.tabs.allSatisfy { $0.minY >= 0 && $0.maxY <= fan.panel.height },
              "the whole stack fits inside the panel")
        check(fan.plus.minY > (fan.tabs.last?.maxY ?? 0), "the + sits below the last tab")
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
