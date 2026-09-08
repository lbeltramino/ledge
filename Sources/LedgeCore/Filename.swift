import Foundation

/// Turns a title into a filename. Identity lives in the frontmatter `id`, so a
/// filename may change freely without the store losing track of the note.
public enum Filename {
    static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
    public static let ext = "md"

    public static func base(for title: String) -> String {
        let cleaned = title
            .components(separatedBy: illegal).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let base = cleaned.isEmpty ? Note.untitled : cleaned
        return String(base.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// `base.md`, or `base 2.md`, `base 3.md` … when the name is already taken.
    public static func unique(for title: String, taken: Set<String>) -> String {
        let b = base(for: title)
        var candidate = "\(b).\(ext)"
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(b) \(n).\(ext)"
            n += 1
        }
        return candidate
    }
}
