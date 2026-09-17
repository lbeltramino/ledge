import Foundation

/// A JSONForms form, read out of a block of JSON in a note.
///
/// Only the reading lives here — no measuring and no drawing, the same bargain
/// `Media` and `Tables` make. What a note asks for is something a check can
/// reason about without a screen.
///
/// Three shapes of JSON arrive at this, and all three are things you would
/// actually paste:
///
///   1. a whole payload out of the IDP, where the form is buried at
///      `attributes.schema`,
///   2. an object with `uiSchema` and `properties` side by side,
///   3. a bare uiSchema, typed by hand, with no properties at all — which is
///      what prototyping looks like before the fields exist.
///
/// So the rule is "find the `uiSchema` key", not "the payload must be shaped
/// this way". Properties are an improvement on the drawing, never a condition
/// for it.
public enum UISchema {

    // MARK: - what a form is made of

    /// A field the form can show, as much of it as the schema says.
    public struct Field: Equatable, Sendable {
        public var title: String
        /// `string`, `integer`, `boolean`… — what decides the shape drawn.
        public var type: String?
        /// An `enum`, which is drawn as something you pick from.
        public var choices: [String]
        public var isRequired: Bool
        public var isReadOnly: Bool
        /// `visibleOn: []` — a field the form deliberately never shows. Drawn
        /// faintly rather than left out: when you are prototyping, the field
        /// you decided to hide is one of the decisions you are looking at.
        public var isHidden: Bool
        public var detail: String?

        public init(title: String, type: String? = nil, choices: [String] = [],
                    isRequired: Bool = false, isReadOnly: Bool = false,
                    isHidden: Bool = false, detail: String? = nil) {
            self.title = title
            self.type = type
            self.choices = choices
            self.isRequired = isRequired
            self.isReadOnly = isReadOnly
            self.isHidden = isHidden
            self.detail = detail
        }
    }

    public struct Control: Equatable, Sendable {
        public let scope: String
        /// Nil when the scope points at nothing — the mistake everyone makes
        /// writing a uiSchema by hand, and the one the drawing exists to show.
        public let field: Field?
        /// What the label falls back to: the last segment of the scope, made
        /// readable. A uiSchema with no properties beside it still draws.
        public let name: String
    }

    public struct Category: Equatable, Sendable {
        public let label: String
        public let elements: [Element]
    }

    public indirect enum Element: Equatable, Sendable {
        case vertical([Element])
        case horizontal([Element])
        case group(label: String?, elements: [Element])
        case control(Control)
        /// A `Label` element: a sentence in the middle of the form.
        case note(String)
        case categorization([Category])
        /// A type this does not know. Drawn as itself rather than dropped, so a
        /// renderer somebody else wrote does not silently vanish.
        case unknown(String)
    }

    public struct Form: Equatable, Sendable {
        public let root: Element
        /// The payload's own `name`, when it came from one.
        public let title: String?
        /// Properties defined and never placed by a control, and anything else
        /// worth saying out loud. Drawn under the form.
        public let warnings: [String]
    }

    // MARK: - finding it

    /// The form in a block of JSON, or nil when there is none.
    public static func find(in json: String) -> Form? {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let site = locate(any, depth: 0) else { return nil }

        var used: Set<String> = []
        let root = element(site.ui, in: site, used: &used)

        var warnings: [String] = []
        // `additionalProperties` belongs beside `properties`, not inside it.
        // Inside, JSON Schema reads it as a field called "additionalProperties"
        // and the rule it was meant to be is simply not there — a real payload
        // had exactly this, and nothing anywhere said so.
        if site.properties["additionalProperties"] != nil {
            warnings.append("additionalProperties is inside properties: it reads as a field, not as a rule")
        }
        let unplaced = site.properties.keys
            .filter { $0 != "additionalProperties" && !used.contains($0) }
            .sorted()
        if !unplaced.isEmpty {
            warnings.append("defined and never placed: " + unplaced.joined(separator: ", "))
        }

        return Form(root: root, title: site.name, warnings: warnings)
    }

    /// Where the form was found: the uiSchema, and whatever was beside it.
    private struct Site {
        let ui: [String: Any]
        let properties: [String: Any]
        let required: Set<String>
        let name: String?
    }

