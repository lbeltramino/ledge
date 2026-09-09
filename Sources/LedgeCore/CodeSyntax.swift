import Foundation

/// What the pieces of a snippet are, so a fenced block can be read rather than
/// merely recognised.
///
/// This says nothing about colour. It returns roles and leaves the palette to
/// the highlighter, which is the only part that knows what the paper looks
/// like — and it means the grammars can be tested without a screen.
public extension Code {

    enum Role: String, Sendable, Equatable, CaseIterable {
        /// `# like this`, whatever the language spells it.
        case comment
        /// Anything quoted.
        case string
        case number
        /// The words the language reserves.
        case keyword
        /// The left-hand side: a YAML key, a JSON field, an HCL argument, a
        /// Make target, a shell variable. What gives a block its shape.
        case key
    }

    struct Token: Sendable, Equatable {
        public let range: NSRange
        public let role: Role
        public init(range: NSRange, role: Role) {
            self.range = range
            self.role = role
        }
    }

    /// The tokens in a snippet, in the order they appear, never overlapping.
    ///
    /// Comments and strings are claimed first and everything else has to fit
    /// around them, because a keyword inside a string is not a keyword and a
    /// quote inside a comment is not a string.
    static func tokens(in text: String, language: String?) -> [Token] {
        guard let grammar = grammar(for: language) else { return [] }
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)

        var claimed: [NSRange] = []
        var tokens: [Token] = []

