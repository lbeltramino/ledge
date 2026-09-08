import AppKit

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

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .dotMatchesLineSeparators])
    }

    private func buildRules() {
        // Order matters: a fenced block claims its range before the inline rules
        // get a chance to pick apart the backticks inside it.
        func rule(_ pattern: String,
                  _ apply: @escaping (NSTextStorage, NSTextCheckingResult, MarkdownHighlighter) -> Void) {
            if let regex = MarkdownHighlighter.regex(pattern) { rules.append(Rule(regex: regex, apply: apply)) }
        }

        // # Heading — the hashes recede, the words grow
        rule("^(#{1,6})\\s+(.+)$") { storage, match, this in
            let level = match.range(at: 1).length
            let scale = [1.55, 1.38, 1.24, 1.14, 1.07, 1.0][min(level - 1, 5)]
            let font = this.resized(this.baseFont, by: scale, bold: true)
            storage.addAttribute(.font, value: font, range: match.range(at: 2))
            storage.addAttribute(.foregroundColor, value: this.ink, range: match.range(at: 2))
            this.fade(storage, match.range(at: 1), 0.28)
        }

        // - list item — the marker hangs and dims
        rule("^\\s*([-*+]|\\d+\\.)\\s+") { storage, match, this in
            this.fade(storage, match.range(at: 1), 0.40)
        }

        // > quote
        rule("^\\s*(>)\\s?(.*)$") { storage, match, this in
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
        rule("^```[^\n]*\n([\\s\\S]*?)^```[ \t]*$") { storage, match, this in
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
                                 range: match.range(at: 1))

            let body = match.range(at: 1)
            this.fade(storage, NSRange(location: whole.location,
                                       length: max(0, body.location - whole.location)), 0.30)
            this.fade(storage, NSRange(location: body.upperBound,
                                       length: max(0, whole.upperBound - body.upperBound)), 0.30)
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
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: ink], range: full)
        let text = storage.string
        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                rule.apply(storage, match, self)
            }
        }
        storage.endEditing()
    }

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Re-running on the whole note is fine: a sticky note is short, and
        // paragraph-scoped highlighting gets multi-line spans wrong.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.highlight(textStorage) }
        }
    }
}
