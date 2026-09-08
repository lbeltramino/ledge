import AppKit
import LedgeCore
import LedgeIndex

/// Reports what a note's text view is actually doing, on the machine where it
/// is going wrong.
///
/// Written after two wrong guesses from a distance — first the font, then the
/// text colour. Both were plausible and neither was the whole story. Run with
/// `--diagnose` and it prints what it can see rather than what it expects.
@MainActor
enum Diagnose {

    static func run() {
        // Unbuffered: if any of this traps, the output up to that point is the
        // most useful thing it can leave behind.
        setvbuf(stdout, nil, _IONBF, 0)
        print("Ledge diagnostics")
        print(String(repeating: "─", count: 62))
        environment()
        fonts()
        textView()
        print("")
        print("code blocks")
        codeSupport()
        print(String(repeating: "─", count: 62))
        print("Paste this whole output back.")
    }

    private static func environment() {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let appearance = NSApp.effectiveAppearance
        print("macOS            \(version)")
        print("appearance       \(appearance.name.rawValue)")
        print("bundle version   "
            + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"))
        print("screens          "
            + NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height))@\($0.backingScaleFactor)x" }
                .joined(separator: ", "))
        print("reduce motion    \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
        print("increase contrast \(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)")
    }

    private static func fonts() {
        print("")
        for name in ["Caveat", "Caveat-Regular", "Bradley Hand"] {
            let font = NSFont(name: name, size: 17)
            print("font \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) "
                + (font.map { "\($0.fontName) \($0.pointSize)pt" } ?? "missing"))
        }
        let resolved = Typography.noteBody(size: 17)
        print("resolved body    \(resolved.fontName) \(resolved.pointSize)pt "
            + "(\(Typography.effectiveFace.rawValue))")
        print("glyph count      \(resolved.numberOfGlyphs)")
    }

    private static func textView() {
        var note = Note(title: "Diagnostic", color: .green)
        note.body = "- apple\n- 4x banana\n- dry fruits"
        let record = NoteRecord(note: note, filename: "Diagnostic.md", mtime: 0, size: 0, hash: "")

        let card = NoteCardView(record: record, body: note.body)
        card.frame = NSRect(x: 0, y: 0, width: 340, height: 260)
        card.layoutSubtreeIfNeeded()
        card.applyColors()
        card.layoutSubtreeIfNeeded()
        card.displayIfNeeded()

        let view = card.textView
        print("")
        print("card frame       \(short(card.frame))")
        print("textView frame   \(short(view.frame))")
        print("  string length  \(view.string.count)")
        print("  textColor      \(describe(view.textColor))")
        // The container's height is usually .greatestFiniteMagnitude, which is
        // not representable as an Int — converting it traps, which is how the
        // first version of this diagnostic crashed before printing anything.
        print("  container      "
            + (view.textContainer.map { measure($0.size) } ?? "none"))
        print("  tracks width   \(view.textContainer?.widthTracksTextView ?? false)")
        print("  vert resizable \(view.isVerticallyResizable)")
        print("  TextKit        \(view.textLayoutManager == nil ? "1 (compatibility)" : "2")")

        if let manager = view.layoutManager, let container = view.textContainer {
            manager.ensureLayout(for: container)
            print("  glyphs         \(manager.numberOfGlyphs)")
            print("  used rect      \(short(manager.usedRect(for: container)))")
        } else if let layout = view.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            print("  usage bounds   \(short(layout.usageBoundsForTextContainer))")
        }

        // and the thing that actually matters: does anything get drawn?
        let applied = (view.textStorage?.length ?? 0) > 0
            ? view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            : nil
        print("  applied colour \(describe(applied))")
        print("  paper          \(describe(card.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }))")
        print("  ink pixels     \(inkPixels(in: card))  (0 means nothing was drawn)")
    }

    /// Which code forms the highlighter actually understands.
    ///
    /// Measured by running it, so the answer cannot drift from the rules the
    /// way a list in a README does.
    static func codeSupport() {
        let samples: [(String, String, String)] = [
            ("inline", "call `foo()` now", "foo()"),
            ("fenced, no language", "```\nlet a = 1\n```", "let a = 1"),
            ("fenced with a language", "```swift\nlet b = 2\n```", "let b = 2"),
            ("fence line itself", "```swift\nlet c = 3\n```", "```swift"),
            ("indented four spaces", "text\n\n    let d = 4\n", "let d = 4"),
            ("tilde fence", "~~~\nlet e = 5\n~~~", "let e = 5"),
            ("inline across lines", "`one\ntwo`", "one"),
        ]

        for (name, source, needle) in samples {
            let highlighter = MarkdownHighlighter(baseFont: .systemFont(ofSize: 14),
                                                  ink: .black, accent: .blue)
            let storage = NSTextStorage(string: source)
            highlighter.highlight(storage)
            let range = (source as NSString).range(of: needle)
            guard range.location != NSNotFound else { continue }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let background = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil)
            let paragraph = storage.attribute(.paragraphStyle, at: range.location,
                                              effectiveRange: nil) as? NSParagraphStyle
            print(String(format: "    %-24@ mono=%@  block=%@  indent=%@",
                         name as NSString,
                         (font?.isFixedPitch ?? false) ? "yes" : "no ",
                         background != nil ? "yes" : "no ",
                         (paragraph?.headIndent ?? 0) > 0 ? "yes" : "no "))
        }
    }

    private static func inkPixels(in card: NoteCardView) -> Int {
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds),
              let paper = card.layer?.backgroundColor.flatMap({ NSColor(cgColor: $0) })
        else { return -1 }
        card.cacheDisplay(in: card.bounds, to: rep)
        var ink = 0
        for x in stride(from: 60, to: Int(card.bounds.width) - 20, by: 2) {
            for y in stride(from: 55, to: Int(card.bounds.height) - 60, by: 2) {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                if !pixel.isCloseTo(paper, tolerance: 0.10) { ink += 1 }
            }
        }
        return ink
    }

    private static func measure(_ size: NSSize) -> String {
        func part(_ value: CGFloat) -> String {
            value >= CGFloat.greatestFiniteMagnitude / 2 ? "∞" : String(format: "%.0f", value)
        }
        return "\(part(size.width))×\(part(size.height))"
    }

    private static func short(_ rect: NSRect) -> String {
        String(format: "%.0f,%.0f ", rect.minX, rect.minY) + measure(rect.size)
    }

    private static func describe(_ color: NSColor?) -> String {
        guard let c = color?.usingColorSpace(.sRGB) else { return "none" }
        return String(format: "#%02X%02X%02X @%.2f",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), c.alphaComponent)
    }
}
