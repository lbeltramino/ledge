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
    private let highlighter: MarkdownHighlighter

    private let record: NoteRecord
    private let focus = FocusReturn()

    var onEdit: ((String) -> Void)?
    var onTitle: ((String) -> Void)?
    var onClose: (() -> Void)?

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
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = ink
        textView.insertionPointColor = ink
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = Typography.noteBody(size: 20)
        textView.string = body
        textView.textStorage?.delegate = highlighter
        if let storage = textView.textStorage { highlighter.highlight(storage) }
        textView.onChange = { [weak self] in self?.onEdit?(self?.textView.string ?? "") }
        textView.onEscape = { [weak self] in self?.window.performClose(nil) }

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        content.addSubview(scroll)

        buildToolbar()
        content.addSubview(toolbar)

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
        scroll.frame = NSRect(x: x, y: inset + toolbarHeight + 10,
                              width: width,
                              height: content.bounds.height - top - titleHeight - 18
                                      - inset - toolbarHeight - 10)
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                       height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    }

    func show() {
        focus.capture()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func close() { window.performClose(nil) }

    func syncBody(_ text: String) { textView.syncBody(text) }

    var isVisible: Bool { window.isVisible }

    func windowDidResize(_ notification: Notification) { layout() }

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
