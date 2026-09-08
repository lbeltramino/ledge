import AppKit
import LedgeCore

/// The editing half of Markdown support. Highlighting shows you what the syntax
/// means; this puts the syntax there for you, so the editor is something you can
/// actually write in rather than a text box that happens to colour hashes.
@MainActor
enum MarkdownEditing {

    /// Wraps or unwraps the selection — ⌘B, ⌘I, code.
    static func wrap(_ textView: NSTextView, with marker: String) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let text = storage.string as NSString
        let markerLength = (marker as NSString).length

        // Already wrapped? Take it off again.
        let outer = NSRange(location: selection.location - markerLength,
                            length: selection.length + markerLength * 2)
        if outer.location >= 0, outer.upperBound <= text.length,
           text.substring(with: outer).hasPrefix(marker),
           text.substring(with: outer).hasSuffix(marker) {
            let inner = text.substring(with: selection)
            replace(textView, range: outer, with: inner)
            textView.setSelectedRange(NSRange(location: outer.location, length: (inner as NSString).length))
            return
        }

        let selected = text.substring(with: selection)
        let wrapped = marker + selected + marker
        replace(textView, range: selection, with: wrapped)
        if selected.isEmpty {
            textView.setSelectedRange(NSRange(location: selection.location + markerLength, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: selection.location + markerLength,
                                              length: (selected as NSString).length))
        }
    }

    /// Adds or removes a line prefix on every line the selection touches —
    /// headings, list items, quotes.
    static func togglePrefix(_ textView: NSTextView, _ prefix: String) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let lines = text.lineRange(for: textView.selectedRange())
        var rebuilt: [String] = []
        var allHavePrefix = true

        let existing = text.substring(with: lines).components(separatedBy: "\n")
        for line in existing where !(line.isEmpty && existing.count > 1) {
            if !line.hasPrefix(prefix) { allHavePrefix = false }
        }
        for line in existing {
            if line.isEmpty { rebuilt.append(line); continue }
            rebuilt.append(allHavePrefix ? String(line.dropFirst(prefix.count)) : prefix + line)
        }

        let replacement = rebuilt.joined(separator: "\n")
        replace(textView, range: lines, with: replacement)
        textView.setSelectedRange(NSRange(location: lines.location,
                                          length: (replacement as NSString).length))
    }

    /// Code, in whichever form the selection actually needs.
    ///
    /// A single backtick cannot span lines — Markdown says so — so wrapping a
    /// multi-line selection in them produces two stray ticks and no formatting
    /// at all. More than one line means a fenced block.
    static func code(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let text = storage.string as NSString
        let selected = text.substring(with: selection)

        // Inside a block already? Then this is the off switch — whether the
        // whole thing is selected or the caret is just sitting in it, which is
        // where fencing leaves it.
        if let fence = enclosingFence(in: text, at: selection) {
            let inner = text.substring(with: fence.body)
            replace(textView, range: fence.whole, with: inner)
            textView.setSelectedRange(NSRange(location: fence.whole.location,
                                              length: (inner as NSString).length))
            return
        }

        guard selected.contains("\n") else {
            wrap(textView, with: "`")
            return
        }

        // Take the whole lines the selection touches, so the fences land clean.
        let lines = text.lineRange(for: selection)
        var body = text.substring(with: lines)
        let trailingNewline = body.hasSuffix("\n")
        if trailingNewline { body.removeLast() }

        let fenced = "```\n" + body + "\n```" + (trailingNewline ? "\n" : "")
        replace(textView, range: lines, with: fenced)
        // caret parked in the language slot, ready to type `swift`
        textView.setSelectedRange(NSRange(location: lines.location + 3, length: 0))
    }

    /// The fenced block containing `selection`, if there is one.
    private static func enclosingFence(in text: NSString,
                                       at selection: NSRange) -> (whole: NSRange, body: NSRange)? {
        guard let regex = try? NSRegularExpression(pattern: "^```[^\n]*\n([\\s\\S]*?)^```[ \t]*$",
                                                   options: [.anchorsMatchLines,
                                                             .dotMatchesLineSeparators])
        else { return nil }
        let full = NSRange(location: 0, length: text.length)
        for match in regex.matches(in: text as String, range: full) {
            let whole = match.range
            guard selection.location >= whole.location,
                  selection.upperBound <= whole.upperBound else { continue }
            var body = match.range(at: 1)
            // drop the newline the closing fence sits on
            if body.length > 0, text.substring(with: NSRange(location: body.upperBound - 1, length: 1)) == "\n" {
                body.length -= 1
            }
            return (whole, body)
        }
        return nil
    }

    /// Turns the selected lines into tasks, or back again.
    static func toggleTask(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let lines = text.lineRange(for: textView.selectedRange())
        let existing = text.substring(with: lines).components(separatedBy: "\n")

        let alreadyTasks = existing.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { Checkbox.items(in: $0).count == 1 }

        let rebuilt = existing.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if alreadyTasks, let item = Checkbox.items(in: line).first {
                return (line as NSString).substring(with: item.content)
            }
            // keep an existing bullet, otherwise add one
            if let match = try? NSRegularExpression(pattern: "^([ \\t]*)([-*+])[ \\t]+")
                .firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let prefix = (line as NSString).substring(with: match.range)
                return prefix + "[ ] " + (line as NSString).substring(from: match.range.length)
            }
            return "- [ ] " + line
        }.joined(separator: "\n")

        replace(textView, range: lines, with: rebuilt)
        textView.setSelectedRange(NSRange(location: lines.location,
                                          length: (rebuilt as NSString).length))
    }

    /// A link, with the caret left where you would type next.
    static func link(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let label = (storage.string as NSString).substring(with: selection)
        let text = "[\(label.isEmpty ? "link" : label)](url)"
        replace(textView, range: selection, with: text)
        let urlOffset = (text as NSString).length - 4
        textView.setSelectedRange(NSRange(location: selection.location + urlOffset, length: 3))
    }

    /// Enter inside a list continues the list; Enter on an empty item ends it.
    /// Returns true when it handled the key.
    static func continueList(_ textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let text = storage.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0 else { return false }
        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let line = text.substring(with: lineRange)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))

        // A task list continues as a task list, not as a plain bullet.
        if let next = Checkbox.continuation(after: line) {
            if next.isEmpty {
                replace(textView, range: lineRange, with: "")
                textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            } else {
                let insertion = "\n" + next
                replace(textView, range: caret, with: insertion)
                textView.setSelectedRange(NSRange(location: caret.location + (insertion as NSString).length,
                                                  length: 0))
            }
            return true
        }

        guard let match = try? NSRegularExpression(pattern: "^(\\s*)([-*+]|(\\d+)\\.)\\s+")
            .firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return false }

        let indent = (line as NSString).substring(with: match.range(at: 1))
        let marker = (line as NSString).substring(with: match.range(at: 2))
        let content = (line as NSString).substring(from: match.range.length)

        // An empty item means "I am done with this list": the marker goes away
        // and the caret stays on the now-blank line, rather than adding one.
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            replace(textView, range: lineRange, with: "")
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return true
        }

        let next: String
        if match.range(at: 3).location != NSNotFound,
           let number = Int((line as NSString).substring(with: match.range(at: 3))) {
            next = "\n\(indent)\(number + 1). "
        } else {
            next = "\n\(indent)\(marker) "
        }
        replace(textView, range: caret, with: next)
        textView.setSelectedRange(NSRange(location: caret.location + (next as NSString).length, length: 0))
        return true
    }

    /// Goes through the undo manager, so every one of these is undoable and the
    /// delegate sees the change.
    private static func replace(_ textView: NSTextView, range: NSRange, with string: String) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
    }
}
