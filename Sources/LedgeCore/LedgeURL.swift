import Foundation

/// `ledge://` — the seam other tools reach Ledge through.
///
/// Parsing lives here rather than in the app so it can be tested, and so a
/// malformed URL from anywhere on the machine is a `nil`, not a surprise.
public enum LedgeURL {

    public static let scheme = "ledge"

    public enum Command: Equatable, Sendable {
        /// A new note, optionally with everything about it decided up front.
        case new(title: String?, text: String?, color: NoteColor?, strip: String?)
        /// Open a note by title, or by id if it is one.
        case open(reference: String)
        /// Open the library with a query already typed.
        case search(String)
    }

    public static func parse(_ url: URL) -> Command? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // Both ledge://new?… and ledge:///new?… reach the same place; people
        // write both, and neither should be a dead link.
        let action = (url.host ?? url.pathComponents.first { $0 != "/" } ?? "").lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        switch action {
        case "new":
            return .new(title: value("title"),
                        text: value("text") ?? value("body"),
                        color: value("color").flatMap { NoteColor(rawValue: $0.lowercased()) },
                        strip: value("strip"))
        case "open":
            guard let reference = value("title") ?? value("id") ?? value("name") else { return nil }
            return .open(reference: reference)
        case "search", "find":
            guard let query = value("q") ?? value("query") ?? value("text") else { return nil }
            return .search(query)
        default:
            return nil
        }
    }

    /// The other direction: a link to a note, for pasting anywhere.
    public static func link(toTitle title: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "title", value: title)]
        return components.url
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
