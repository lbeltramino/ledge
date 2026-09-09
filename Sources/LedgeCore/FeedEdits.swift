import Foundation

/// The edits something other than you is allowed to make to a note.
///
/// Every one of them is local: it appends, or it changes one line. None of them
/// rewrites the body, because an agent doing read-modify-write on the whole note
/// while you are typing means one of you loses — and with a 250 ms autosave, you
/// are typing more often than it looks.
public enum FeedEdit {

    /// Adds a block at the end, separated by a blank line.
    ///
    /// A feed is a sequence of entries, so they are kept apart. Something that
    /// belongs *to* the last entry is not an append — it is an edit of it, and
    /// that is not on offer.
    public static func appending(_ block: String, to body: String) -> String {
        let addition = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return body }
        let existing = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty else { return addition }
        return existing + "\n\n" + addition
    }

    /// Adds an unticked task, beside the others if there are any.
    ///
    /// A checklist an agent is working through should stay one list, not grow a
    /// second one below every note it leaves.
    public static func addingTask(_ text: String, to body: String) -> String {
        let item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty else { return body }

        let items = Checkbox.items(in: body)
        guard let last = items.last else {
            return appending("- [ ] " + item, to: body)
        }
        // Match the indent of the list it joins.
        let source = body as NSString
        let line = source.substring(with: last.line)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let insertion = "\n" + indent + "- [ ] " + item
        return source.replacingCharacters(in: NSRange(location: last.line.upperBound, length: 0),
                                          with: insertion)
    }

    public struct Ticked: Sendable, Equatable {
        public let body: String
        /// False when the item was already in the state asked for — worth
        /// saying, because an agent repeating itself should not look like work.
        public let changed: Bool
        public let item: String
    }

    /// Ticks (or unticks) the first task whose text contains `needle`.
    ///
    /// Matching on the text rather than an index because an agent that
    /// remembers "item 3" will tick the wrong thing the moment you add one.
    public static func setting(_ done: Bool, matching needle: String,
                               in body: String) -> Ticked? {
        let source = body as NSString
        let wanted = fold(needle)
        guard !wanted.isEmpty else { return nil }

        for item in Checkbox.items(in: body) {
            let text = source.substring(with: item.content)
            guard fold(text).contains(wanted) else { continue }
            guard item.isDone != done else {
                return Ticked(body: body, changed: false, item: text)
            }
            let updated = source.replacingCharacters(in: item.box, with: done ? "[x]" : "[ ]")
            return Ticked(body: updated, changed: true, item: text)
        }
        return nil
    }

    /// Case, accents and surrounding space all ignored: an agent quoting a task
    /// back from its own transcript should not miss on "Migración".
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
