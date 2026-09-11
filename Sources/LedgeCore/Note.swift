import Foundation

public enum NoteColor: String, CaseIterable, Sendable, Codable {
    case blue, green, lavender, butter, coral

    public static let `default`: NoteColor = .butter

    /// Cycles the palette so consecutive new notes look different.
    public static func next(after previous: NoteColor?) -> NoteColor {
        guard let previous, let i = allCases.firstIndex(of: previous) else { return .default }
        return allCases[(i + 1) % allCases.count]
    }
}

public enum NoteState: String, Sendable, Codable {
    case active, archived
}

public struct Note: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var color: NoteColor
    public var state: NoteState
    public var rank: String
    public var tags: [String]
    /// Which strip of the deck this note sits on. Empty means the primary one.
    public var strip: String
    /// What is writing to this note, when something other than you is: the name
    /// an agent gave when it took the note over. Empty means nobody.
    ///
    /// It lives in the file rather than beside it because it is a fact about the
    /// note — it should follow it to your other machine, and survive a rebuild
    /// of the index.
    public var feed: String
    public var created: Date
    public var updated: Date
    public var body: String

    /// Frontmatter keys written by something other than Ledge. Preserved
    /// verbatim on rewrite — another tool may own them.
    public var passthrough: [String]

    public init(
        id: String = ULID.generate(),
        title: String = "",
        color: NoteColor = .default,
        state: NoteState = .active,
        rank: String = Rank.initial,
        tags: [String] = [],
        strip: String = "",
        feed: String = "",
        created: Date = Date(),
        updated: Date = Date(),
        body: String = "",
        passthrough: [String] = []
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.state = state
        self.rank = rank
        self.tags = tags
        self.strip = strip
        self.feed = feed
        self.created = Frontmatter.normalized(created)
        self.updated = Frontmatter.normalized(updated)
        self.body = body
        self.passthrough = passthrough
    }

    public static let untitled = "Untitled note"

    /// The title shown in lists and on tabs.
    public var displayTitle: String {
        title.isEmpty ? Note.untitled : title
    }

    /// One-line preview for list rows, with markdown leaders flattened.
    public var snippet: String {
        body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Body text with markdown syntax stripped, for the search index.
    public var searchableBody: String {
        body.replacingOccurrences(of: "[*_`#>\\[\\]]", with: "", options: .regularExpression)
    }
}
