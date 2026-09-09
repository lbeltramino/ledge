import Foundation

/// Reads and writes the YAML frontmatter block at the head of a note file.
///
/// Deliberately not a general YAML implementation: the schema is eight known
/// scalar keys, and anything else is carried through untouched rather than
/// re-serialised through a model that does not understand it.
public enum Frontmatter {
    static let fence = "---"
    static let knownKeys: Set<String> = ["id", "title", "color", "state", "rank", "tags",
                                        "strip", "feed", "created", "updated"]

    // Value-typed and Sendable, unlike ISO8601DateFormatter.
    private static let iso = Date.ISO8601FormatStyle()
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// A note's body never carries trailing newlines: the file always ends with
    /// exactly one, so without this a note is not equal to itself after a
    /// round-trip and every save rewrites a file that did not change.
    static func trimmed(_ body: String) -> String {
        var b = body
        while b.hasSuffix("\n") || b.hasSuffix("\r") { b.removeLast() }
        return b
    }

    public static func date(from s: String) -> Date? {
        (try? iso.parse(s)) ?? (try? isoFractional.parse(s))
    }

    public static func string(from d: Date) -> String {
        iso.format(d)
    }

    /// Note files carry whole seconds. Normalising on the way in keeps an
    /// in-memory note equal to the one that comes back off disk.
    public static func normalized(_ d: Date) -> Date {
        Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
    }

    // MARK: - parse

    /// Parses a note file. A file with no frontmatter is still a valid note:
    /// it is adopted, using `fallbackTitle` and fresh metadata, and gains
    /// frontmatter the first time it is saved.
    public struct Parsed: Sendable {
        public var note: Note
        /// Frontmatter keys the file actually carried. The difference between
        /// "this note has no rank" and "this note's rank is a0" matters.
        public var declared: Set<String>

        public func declares(_ key: String) -> Bool { declared.contains(key) }
    }

    public static func parse(_ text: String, fallbackTitle: String,
                             fallbackID: String? = nil, fallbackDate: Date = Date()) -> Note {
        parseDetailed(text, fallbackTitle: fallbackTitle, fallbackID: fallbackID, fallbackDate: fallbackDate).note
    }

    public static func parseDetailed(_ text: String, fallbackTitle: String,
                                     fallbackID: String? = nil, fallbackDate: Date = Date()) -> Parsed {
        let base = normalized(fallbackDate)
        var declared = Set<String>()
        var note = Note(
            id: fallbackID ?? ULID.generate(date: base),
            title: fallbackTitle,
            created: base,
            updated: base
        )

        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == fence else {
            note.body = trimmed(text)
            return Parsed(note: note, declared: declared)
        }

        var end: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == fence {
            end = i
            break
        }
        guard let close = end else {
            note.body = trimmed(text)
            return Parsed(note: note, declared: declared)
        }

        var passthrough: [String] = []
        for raw in lines[1..<close] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = raw.firstIndex(of: ":") else {
                passthrough.append(raw)
                continue
            }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces))

            guard knownKeys.contains(key) else {
                passthrough.append(raw)
                continue
            }
            declared.insert(key)

            switch key {
            case "id":      if ULID.isValid(value) { note.id = value } else { declared.remove("id") }
            case "title":   note.title = value
            case "color":   note.color = NoteColor(rawValue: value.lowercased()) ?? .default
            case "state":   note.state = NoteState(rawValue: value.lowercased()) ?? .active
            case "rank":    if value.isEmpty { declared.remove("rank") } else { note.rank = value }
            case "tags":    note.tags = parseList(value)
            case "strip":   note.strip = value
            case "feed":    note.feed = value
            case "created": if let d = date(from: value) { note.created = d } else { declared.remove("created") }
            case "updated": if let d = date(from: value) { note.updated = d } else { declared.remove("updated") }
            default: break
            }
        }

        note.passthrough = passthrough
        note.body = lines[(close + 1)...].joined(separator: "\n")
        if note.body.hasPrefix("\n") { note.body.removeFirst() }
        note.body = trimmed(note.body)
        return Parsed(note: note, declared: declared)
    }

    static func parseList(_ value: String) -> [String] {
        var v = value
        if v.hasPrefix("["), v.hasSuffix("]") { v = String(v.dropFirst().dropLast()) }
        return v.split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let quote = s.first!
        guard (quote == "\"" || quote == "'"), s.last == quote else { return s }
        let inner = String(s.dropFirst().dropLast())
        return quote == "\""
            ? inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            : inner
    }

    // MARK: - serialise

    public static func serialize(_ note: Note) -> String {
        var out = fence + "\n"
        out += "id: \(note.id)\n"
        out += "title: \(quoteIfNeeded(note.title))\n"
        out += "color: \(note.color.rawValue)\n"
        out += "state: \(note.state.rawValue)\n"
        out += "rank: \(note.rank)\n"
        out += "tags: [\(note.tags.map(quoteIfNeeded).joined(separator: ", "))]\n"
        if !note.strip.isEmpty { out += "strip: \(quoteIfNeeded(note.strip))\n" }
        if !note.feed.isEmpty { out += "feed: \(quoteIfNeeded(note.feed))\n" }
        out += "created: \(string(from: note.created))\n"
        out += "updated: \(string(from: note.updated))\n"
        for line in note.passthrough { out += line + "\n" }
        out += fence + "\n"
        if !note.body.isEmpty {
            out += note.body
            if !note.body.hasSuffix("\n") { out += "\n" }
        }
        return out
    }

    static func quoteIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let needsQuoting =
            s != s.trimmingCharacters(in: .whitespaces) ||
            s.contains(where: { ":#[]{},&*?|<>=!%@`\"'".contains($0) }) ||
            s.first == "-"
        guard needsQuoting else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
