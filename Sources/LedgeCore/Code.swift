import Foundation

/// Recognising pasted source code.
///
/// Pasting a manifest into a Markdown note is not a neutral act. Every
/// `# comment` becomes an H1, every `- name:` becomes a bullet, and what you
/// pasted stops looking like what you copied. Fencing it fixes that — but only
/// if it happens by itself, because nobody pastes a snippet and then reaches
/// for a menu.
///
/// So the bar here is precision, not recall: fencing prose you pasted is a
/// worse mistake than leaving a snippet unfenced, and every detector below
/// wants a signal that prose does not produce by accident.
public enum Code {

    public struct Detection: Equatable, Sendable {
        /// The fence tag — `yaml`, `hcl`, `bash`. Nil when it is plainly code
        /// but of no language we recognise.
        public let language: String?
        /// A name for the snippet, for notes that arrive with no title.
        public let title: String?

        public init(language: String?, title: String?) {
            self.language = language
            self.title = title
        }
    }

    /// What this text is, or nil when it reads as prose.
    public static func detect(_ text: String) -> Detection? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        if let language = language(of: body) {
            return Detection(language: language, title: title(of: body, language: language))
        }
        guard looksLikeCode(body) else { return nil }
        return Detection(language: nil, title: title(of: body, language: nil))
    }

    // MARK: - which language

    /// The languages, in the order they are tried. Order is load-bearing:
    /// a Dockerfile is also shell-shaped, a Kubernetes manifest is also YAML,
    /// and JSON is also valid JavaScript.
    private static var detectors: [(String, (Lines) -> Bool)] {[
        ("dockerfile", isDockerfile),
        ("json", isJSON),
        ("xml", isXML),
        ("hcl", isHCL),
        ("groovy", isGroovy),
        ("typescript", isTypeScript),
        ("javascript", isJavaScript),
        ("yaml", isYAML),
        ("go", isGo),
        ("python", isPython),
        ("sql", isSQL),
        ("makefile", isMakefile),
        ("toml", isTOML),
        ("bash", isBash),
    ]}

    public static func language(of text: String) -> String? {
        let lines = Lines(text)
        return detectors.first { $0.1(lines) }?.0
    }

    /// The lines, prepared once. Every detector reads the same view of the text
    /// rather than re-splitting it ten times.
    struct Lines {
        let raw: String
        /// Non-blank lines, as written — indentation intact.
        let all: [String]
        /// The same lines trimmed, with comments and blanks dropped.
        let code: [String]

        init(_ text: String) {
            raw = text
            all = text.components(separatedBy: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            code = all.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") && !$0.hasPrefix("//") && !$0.hasPrefix("--") }
        }

        var first: String { code.first ?? "" }
        func count(_ pattern: String) -> Int {
            all.filter { $0.matches(pattern) }.count
        }
        func any(_ pattern: String) -> Bool { count(pattern) > 0 }
    }

    // MARK: - the detectors

    static func isDockerfile(_ lines: Lines) -> Bool {
        lines.first.matches("^FROM[ \t]+\\S")
            && lines.any("^(RUN|COPY|ADD|CMD|ENTRYPOINT|WORKDIR|ENV|EXPOSE|ARG|LABEL|USER|VOLUME|HEALTHCHECK)[ \t]")
    }

    static func isJSON(_ lines: Lines) -> Bool {
        let text = lines.raw
        guard text.hasPrefix("{") || text.hasPrefix("[") else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    static func isHCL(_ lines: Lines) -> Bool {
        // A block header — `resource "aws_s3_bucket" "logs" {` — is unmistakable.
        if lines.any("^[ \t]*(resource|data|module|provider|variable|output|locals|terraform|backend|provisioner)[ \t]*(\"[^\"]*\"[ \t]*)*\\{") {
            return true
        }
        // Otherwise: HCL assignments inside braces, which YAML never has.
        return lines.any("\\{[ \t]*$")
            && lines.count("^[ \t]*[\\w.\\[\\]\"-]+[ \t]*=[ \t]*\\S") >= 2
    }

    static func isYAML(_ lines: Lines) -> Bool {
        // A document marker settles it on its own.
        if lines.all.first?.trimmingCharacters(in: .whitespaces) == "---",
           lines.any("^[ \t]*[\\w.\\-/]+:([ \t]|$)") { return true }

        let keys = lines.count("^[ \t]*[\\w.\\-/]+:([ \t]|$)")
        let items = lines.count("^[ \t]*-[ \t]+\\S")
        guard keys >= 2 else { return false }
        // Braces and semicolons mean some other language that also has colons.
        guard !lines.any("\\{[ \t]*$"), !lines.any(";[ \t]*$") else { return false }
        // A colon is common enough in prose ("Note: this matters"), so a single
        // pair of key-shaped lines is not enough — either it nests, it lists,
        // or most of the text is keys.
        let nested = lines.count("^[ \t]+[\\w.\\-/]+:([ \t]|$)")
        return nested >= 1 || items >= 1 || keys >= max(3, lines.all.count / 2)
    }

    static func isXML(_ lines: Lines) -> Bool {
        guard lines.raw.hasPrefix("<") else { return false }
        return lines.any("^[ \t]*<\\?xml")
            || (lines.any("^[ \t]*<[\\w:.-]+[^>]*>") && lines.any("</[\\w:.-]+>"))
    }

    /// Jenkinsfiles and Gradle builds — brace-and-block DSLs that would
    /// otherwise be read as JavaScript.
    static func isGroovy(_ lines: Lines) -> Bool {
        lines.any("^[ \t]*(pipeline|node)[ \t]*(\\([^)]*\\))?[ \t]*\\{")
            && lines.any("^[ \t]*(stages?|steps|agent|pipeline|post|environment)\\b")
            || lines.any("^[ \t]*(plugins|dependencies|subprojects|allprojects)[ \t]*\\{")
    }

    /// TypeScript is JavaScript plus types, so it is asked about first and only
    /// claims the text when something in it could not be JavaScript.
    static func isTypeScript(_ lines: Lines) -> Bool {
        guard hasJavaScriptShape(lines) || lines.any("^[ \t]*(export[ \t]+)?(interface|type|enum|namespace|declare)[ \t]+\\w")
        else { return false }
        return lines.any("^[ \t]*(export[ \t]+)?(interface|namespace|declare)[ \t]+\\w")
            || lines.any("^[ \t]*(export[ \t]+)?(type|enum)[ \t]+\\w+[ \t]*[={]")
            || lines.any("^import[ \t]+type[ \t]")
            || lines.any("[)\\w][ \t]*:[ \t]*(string|number|boolean|void|any|unknown|never|Promise<|Record<|Array<|readonly[ \t])")
            || lines.any("^[ \t]*(public|private|protected|readonly)[ \t]+\\w+[ \t]*[:(]")
            || lines.any("[ \t]as[ \t]+(const|string|number|unknown)\\b")
    }

    static func isJavaScript(_ lines: Lines) -> Bool { hasJavaScriptShape(lines) }

    /// The shape both of them share.
    private static func hasJavaScriptShape(_ lines: Lines) -> Bool {
        if lines.any("^[ \t]*(export[ \t]+)?(async[ \t]+)?function[ \t]*\\*?[ \t]*\\w") { return true }
        if lines.any("\\brequire\\([\"\']") { return true }
        if lines.any("^[ \t]*module\\.exports\\b") { return true }
        if lines.any("^[ \t]*export[ \t]+(default|const|class|async|function)\\b") { return true }
        if lines.any("^import[ \t]+[\\w{*][^\\n]*[ \t]from[ \t]+[\"\']") { return true }

        // Otherwise it takes a declaration *and* something only JavaScript
        // does. `let x = f();` on its own is also Rust, Swift and C — a
        // semicolon is evidence of nothing.
        guard lines.any("^[ \t]*(const|let|var)[ \t]+[\\w{\\[]") else { return false }
        return lines.any("=>")
            || lines.any("\\b(console|process|window|document|JSON)\\.")
            || lines.any("\\b(await|new|typeof|null|undefined)\\b")
            || lines.any("\\$\\{")
            || lines.any("\\.then\\(")
    }

    static func isGo(_ lines: Lines) -> Bool {
        lines.any("^package[ \t]+\\w+[ \t]*$")
            && lines.any("^(func|import|type|var|const)[ \t(]")
    }

    static func isPython(_ lines: Lines) -> Bool {
        let defs = lines.count("^[ \t]*(def|class)[ \t]+\\w+.*:[ \t]*$")
        let imports = lines.count("^(import[ \t]+\\w|from[ \t]+[\\w.]+[ \t]+import[ \t])")
        return defs >= 1 || imports >= 2 || (imports == 1 && lines.all.count > 2)
    }

    static func isSQL(_ lines: Lines) -> Bool {
        let head = lines.first.uppercased()
        guard head.matches("^(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|WITH)\\b") else { return false }
        return lines.raw.uppercased().matches("\\b(FROM|INTO|TABLE|VALUES|WHERE|SET)\\b")
    }

    static func isMakefile(_ lines: Lines) -> Bool {
        lines.any("^[\\w.%$()/-]+:([ \t]*$|[ \t]+[\\w.%$()/ -]*$)")
            && lines.any("^\t[^\t]")
    }

    static func isTOML(_ lines: Lines) -> Bool {
        lines.any("^\\[[\\w.\"-]+\\][ \t]*$")
            && lines.count("^[ \t]*[\\w.\"-]+[ \t]*=[ \t]*\\S") >= 1
    }

    static func isBash(_ lines: Lines) -> Bool {
        if lines.all.first?.matches("^#![ \t]*/.*(sh|bash|zsh)") == true { return true }
        // Otherwise it has to look like commands, not like a sentence that
        // happens to mention a program.
        let commands = lines.count("^[ \t]*(sudo[ \t]+)?(kubectl|docker|terraform|helm|aws|gcloud|az|git|curl|npm|yarn|make|systemctl|apt|apt-get|brew|ssh|scp|chmod|chown|mkdir|cd|export|echo|cat|grep|sed|awk|jq|ansible|ansible-playbook|pulumi|kustomize|argocd|flux|vault|nomad|consul|packer|openssl|psql|mysql|redis-cli)\\b")
        guard commands >= 1 else { return false }
        let flags = lines.count("[ \t]--?[\\w-]+")
        let pipes = lines.count("[|]|&&|\\$\\{|\\$\\(|>[ \t]*\\S")
        return commands >= 2 || flags >= 1 || pipes >= 1
    }

    // MARK: - code of no particular language

    /// For everything the detectors miss — a Groovy pipeline, a C header, a
    /// snippet of Rust. Two independent signals, so an indented quotation or a
    /// list of file names does not qualify.
    public static func looksLikeCode(_ text: String) -> Bool {
        let lines = Lines(text)
        guard lines.all.count >= 2 else { return false }

        // Prose veto first: text made of sentences is not code, whatever else
        // it contains.
        let sentences = lines.all.filter { $0.matches("[.!?][\"')]?[ \t]*$") }.count
        if sentences * 2 > lines.all.count { return false }

        var signals = 0
        if lines.any("[{}][ \t]*$") { signals += 1 }
        if lines.any(";[ \t]*$") { signals += 1 }
        if lines.any("^[ \t]*(//|/\\*|\\*|#)[ \t]*\\w") { signals += 1 }
        if lines.any("\\$\\{|\\$\\(|=>|->|::|&&|\\|\\|") { signals += 1 }
        if lines.count("^([ ]{2,}|\t)\\S") >= 2 { signals += 1 }
        if lines.count("^[ \t]*[\\w.\\[\\]\"-]+[ \t]*[:=][ \t]*\\S") >= 2 { signals += 1 }
        return signals >= 2
    }

    // MARK: - a name for it

    /// A title for a snippet, the way you would refer to it out loud.
    public static func title(of text: String, language: String?) -> String? {
        let lines = Lines(text)
        let name: String?

        switch language {
        case "yaml":
            // Kubernetes first: `kind` and `metadata.name` are how you say what
            // a manifest is.
            if let kind = lines.capture("^kind:[ \t]*[\"']?([\\w.-]+)") {
                if let object = lines.capture("^[ \t]+name:[ \t]*[\"']?([\\w.-]+)") {
                    name = "\(kind)/\(object)"
                } else {
                    name = kind
                }
            } else if let top = lines.capture("^([\\w.-]+):") {
                name = top
            } else {
                name = nil
            }
        case "hcl":
            if let m = lines.captures("^[ \t]*(resource|data)[ \t]+\"([^\"]+)\"[ \t]+\"([^\"]+)\"") {
                name = "\(m[1]).\(m[2])"
            } else if let m = lines.captures("^[ \t]*(module|variable|output|provider|backend)[ \t]+\"([^\"]+)\"") {
                name = "\(m[0]).\(m[1])"
            } else {
                name = "terraform"
            }
        case "dockerfile":
            name = lines.capture("^FROM[ \t]+(\\S+)").map { "Dockerfile · \($0)" } ?? "Dockerfile"
        case "typescript", "javascript":
            // Whichever declaration comes first in the file, not whichever
            // pattern is first in this list — the top of a module is what it
            // is about.
            name = lines.captureAny([
                "^[ \t]*(?:export[ \t]+)?(?:default[ \t]+)?(?:async[ \t]+)?function[ \t]*\\*?[ \t]*(\\w+)",
                "^[ \t]*(?:export[ \t]+)?(?:interface|type|enum|class)[ \t]+(\\w+)",
                "^[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+(\\w+)",
                "^import[ \t]+.*[ \t]from[ \t]+[\"']([^\"']+)",
            ])
        case "groovy":
            name = lines.capture("^[ \t]*stage[ \t]*\\([\"\']([^\"\']+)").map { "stage \($0)" }
                ?? (lines.any("^[ \t]*pipeline[ \t]*\\{") ? "Jenkinsfile" : "groovy")
        case "xml":
            name = lines.capture("^[ \t]*<([\\w:.-]+)[ >]").map { "<\($0)>" }
        case "go":
            if let fn = lines.capture("^func[ \t]+(?:\\([^)]*\\)[ \t]*)?(\\w+)") {
                name = lines.capture("^package[ \t]+(\\w+)").map { "\($0).\(fn)" } ?? fn
            } else {
                name = lines.capture("^package[ \t]+(\\w+)")
            }
        case "python":
            name = lines.capture("^[ \t]*(?:def|class)[ \t]+(\\w+)")
                ?? lines.capture("^(?:import|from)[ \t]+([\\w.]+)")
        case "sql":
            if let m = lines.captures("(?i)^(create|alter|drop)[ \t]+(?:or[ \t]+replace[ \t]+)?(table|view|index|function)[ \t]+(?:if[ \t]+not[ \t]+exists[ \t]+)?([\\w.\"]+)") {
                name = "\(m[0].lowercased()) \(m[2])"
            } else if let table = lines.capture("(?i)\\b(?:from|into|update)[ \t]+([\\w.\"]+)") {
                name = "query · \(table)"
            } else {
                name = "sql"
            }
        case "makefile":
            name = lines.capture("^([\\w.%/-]+):").map { "make \($0)" }
        case "toml":
            name = lines.capture("^\\[([\\w.\"-]+)\\]")
        case "json":
            name = lines.capture("^[ \t]*\"(?:name|id|kind)\"[ \t]*:[ \t]*\"([^\"]+)\"") ?? "json"
        case "bash":
            // The command you would say you were running — which is never
            // `set -euo pipefail`, however faithfully that is the first line.
            let boilerplate = "^(set|shopt|cd|export|source|umask|trap)\\b"
            let commands = lines.code.filter { !$0.hasPrefix("#!") && !$0.matches(boilerplate) }
            if let line = commands.first ?? lines.code.first(where: { !$0.hasPrefix("#!") }) {
                let words = line.split(separator: " ").filter { !$0.hasPrefix("-") }.prefix(3)
                name = words.isEmpty ? nil : words.joined(separator: " ")
            } else {
                name = nil
            }
        default:
            name = lines.code.first
        }

        guard let name, !name.isEmpty else { return nil }
        return shorten(name)
    }

    private static func shorten(_ text: String, to limit: Int = 44) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    // MARK: - fencing

    /// Wraps the text in a fence long enough to survive whatever is inside it.
    /// A snippet that itself contains ``` — a README, a chat log — would
    /// otherwise close the block early and spill.
    public static func fenced(_ text: String, language: String?) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var longest = 2
        for line in body.components(separatedBy: "\n") {
            let ticks = line.prefix { $0 == "`" }.count
            longest = max(longest, ticks)
        }
        let fence = String(repeating: "`", count: longest + 1)
        return fence + (language ?? "") + "\n" + body + "\n" + fence
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}

extension Code.Lines {
    /// The first capture group of the first line that matches.
    func capture(_ pattern: String) -> String? {
        captures(pattern)?.first
    }

    /// The first capture of whichever of these patterns matches earliest in
    /// the text — line order first, pattern order only to break a tie.
    func captureAny(_ patterns: [String]) -> String? {
        for line in all {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let text = line as NSString
                guard let match = regex.firstMatch(in: line,
                                                   range: NSRange(location: 0, length: text.length)),
                      match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound else { continue }
                return text.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    /// Every capture group of the first line that matches.
    func captures(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in all {
            let text = line as NSString
            guard let match = regex.firstMatch(in: line,
                                               range: NSRange(location: 0, length: text.length))
            else { continue }
            guard match.numberOfRanges > 1 else { continue }
            return (1..<match.numberOfRanges).compactMap { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
        }
        return nil
    }
}
