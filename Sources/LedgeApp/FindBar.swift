import AppKit

/// Find inside a note.
///
/// The matches are drawn with the same marker stroke as `==highlight==`, in a
/// different pen, so searching looks like the rest of the app rather than like
/// a system find bar bolted onto a sticky note.
final class FindBar: NSView, NSTextFieldDelegate {

    var onQuery: ((String) -> Void)?
    var onStep: ((Int) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = ChromeButton(title: "‹")
    private let next = ChromeButton(title: "›")
    private let close = ChromeButton(title: "✕")

    static var height: CGFloat { max(26, Metrics.Card.titleSize * 2.0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        field.placeholderString = "Find"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: max(10, Metrics.Card.titleSize * 0.82))
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        addSubview(field)

        count.font = .systemFont(ofSize: max(9, Metrics.Card.titleSize * 0.72))
        count.alignment = .right
        addSubview(count)

        previous.onClick = { [weak self] in self?.onStep?(-1) }
        next.onClick = { [weak self] in self?.onStep?(1) }
        close.onClick = { [weak self] in self?.onClose?() }
        for button in [previous, next, close] { button.isHidden = false; addSubview(button) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var query: String { field.stringValue }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func show(matches: Int, current: Int) {
        count.stringValue = matches == 0
            ? (field.stringValue.isEmpty ? "" : "none")
            : "\(current + 1) of \(matches)"
        previous.isHidden = matches == 0
        next.isHidden = matches == 0
        needsLayout = true
    }

    func tint(paper: NSColor, ink: NSColor) {
        layer?.backgroundColor = ink.withAlphaComponent(0.07).cgColor
        field.textColor = ink
        count.textColor = ink.withAlphaComponent(0.5)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 7
        var x = bounds.width - pad
        for button in [close, next, previous] where !button.isHidden {
            let width = max(18, button.intrinsicContentSize.width * 0.7)
            x -= width
            button.frame = NSRect(x: x, y: 2, width: width, height: bounds.height - 4)
            x -= 2
        }
        let countWidth: CGFloat = count.stringValue.isEmpty ? 0 : 56
        count.frame = NSRect(x: x - countWidth - 4, y: 3, width: countWidth, height: bounds.height - 6)
        field.frame = NSRect(x: pad, y: 3, width: max(20, count.frame.minX - pad - 4),
                             height: bounds.height - 6)
    }

    func controlTextDidChange(_ obj: Notification) {
        onQuery?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(1); return true
        case #selector(NSResponder.insertBacktab(_:)):
            onStep?(-1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?(); return true
        default:
            return false
        }
    }
}