    /// Depth-first for the `uiSchema` key, and failing that, for something that
    /// already is one.
    ///
    /// Bounded because this runs on every keystroke in a note that has one, and
    /// what arrives is whatever an API returned — a form is never eight levels
    /// down, and a payload that deep would cost more to search than it is worth.
    private static func locate(_ any: Any, depth: Int) -> Site? {
        guard depth < 8 else { return nil }

        if let object = any as? [String: Any] {
            if let ui = object["uiSchema"] as? [String: Any] {
                return Site(ui: ui,
                            properties: object["properties"] as? [String: Any] ?? [:],
                            required: Set(object["required"] as? [String] ?? []),
                            name: nil)
            }
            // A bare uiSchema, typed straight into the note.
            if isLayout(object) {
                return Site(ui: object, properties: [:], required: [], name: nil)
            }
            // The payload's name is worth carrying down: it is at the top of an
            // IDP response and the form is several levels under it.
            let name = object["name"] as? String
            for key in object.keys.sorted() {
                if let found = locate(object[key]!, depth: depth + 1) {
                    return Site(ui: found.ui, properties: found.properties,
                                required: found.required, name: found.name ?? name)
                }
            }
            return nil
        }

        if let array = any as? [Any] {
            for item in array {
                if let found = locate(item, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private static func isLayout(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String else { return false }
        return layouts.contains(type) && object["elements"] != nil
    }

    private static let layouts: Set<String> = [
        "VerticalLayout", "HorizontalLayout", "Group", "Categorization",
    ]

    // MARK: - reading it

    private static func element(_ object: [String: Any], in site: Site,
                                used: inout Set<String>) -> Element {
        let type = object["type"] as? String ?? ""
        let children = (object["elements"] as? [[String: Any]] ?? [])

        switch type {
        case "VerticalLayout":
            return .vertical(children.map { element($0, in: site, used: &used) })
        case "HorizontalLayout":
            return .horizontal(children.map { element($0, in: site, used: &used) })
        case "Group":
            return .group(label: object["label"] as? String,
                          elements: children.map { element($0, in: site, used: &used) })
        case "Categorization":
            return .categorization(children.map { child in
                Category(label: child["label"] as? String ?? "",
                         elements: (child["elements"] as? [[String: Any]] ?? [])
                            .map { element($0, in: site, used: &used) })
            })
        case "Label":
            return .note(plain(object["text"] as? String ?? ""))
        case "Control":
            let scope = object["scope"] as? String ?? ""
            let key = name(of: scope)
            if resolve(scope, in: site.properties) != nil { used.insert(key) }
            return .control(Control(scope: scope,
                                    field: field(at: scope, in: site),
                                    name: readable(key)))
        default:
            return .unknown(type.isEmpty ? "element with no type" : type)
        }
    }

    /// `#/properties/db_name` — and the nested form, `#/properties/a/properties/b`.
    private static func resolve(_ scope: String, in properties: [String: Any]) -> [String: Any]? {
        var parts = scope.split(separator: "/").map(String.init)
        guard parts.first == "#" else { return nil }
        parts.removeFirst()
        guard parts.first == "properties" else { return nil }
        parts.removeFirst()

        var here = properties
        while let key = parts.first {
            parts.removeFirst()
            guard let next = here[key] as? [String: Any] else { return nil }
            if parts.isEmpty { return next }
            guard parts.first == "properties" else { return nil }
            parts.removeFirst()
            guard let deeper = next["properties"] as? [String: Any] else { return nil }
            here = deeper
        }
        return nil
    }

    private static func field(at scope: String, in site: Site) -> Field? {
        guard let property = resolve(scope, in: site.properties) else { return nil }
        let key = name(of: scope)
        // `visibleOn` present and empty is a decision; absent is not one.
        let hidden = (property["visibleOn"] as? [Any])?.isEmpty ?? false
        return Field(title: property["title"] as? String ?? readable(key),
                     type: property["type"] as? String,
                     choices: (property["enum"] as? [Any] ?? []).map { "\($0)" },
                     isRequired: site.required.contains(key),
                     isReadOnly: property["readOnly"] as? Bool ?? false,
                     isHidden: hidden,
                     detail: property["description"] as? String)
    }

    private static func name(of scope: String) -> String {
        String(scope.split(separator: "/").last ?? "")
    }

    /// `cluster_reader_endpoint` → `Cluster Reader Endpoint`. Only ever a
    /// fallback: a `title` in the schema always wins.
    public static func readable(_ key: String) -> String {
        guard !key.isEmpty else { return "" }
        return key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// A `Label` is written in markdown and drawn as one line of prose, so the
    /// marks come off. Not a markdown renderer: the point is to read the
    /// sentence, and `**IAM**` with the stars still on reads worse than without.
    static func plain(_ markdown: String) -> String {
        var text = markdown
        // A link becomes its text: the URL is not something you can press on a
        // drawing, and it is usually longer than the sentence around it.
        if let links = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#) {
            let full = NSRange(text.startIndex..., in: text)
            text = links.stringByReplacingMatches(in: text, range: full, withTemplate: "$1")
        }
        for mark in ["**", "__", "*", "_", "`"] {
            text = text.replacingOccurrences(of: mark, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
