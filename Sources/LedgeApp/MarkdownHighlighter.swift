import AppKit
import LedgeCore

/// Live Markdown highlighting, applied as you type.
///
/// Not a preview pane: the source is always there and always editable, the
/// syntax just steps back. `**` fades to a third of its opacity rather than
/// disappearing, list markers hang and dim, and anything you might paste into a
/// terminal — code, URLs — drops to a monospace so it stays exactly readable
/// even when the body is handwritten.
@MainActor
final class MarkdownHighlighter: NSObject, @preconcurrency NSTextStorageDelegate {

    var baseFont: NSFont
    var ink: NSColor
    var accent: NSColor
    /// The colour a `==highlight==` is swiped in — the note's own hue, deepened.
    var highlight: NSColor = .systemYellow.withAlphaComponent(0.45)

    private struct Rule {
        let regex: NSRegularExpression
        let apply: (NSTextStorage, NSTextCheckingResult, MarkdownHighlighter) -> Void
    }
    private var rules: [Rule] = []

    init(baseFont: NSFont, ink: NSColor, accent: NSColor) {
        self.baseFont = baseFont
        self.ink = ink
        self.accent = accent
        super.init()
        buildRules()
    }

    /// Deliberately *without* `.dotMatchesLineSeparators`.
    ///
    /// It was added once so a fenced block could span lines, and it made every
    /// line-oriented rule wrong: `^(#{1,6})\\s+(.+)$` stopped at the end of the
    /// heading only by luck, and in practice swallowed the whole note below it.
    /// The fenced rule matches across lines with `[\\s\\S]` instead, which needs
    /// no option and cannot leak into anything else.
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private func buildRules() {
        // Order matters: a fenced block claims its range before the inline rules
        // get a chance to pick apart the backticks inside it.
        func rule(_ pattern: String,
                  _ apply: @escaping (NSTextStorage, NSTextCheckingResult, MarkdownHighlighter) -> Void) {
            if let regex = MarkdownHighlighter.regex(pattern) { rules.append(Rule(regex: regex, apply: apply)) }
        }

        // # Heading — the hashes recede, the words grow
        rule("^(#{1,6})[ \\t]+([^\\n]+)$") { storage, match, this in
            let level = match.range(at: 1).length
            let scale = [1.55, 1.38, 1.24, 1.14, 1.07, 1.0][min(level - 1, 5)]
            let font = this.resized(this.baseFont, by: scale, bold: true)
            storage.addAttribute(.font, value: font, range: match.range(at: 2))
            storage.addAttribute(.foregroundColor, value: this.ink, range: match.range(at: 2))
            this.fade(storage, match.range(at: 1), 0.28)
        }

        // - [ ] tasks. The marker recedes; a finished one is struck through and
        // steps back, so what is left to do is what stands out.
        rule(Checkbox.pattern) { storage, match, this in
            let markerEnd = match.range(at: 3).location + 2
            this.fade(storage, NSRange(location: match.range.location,
                                       length: markerEnd - match.range.location), 0.45)
            let state = Checkbox.State(mark: (storage.string as NSString)
                .substring(with: match.range(at: 3)))

            // In progress: the slash is painted out and half a tick is drawn
            // where it was. See ProgressTick.
            if state == .doing {
                storage.addAttribute(.foregroundColor, value: NSColor.clear,
                                     range: match.range(at: 3))
                storage.addAttribute(ProgressTick.attribute, value: this.accent,
                                     range: match.range(at: 3))
            }

            let done = state == .done
            let content = match.range(at: 4)
            guard content.length > 0 else { return }
            if done {
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: content)
                storage.addAttribute(.foregroundColor,
                                     value: this.ink.withAlphaComponent(0.42), range: content)
            } else {
                storage.addAttribute(.foregroundColor, value: this.ink, range: content)
            }
        }

        // ==highlighted== — the syntax Obsidian and the CommonMark extensions
        // use, so the file stays readable anywhere. The colour is not in the
        // text: it comes from the note, which is what keeps one highlight
        // portable and still not the same yellow in every note.
        rule("(==)([^=\n]+)(==)") { storage, match, this in
            storage.addAttribute(MarkerStroke.attribute, value: this.highlight,
                                 range: match.range(at: 2))
            storage.addAttribute(.foregroundColor, value: this.ink, range: match.range(at: 2))
            this.fade(storage, match.range(at: 1), 0.22)
            this.fade(storage, match.range(at: 3), 0.22)
        }