        func add(_ patterns: [String], _ role: Role, group: Int = 0) {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(
                    pattern: pattern, options: [.anchorsMatchLines, .dotMatchesLineSeparators])
                else { continue }
                for match in regex.matches(in: text, range: whole) {
                    let range = match.numberOfRanges > group ? match.range(at: group) : match.range
                    guard range.location != NSNotFound, range.length > 0 else { continue }
                    guard !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 })
                    else { continue }
                    claimed.append(range)
                    tokens.append(Token(range: range, role: role))
                }
            }
        }

        add(grammar.comments, .comment)
        add(grammar.strings, .string)
        add(grammar.keys, .key, group: 1)
        if !grammar.keywords.isEmpty {
            let words = grammar.keywords.joined(separator: "|")
            let boundary = grammar.caseInsensitive ? "(?i)" : ""
            add(["\(boundary)(?<![\\w$])(\(words))(?![\\w$])"], .keyword, group: 1)
        }
        add(["(?<![\\w.$])(\\d+(?:\\.\\d+)?)(?![\\w.])"], .number, group: 1)

        return tokens.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - the grammars

    struct Grammar: Sendable {
        var comments: [String] = []
        var strings: [String] = []
        /// Each of these must capture the part to colour in group 1.
        var keys: [String] = []
        var keywords: [String] = []
        var caseInsensitive = false
    }

    /// Deliberately shallow. These are snippets pasted into a sticky note, not
    /// files in an IDE: five roles read at a glance are worth more than a real
    /// parser, and a regex that is wrong about an edge case only ever costs a
    /// word the wrong shade.
    static func grammar(for language: String?) -> Grammar? {
        let hash = "#[^\n]*"
        let slashes = "//[^\n]*"
        let block = "/\\*.*?\\*/"
        let doubleQuoted = "\"(?:[^\"\\\\\n]|\\\\.)*\""
        let singleQuoted = "'(?:[^'\\\\\n]|\\\\.)*'"
        let backticked = "`(?:[^`\\\\]|\\\\.)*`"

        switch language {
        case "yaml":
            return Grammar(
                comments: [hash],
                strings: [doubleQuoted, singleQuoted],
                keys: ["^[ \t]*(?:-[ \t]+)?([\\w.\\-/]+)(?=:(?:[ \t]|$))"],
                keywords: ["true", "false", "null", "yes", "no", "on", "off"])
        case "json":
            return Grammar(
                strings: [doubleQuoted],
                keys: ["(\"(?:[^\"\\\\\n]|\\\\.)*\")(?=[ \t]*:)"],
                keywords: ["true", "false", "null"])
        case "hcl":
            return Grammar(
                comments: [hash, slashes, block],
                strings: [doubleQuoted],
                keys: ["^[ \t]*([\\w.\\[\\]-]+)(?=[ \t]*=[^=])"],
                keywords: ["resource", "data", "module", "provider", "variable", "output",
                           "locals", "terraform", "backend", "provisioner", "dynamic",
                           "for_each", "count", "depends_on", "lifecycle", "var", "local",
                           "each", "true", "false", "null"])
        case "bash":
            return Grammar(
                comments: [hash],
                strings: [doubleQuoted, singleQuoted],
                keys: ["(\\$\\{?[\\w]+\\}?)", "^[ \t]*(?:export[ \t]+)?([A-Za-z_][\\w]*)(?==)"],
                keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do",
                           "done", "case", "esac", "function", "return", "export", "local",
                           "set", "in", "source", "trap", "exit", "echo"])
        case "python":
            return Grammar(
                comments: [hash],
                strings: ["\"\"\".*?\"\"\"", "'''.*?'''", doubleQuoted, singleQuoted],
                keywords: ["def", "class", "import", "from", "as", "return", "if", "elif",
                           "else", "for", "while", "try", "except", "finally", "with", "in",
                           "not", "and", "or", "is", "None", "True", "False", "lambda",
                           "yield", "async", "await", "raise", "pass", "break", "continue",
                           "global", "nonlocal", "assert", "del", "self"])
        case "go":
            return Grammar(
                comments: [slashes, block],
                strings: [doubleQuoted, backticked],
                keywords: ["package", "import", "func", "type", "struct", "interface", "map",
                           "chan", "var", "const", "return", "if", "else", "for", "range",
                           "switch", "case", "default", "select", "go", "defer", "break",
                           "continue", "fallthrough", "nil", "true", "false", "error",
                           "string", "int", "int64", "float64", "bool", "byte", "rune"])
        case "javascript", "typescript":
            return Grammar(
                comments: [slashes, block],
                strings: [doubleQuoted, singleQuoted, backticked],
                keywords: ["const", "let", "var", "function", "return", "if", "else", "for",
                           "while", "do", "switch", "case", "default", "break", "continue",
                           "class", "extends", "super", "new", "this", "import", "from",
                           "export", "async", "await", "try", "catch", "finally", "throw",
                           "typeof", "instanceof", "delete", "in", "of", "null", "undefined",
                           "true", "false", "interface", "type", "enum", "namespace",
                           "declare", "implements", "public", "private", "protected",
                           "readonly", "abstract", "as", "satisfies"])
        case "groovy":
            return Grammar(
                comments: [slashes, block],
                strings: [doubleQuoted, singleQuoted, backticked],
                keywords: ["pipeline", "agent", "stages", "stage", "steps", "post", "script",
                           "environment", "options", "parameters", "when", "sh", "node", "def",
                           "if", "else", "for", "while", "return", "try", "catch", "finally",
                           "class", "new", "null", "true", "false", "plugins", "dependencies"])
        case "dockerfile":
            return Grammar(
                comments: [hash],
                strings: [doubleQuoted, singleQuoted],
                keywords: ["FROM", "RUN", "COPY", "ADD", "CMD", "ENTRYPOINT", "WORKDIR", "ENV",
                           "EXPOSE", "ARG", "LABEL", "USER", "VOLUME", "HEALTHCHECK", "SHELL",
                           "ONBUILD", "STOPSIGNAL", "AS"])
        case "sql":
            return Grammar(
                comments: ["--[^\n]*", block],
                strings: [singleQuoted, doubleQuoted],
                keywords: ["select", "from", "where", "insert", "into", "values", "update",
                           "set", "delete", "create", "table", "alter", "drop", "index",
                           "view", "join", "left", "right", "inner", "outer", "full", "on",
                           "group", "order", "by", "having", "limit", "offset", "and", "or",
                           "not", "null", "primary", "key", "foreign", "references",
                           "default", "with", "as", "distinct", "union", "exists", "case",
                           "when", "then", "else", "end", "if", "cascade", "constraint",
                           "unique", "check", "returning"],
                caseInsensitive: true)
        case "toml":
            return Grammar(
                comments: [hash],
                strings: [doubleQuoted, singleQuoted],
                keys: ["^[ \t]*(\\[[^\\]\n]+\\])", "^[ \t]*([\\w.\"-]+)(?=[ \t]*=)"],
                keywords: ["true", "false"])
        case "makefile":
            return Grammar(
                comments: [hash],
                strings: [doubleQuoted, singleQuoted],
                keys: ["^([\\w.%/-]+)(?=:(?:[ \t]|$))", "(\\$[({][\\w]+[)}])"],
                keywords: ["ifeq", "ifneq", "ifdef", "ifndef", "endif", "else", "include",
                           "define", "endef", "export", "PHONY"])
        case "xml":
            return Grammar(
                comments: ["<!--.*?-->"],
                strings: [doubleQuoted, singleQuoted],
                keys: ["</?([\\w:.-]+)"])
        default:
            return nil
        }
    }
}
