import Foundation

/// A ```` ```log ```` block: a line of prose with the time it happened in front
/// of it.
///
/// The time is *text in the file*, the way a tag is `#work` and a task is
/// `- [ ]`. Nothing here invents a format a different editor could not read —
/// what the app adds is that Enter writes the time for you and the drawing
/// lines the prose up.
///
/// Only the reading lives here: no fonts, no measuring, no idea a screen
/// exists. Same bargain as `Media` and `Tables`.
public enum Log {

    /// One line of a log: where its time is, where its words are, and whether
    /// the time repeats the line above.
    public struct Entry: Equatable, Sendable {
        /// The whole line, without its newline.
        public let line: NSRange
        /// The `HH:MM` at the front, when there is one.
        public let time: NSRange?
        /// What the time says, for the day boundary and for a check.
        public let minutes: Int?
        /// The same minute as the line above, so the drawing can leave it out
        /// while the file keeps it.
        public let repeatsPrevious: Bool

        public init(line: NSRange, time: NSRange?, minutes: Int?, repeatsPrevious: Bool) {
            self.line = line
            self.time = time
            self.minutes = minutes
            self.repeatsPrevious = repeatsPrevious
        }
    }

    /// `9:07` and `23:54` both count; `9:7` and `24:00` do not.
    private static let timePattern = #"^(\d{1,2}:[0-5]\d)(?=$|[ \t])"#
    private static let timeRegex = try? NSRegularExpression(pattern: timePattern)

    /// The entries in a stretch of text, one per line.
    ///
    /// `text` is the body of the block, and every range is relative to it — the
    /// caller knows where the block starts.
    public static func entries(in text: String) -> [Entry] {
        let source = text as NSString
        var entries: [Entry] = []
        var previous: Int?
        var start = 0

        // `<` and not `<=`: at exactly the length there is no line left, only
        // the position after the last newline, and counting it gave every block
        // one entry more than it had lines.
        while start < source.length {
            let line = source.lineRange(for: NSRange(location: min(start, source.length), length: 0))
            var content = line
            // The newline belongs to the line for `lineRange`, and to nothing
            // at all for anything drawn.
            while content.length > 0 {
                let last = source.substring(with: NSRange(location: NSMaxRange(content) - 1, length: 1))
                guard last == "\n" || last == "\r" else { break }
                content.length -= 1
            }

            // The pattern says what a time looks like; `minutes` says whether
            // it is one. `24:00` passes the first and fails the second, and
            // without both it was drawn as a time that does not exist.
            let found = timeRegex?.firstMatch(in: text, range: content)
            var time: NSRange?
            var minutes: Int?
            if let found, found.numberOfRanges > 1,
               let value = self.minutes(of: source.substring(with: found.range(at: 1))) {
                time = found.range(at: 1)
                minutes = value
            }
            entries.append(Entry(line: content, time: time, minutes: minutes,
                                 repeatsPrevious: minutes != nil && minutes == previous))
            if let minutes { previous = minutes }

            if NSMaxRange(line) <= start { break }
            start = NSMaxRange(line)
        }
        return entries
    }

    /// Minutes since midnight, or nil for something that is not a time.
    public static func minutes(of text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// `HH:MM`, zero-padded, which is what makes the column line up.
    public static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The widest a time can be, for the column the prose is indented to.
    /// Always the same string so a check can measure the same thing the drawing
    /// does.
    public static let widestTime = "00:00 "

    /// Whether this fence tag opens a log.
    public static func isLogTag(_ tag: String) -> Bool {
        tag.trimmingCharacters(in: .whitespaces).lowercased() == "log"
    }
}