        // [[links between notes]]
        rule(Wikilink.pattern) { storage, match, this in
            storage.addAttribute(.foregroundColor, value: this.accent, range: match.range(at: 1))
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                 range: match.range(at: 1))
            let open = NSRange(location: match.range.location, length: 2)
            let close = NSRange(location: match.range.upperBound - 2, length: 2)
            this.fade(storage, open, 0.30)
            this.fade(storage, close, 0.30)
        }

        // - list item — the marker hangs and dims
        rule("^[ \\t]*([-*+]|\\d+\\.)[ \\t]+") { storage, match, this in
            this.fade(storage, match.range(at: 1), 0.40)
        }

        // > quote
        rule("^[ \\t]*(>)[ \\t]?([^\\n]*)$") { storage, match, this in
            this.fade(storage, match.range(at: 1), 0.35)
            storage.addAttribute(.foregroundColor,
                                 value: this.ink.withAlphaComponent(0.72),
                                 range: match.range(at: 2))
        }

        // **bold**
        rule("(\\*\\*)([^*\\n]+)(\\*\\*)") { storage, match, this in
            storage.addAttribute(.font, value: this.resized(this.baseFont, by: 1, bold: true),
                                 range: match.range(at: 2))
            this.fade(storage, match.range(at: 1), 0.30)
            this.fade(storage, match.range(at: 3), 0.30)
        }

        // *italic* / _italic_ — obliqueness works for faces with no italic cut,
        // which includes the handwriting
        rule("(?<![*\\w])([*_])([^*_\\n]+)([*_])(?![*\\w])") { storage, match, this in
            storage.addAttribute(.obliqueness, value: 0.16, range: match.range(at: 2))
            this.fade(storage, match.range(at: 1), 0.30)
            this.fade(storage, match.range(at: 3), 0.30)
        }

        // ```fenced blocks``` — the whole run becomes one panel, fences
        // included, rather than three separately coloured lines. Declared before
        // the inline rules so it claims its range first.
        rule("^(```|~~~)([^\n]*)\n([\\s\\S]*?)^\\1[ \t]*$") { storage, match, this in
            let whole = match.range
            storage.addAttribute(.font, value: this.mono(), range: whole)
            storage.addAttribute(.backgroundColor,
                                 value: this.ink.withAlphaComponent(0.07), range: whole)
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 10
            paragraph.headIndent = 10
            paragraph.tailIndent = -10
            storage.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            storage.addAttribute(.foregroundColor, value: this.ink.withAlphaComponent(0.88),
                                 range: match.range(at: 3))

            let body = match.range(at: 3)
            this.fade(storage, NSRange(location: whole.location,
                                       length: max(0, body.location - whole.location)), 0.30)
            this.fade(storage, NSRange(location: body.upperBound,
                                       length: max(0, whole.upperBound - body.upperBound)), 0.30)

            // ```yaml, ```hcl, ```go — the tag on the fence, which until now was
            // parsed and thrown away.
            let tag = (storage.string as NSString).substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespaces).lowercased()
            this.paintCode(storage, body: body, language: tag)
        }

        // An indented code block: four spaces or a tab after a blank line.
        // Markdown's other way of writing one, and what you get by pasting from
        // a terminal.
        rule("(?:(?<=\n\n)|\\A)((?:(?:[ ]{4}|\t)[^\n]*(?:\n|$))+)") { storage, match, this in
            let block = match.range(at: 1)
            let text = (storage.string as NSString).substring(with: block)
            // A nested list item also begins with four spaces. It is not code.
            let firstLine = text.components(separatedBy: "\n").first ?? ""
            let stripped = String(firstLine.drop { $0 == " " || $0 == "\t" })
            guard MarkdownText.marker(of: stripped) == nil else { return }

            storage.addAttribute(.font, value: this.mono(), range: block)
            storage.addAttribute(.backgroundColor,
                                 value: this.ink.withAlphaComponent(0.07), range: block)
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 10
            paragraph.headIndent = 10
            storage.addAttribute(.paragraphStyle, value: paragraph, range: block)
        }

        // `code`
        rule("(`)([^`\\n]+)(`)") { storage, match, this in
            storage.addAttribute(.font, value: this.mono(), range: match.range(at: 2))
            this.fade(storage, match.range(at: 1), 0.30)
            this.fade(storage, match.range(at: 3), 0.30)
        }

        // [text](url)
        rule("\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)") { storage, match, this in
            storage.addAttribute(.foregroundColor, value: this.accent, range: match.range(at: 1))
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                 range: match.range(at: 1))
            let url = (storage.string as NSString).substring(with: match.range(at: 2))
            if let link = URL(string: url) {
                storage.addAttribute(.link, value: link, range: match.range(at: 1))
            }
            this.fade(storage, match.range, 0.55, only: [match.range(at: 2)])
        }

        // #tags — written in the note, like everything else about it
        rule(Tags.pattern) { storage, match, this in
            storage.addAttribute(.foregroundColor, value: this.accent, range: match.range)
            storage.addAttribute(.font,
                                 value: this.resized(this.baseFont, by: 1, bold: true),
                                 range: match.range)
        }

        // a bare URL stays exactly readable
        rule("(?<![(\\]])\\bhttps?://[^\\s)]+") { storage, match, this in
            storage.addAttribute(.font, value: this.mono(), range: match.range)
            storage.addAttribute(.foregroundColor, value: this.accent, range: match.range)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                 range: match.range)
            if let link = URL(string: (storage.string as NSString).substring(with: match.range)) {
                storage.addAttribute(.link, value: link, range: match.range)
            }
        }
    }

    /// Colours the inside of a fenced block according to its language.
    ///
    /// Two hues and four weights, both taken from the note itself: structure in
    /// ink, values in the accent, comments faded back. A syntax theme with its
    /// own palette would fight the paper — and there are eleven paper colours.
    private func paintCode(_ storage: NSTextStorage, body: NSRange, language: String) {
        guard body.length > 0, Code.grammar(for: language) != nil else { return }
        let source = (storage.string as NSString).substring(with: body)
        let bold = NSFont.monospacedSystemFont(ofSize: mono().pointSize, weight: .semibold)

        for token in Code.tokens(in: source, language: language) {
            let range = NSRange(location: body.location + token.range.location,
                                length: token.range.length)
            guard range.upperBound <= storage.length else { continue }
            switch token.role {
            case .comment:
                storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.40),
                                     range: range)
                storage.addAttribute(.obliqueness, value: 0.14, range: range)
            case .string:
                storage.addAttribute(.foregroundColor, value: accent.withAlphaComponent(0.90),
                                     range: range)
            case .number:
                storage.addAttribute(.foregroundColor, value: accent.withAlphaComponent(0.72),
                                     range: range)
            case .keyword:
                storage.addAttribute(.foregroundColor, value: ink, range: range)
                storage.addAttribute(.font, value: bold, range: range)
            case .key:
                storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.92),
                                     range: range)
                storage.addAttribute(.font, value: bold, range: range)
            }
        }
    }

    private func fade(_ storage: NSTextStorage, _ range: NSRange, _ alpha: CGFloat,
                      only: [NSRange] = []) {
        let targets = only.isEmpty ? [range] : only
        for target in targets where target.location != NSNotFound {
            storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(alpha), range: target)
        }
    }

    private func resized(_ font: NSFont, by scale: CGFloat, bold: Bool) -> NSFont {
        let sized = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
        guard bold else { return sized }
        return NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask)
    }

    private func mono() -> NSFont {
        .monospacedSystemFont(ofSize: baseFont.pointSize * 0.78, weight: .regular)
    }

    // MARK: - applying

    func highlight(_ storage: NSTextStorage) {
        highlight(storage, in: NSRange(location: 0, length: storage.length))
    }

    /// Re-applies the rules over `range`, which must start and end on line
    /// boundaries — `^` and `$` are matched against the range's edges.
    func highlight(_ storage: NSTextStorage, in range: NSRange) {
        guard range.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: ink], range: range)
        let text = storage.string
        for rule in rules {
            // Two separate permissions, and both are needed. `transparentBounds`
            // lets a lookbehind read the text before the range — without it the
            // indented-code rule cannot see the blank line that qualifies its
            // block, and the block silently stops being code. `withoutAnchoring
            // Bounds` stops `^` and `$` matching at the range's edges just
            // because they are edges; the range is always aligned to line
            // boundaries, so they still land where they should.
            rule.regex.enumerateMatches(in: text,
                                        options: [.withTransparentBounds, .withoutAnchoringBounds],
                                        range: range) { match, _, _ in
                guard let match else { return }
                rule.apply(storage, match, self)
            }
        }
        storage.endEditing()
    }

    /// The smallest range that can be re-highlighted correctly after an edit.
    ///
    /// Paragraph bounds are not enough on their own: a fenced code block spans
    /// lines, and re-running the rules over half of one would style it as
    /// ordinary text. So the range grows to swallow any fence it lands inside —
    /// which is rare, and cheap to detect.
    static func dirtyRange(for edited: NSRange, in text: NSString) -> NSRange {
        var range = text.lineRange(for: NSRange(location: min(edited.location, text.length),
                                                length: min(edited.length, text.length - min(edited.location, text.length))))

        let fences = fenceLines(in: text)
        guard !fences.isEmpty else { return range }

        // An odd number of fences before the start means the edit began inside a
        // block; the same at the end means it finished inside one.
        if let opening = fences.last(where: { $0.location < range.location }),
           fences.filter({ $0.location < range.location }).count % 2 == 1 {
            range = NSRange(location: opening.location, length: range.upperBound - opening.location)
        }
        if let closing = fences.first(where: { $0.location >= range.upperBound }),
           fences.filter({ $0.location < range.upperBound }).count % 2 == 1 {
            range.length = closing.upperBound - range.location
        }
        return NSRange(location: range.location,
                       length: min(range.length, text.length - range.location))
    }

    private static let fenceRegex = try? NSRegularExpression(
        pattern: "^(?:```|~~~)[^\n]*$", options: [.anchorsMatchLines])

    private static func fenceLines(in text: NSString) -> [NSRange] {
        fenceRegex?.matches(in: text as String,
                            range: NSRange(location: 0, length: text.length)).map(\.range) ?? []
    }

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Only the lines that changed, grown to cover any fenced block they sit
        // inside. Re-running over the whole note cost 26 ms a keystroke at a
        // thousand lines, which is a stutter you can feel.
        let dirty = MarkdownHighlighter.dirtyRange(for: editedRange,
                                                   in: textStorage.string as NSString)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.highlight(textStorage, in: dirty) }
        }
    }
}
