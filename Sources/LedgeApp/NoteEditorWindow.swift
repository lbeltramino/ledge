import AppKit
import LedgeCore
import LedgeIndex

/// The note, opened properly.
///
/// A sticky note is deliberately too small to write anything long in. This is
/// the same note on a real page: the same paper, the same face, the same live
/// Markdown — just room to think. It is a window rather than a modal, so it does
/// not hold the rest of the Mac hostage while it is open.
@MainActor
final class NoteEditorWindow: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let titleField = NSTextField()
    let textView = NoteTextView()
    private let scroll = NSScrollView()
    private let toolbar = NSStackView()
    private let findBar = FindBar()
    private var isFinding = false
    private let highlighter: MarkdownHighlighter

    private let record: NoteRecord
    private let focus = FocusReturn()

    var onEdit: ((String) -> Void)?
    var onTitle: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onOpenLink: ((String) -> Void)?

    init(record: NoteRecord, title: String, body: String) {
        self.record = record

        let dark = NSApp.effectiveAppearance.isDark
        let paper = Palette.paper(record.color, dark: dark, tint: Jitter(id: record.id).paperTint)
        let ink = Palette.ink(dark: dark)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        highlighter = MarkdownHighlighter(
            baseFont: Typography.noteBody(size: 20),
            ink: ink,
            accent: Palette.tab(record.color).blended(withFraction: 0.35, of: ink) ?? ink
        )
        super.init()

        // Under ARC this must be false: AppKit would otherwise release the
        // window on close while `editors[id]` still holds it.
        window.isReleasedWhenClosed = false
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = paper
        window.minSize = NSSize(width: 420, height: 320)
        window.delegate = self
        window.center()

        let content = NSView()
        content.wantsLayer = true
        window.contentView = content

        titleField.stringValue = title
        titleField.placeholderString = "Title"
        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.textColor = ink
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.cell?.usesSingleLineMode = true
        titleField.delegate = self
        content.addSubview(titleField)

        textView.isRichText = false
        textView.configureForNotes()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = ink
        textView.insertionPointColor = ink
        textView.codeCopy.ink = ink
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = Typography.noteBody(size: 20)
        textView.string = body
        highlighter.highlight = MarkerStroke.colour(for: record.color, dark: dark)
        textView.strokeSeed = record.id
        textView.textStorage?.delegate = highlighter
        if let storage = textView.textStorage { highlighter.highlight(storage) }
        textView.onChange = { [weak self] in self?.onEdit?(self?.textView.string ?? "") }
        textView.onEscape = { [weak self] in self?.window.performClose(nil) }
        textView.onOpenLink = { [weak self] name in self?.onOpenLink?(name) }

        // An NSTextView made the document view of a hand-built scroll view has to
        // be told how to size itself. Without this its frame is undefined: on
        // some macOS versions it happens to come out right, and on others it
        // lays out no glyphs at all while the insertion point still tracks —
        // a caret moving over text that was never drawn.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        content.addSubview(scroll)

        buildToolbar()
        content.addSubview(toolbar)

        findBar.isHidden = true
        findBar.onQuery = { [weak self] query in self?.runFind(query) }
        findBar.onStep = { [weak self] delta in self?.stepFind(delta) }
        findBar.onClose = { [weak self] in self?.endFind() }
        content.addSubview(findBar)

        textView.strokeSeed = record.id
        textView.findColour = { [weak self] current in
            MarkerStroke.findColour(for: record.color,
                                    dark: self?.window.effectiveAppearance.isDark ?? false,
                                    current: current)
        }
        textView.onFind = { [weak self] in self?.beginFind() }
        textView.onSuggestedTitle = { [weak self] suggested in
            guard let self, self.titleField.stringValue.isEmpty else { return }
            self.titleField.stringValue = suggested
            self.window.title = suggested
            self.onTitle?(suggested)
        }
        textView.onStepFind = { [weak self] delta in self?.stepFind(delta) }

        layout()
    }

    /// Markdown you can reach without knowing it. The shortcuts do the same
    /// thing; this is so you find out they exist.
    private func buildToolbar() {
        toolbar.orientation = .horizontal
        toolbar.spacing = 4

        let actions: [(String, () -> Void)] = [
            ("H1", { [weak self] in self.map { MarkdownEditing.togglePrefix($0.textView, "# ") } }),
            ("H2", { [weak self] in self.map { MarkdownEditing.togglePrefix($0.textView, "## ") } }),
            ("Bold", { [weak self] in self.map { MarkdownEditing.wrap($0.textView, with: "**") } }),
            ("Italic", { [weak self] in self.map { MarkdownEditing.wrap($0.textView, with: "*") } }),
            ("List", { [weak self] in self.map { MarkdownEditing.togglePrefix($0.textView, "- ") } }),
            ("Quote", { [weak self] in self.map { MarkdownEditing.togglePrefix($0.textView, "> ") } }),
            ("Code", { [weak self] in self.map { MarkdownEditing.code($0.textView) } }),
            ("Link", { [weak self] in self.map { MarkdownEditing.link($0.textView) } }),
            ("Highlight", { [weak self] in self.map { MarkdownEditing.wrap($0.textView, with: "==") } }),
        ]
        for (title, action) in actions {
            let button = ChromeButton(title: title)
            button.onClick = action
            button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
            toolbar.addArrangedSubview(button)
        }
    }

    private func layout() {
        guard let content = window.contentView else { return }
        let inset: CGFloat = 44
        let top: CGFloat = 34
        let width = min(content.bounds.width - inset * 2, 640)
        let x = (content.bounds.width - width) / 2

        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(x: x - 2, y: content.bounds.height - top - titleHeight,
                                  width: width + 2, height: titleHeight)
        let toolbarHeight: CGFloat = 24
        toolbar.frame = NSRect(x: x - 9, y: inset - 4, width: width, height: toolbarHeight)

        var textTop = content.bounds.height - top - titleHeight - 18
        if isFinding {
            findBar.frame = NSRect(x: x, y: textTop - FindBar.height, width: width,
                                   height: FindBar.height)
            textTop -= FindBar.height + 8
        }
        scroll.frame = NSRect(x: x, y: inset + toolbarHeight + 10,
                              width: width,
                              height: max(60, textTop - inset - toolbarHeight - 10))
        let visible = scroll.contentSize
        textView.frame = NSRect(x: 0, y: 0, width: visible.width,
                                height: max(visible.height, textView.frame.height))
        textView.textContainer?.containerSize = NSSize(width: visible.width,
                                                       height: .greatestFiniteMagnitude)
    }

    func show() {
        focus.capture()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func close() { window.performClose(nil) }

    func beginFind() {
        isFinding = true
        findBar.isHidden = false
        let dark = window.effectiveAppearance.isDark
        findBar.tint(paper: Palette.paper(record.color, dark: dark), ink: Palette.ink(dark: dark))
        layout()
        findBar.focus()
        runFind(findBar.query)
    }

    func endFind() {
        isFinding = false
        findBar.isHidden = true
        textView.clearFind()
        layout()
        window.makeFirstResponder(textView)
    }

    private func runFind(_ query: String) {
        let count = textView.find(query)
        findBar.show(matches: count, current: textView.currentMatch)
        if count > 0 { textView.scrollRangeToVisible(textView.findMatches[textView.currentMatch]) }
    }

    private func stepFind(_ delta: Int) {
        let current = textView.stepMatch(delta)
        findBar.show(matches: textView.findMatches.count, current: current)
    }

    func syncBody(_ text: String) { textView.syncBody(text) }

    /// The editor is the same note on a bigger page, so it repaints too.
    func setColor(_ color: NoteColor) {
        let dark = NSApp.effectiveAppearance.isDark
        window.backgroundColor = Palette.paper(color, dark: dark, tint: Jitter(id: record.id).paperTint)
        highlighter.accent = Palette.tab(color)
            .blended(withFraction: 0.35, of: Palette.ink(dark: dark)) ?? Palette.ink(dark: dark)
        if let storage = textView.textStorage { highlighter.highlight(storage) }
    }

    var isVisible: Bool { window.isVisible }

    func windowDidResize(_ notification: Notification) { layout() }

    /// Same hazard as the card: the highlighter owns the text's colour, so it
    /// has to be told when light and dark swap over.
    func windowDidChangeBackingProperties(_ notification: Notification) { restyle() }

    private func restyle() {
        let dark = NSApp.effectiveAppearance.isDark
        let ink = Palette.ink(dark: dark)
        window.backgroundColor = Palette.paper(record.color, dark: dark,
                                               tint: Jitter(id: record.id).paperTint)
        titleField.textColor = ink
        textView.textColor = ink
        textView.insertionPointColor = ink
        textView.codeCopy.ink = ink
        highlighter.ink = ink
        highlighter.accent = Palette.tab(record.color)
            .blended(withFraction: 0.35, of: ink) ?? ink
        highlighter.highlight = MarkerStroke.colour(for: record.color, dark: dark)
        if let storage = textView.textStorage { highlighter.highlight(storage) }
    }

    func windowWillClose(_ notification: Notification) {
        commitTitle()
        onEdit?(textView.string)
        onClose?()
        focus.restore()
    }

    private func commitTitle() {
        let typed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != window.title else { return }
        window.title = typed
        onTitle?(typed)
    }
}

extension NoteEditorWindow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) { commitTitle() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            commitTitle()
            window.makeFirstResponder(self.textView)
            return true
        default:
            return false
        }
    }
}
