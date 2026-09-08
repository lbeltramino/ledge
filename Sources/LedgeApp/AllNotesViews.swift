import AppKit
import LedgeCore
import LedgeIndex

/// One row in the list: colour bar, title, a line of the note, its state, and
/// when it last changed.
final class NoteRowView: NSTableCellView {

    private let bar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let badge = StateBadge()
    private let timeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        addSubview(bar)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        snippetLabel.font = Typography.noteBody(size: 13)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.lineBreakMode = .byTruncatingTail
        addSubview(snippetLabel)

        addSubview(badge)

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right
        addSubview(timeLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(record: NoteRecord, excerpt: String) {
        bar.layer?.backgroundColor = Palette.tab(record.color).cgColor
        titleLabel.stringValue = record.displayTitle
        // Search marks its match with private-use sentinels; the list shows the
        // text, not the sentinels.
        snippetLabel.stringValue = excerpt
            .replacingOccurrences(of: SearchHit.openMark, with: "")
            .replacingOccurrences(of: SearchHit.closeMark, with: "")
        badge.state = record.state
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        timeLabel.stringValue = formatter.localizedString(for: record.updated, relativeTo: Date())
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        bar.frame = NSRect(x: pad, y: 10, width: 3, height: bounds.height - 20)
        let left = pad + 13
        let right = bounds.width - pad
        let timeWidth: CGFloat = 44
        let badgeWidth = badge.intrinsicContentSize.width

        timeLabel.frame = NSRect(x: right - timeWidth, y: bounds.height - 26, width: timeWidth, height: 15)
        badge.frame = NSRect(x: right - timeWidth - badgeWidth - 8, y: bounds.height - 27,
                             width: badgeWidth, height: 16)
        titleLabel.frame = NSRect(x: left, y: bounds.height - 27,
                                  width: badge.frame.minX - left - 8, height: 17)
        snippetLabel.frame = NSRect(x: left, y: 9, width: right - left, height: 18)
    }
}

/// ACTIVE / ARCHIVED. State is never carried by colour alone.
final class StateBadge: NSView {
    var state: NoteState = .active { didSet { needsDisplay = true } }

    private var text: String { state == .active ? "ACTIVE" : "ARCHIVED" }
    private var font: NSFont { .systemFont(ofSize: 9, weight: .semibold) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.5,
        ]
        NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }
}

/// The right-hand pane: the selected note, shown as itself.
final class DetailPane: NSView {

    var onArchive: ((String) -> Void)?
    var onRestore: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onOpen: ((String) -> Void)?

    private let stateLabel = NSTextField(labelWithString: "")
    private let openButton = ChromeButton(title: "Open")
    private let archiveButton = ChromeButton(title: "Archive")
    private let deleteButton = ChromeButton(title: "Delete", destructive: true)
    private let paper = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let datesLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")

    private var current: NoteRecord?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stateLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        stateLabel.textColor = .secondaryLabelColor
        addSubview(stateLabel)

        openButton.onClick = { [weak self] in self.flatMap { $0.current }.map { self?.onOpen?($0.id) } }
        archiveButton.onClick = { [weak self] in
            guard let self, let record = current else { return }
            record.state == .active ? onArchive?(record.id) : onRestore?(record.id)
        }
        deleteButton.onClick = { [weak self] in self.flatMap { $0.current }.map { self?.onDelete?($0.id) } }
        for button in [openButton, archiveButton, deleteButton] { addSubview(button) }

        paper.wantsLayer = true
        paper.layer?.cornerRadius = 10
        paper.layer?.cornerCurve = .continuous
        addSubview(paper)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        paper.addSubview(titleLabel)

        bodyLabel.font = Typography.noteBody(size: 16)
        paper.addSubview(bodyLabel)

        datesLabel.font = .systemFont(ofSize: 11)
        paper.addSubview(datesLabel)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(nothing message: String) {
        current = nil
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        for view in [paper, stateLabel, openButton, archiveButton, deleteButton] { view.isHidden = true }
        needsLayout = true
    }

    func show(record: NoteRecord, body: String) {
        current = record
        emptyLabel.isHidden = true
        for view in [paper, stateLabel, openButton, archiveButton, deleteButton] { view.isHidden = false }

        let dark = effectiveAppearance.isDark
        stateLabel.stringValue = record.state == .active ? "ACTIVE · IN THE DECK" : "ARCHIVED"
        archiveButton.isHidden = false
        paper.layer?.backgroundColor = Palette.paper(record.color, dark: dark,
                                                     tint: Jitter(id: record.id).paperTint).cgColor
        let ink = Palette.ink(dark: dark)
        titleLabel.stringValue = record.displayTitle
        titleLabel.textColor = ink
        bodyLabel.stringValue = body
        bodyLabel.textColor = ink.withAlphaComponent(0.92)

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        datesLabel.stringValue = "Created \(formatter.string(from: record.created))"
            + " · Updated \(relative.localizedString(for: record.updated, relativeTo: Date()))"
        datesLabel.textColor = ink.withAlphaComponent(0.45)

        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 22
        emptyLabel.frame = NSRect(x: pad, y: bounds.height / 2 - 10, width: bounds.width - pad * 2, height: 20)

        var x = bounds.width - pad
        for button in [deleteButton, archiveButton, openButton] {
            let width = button.intrinsicContentSize.width
            x -= width
            button.frame = NSRect(x: x, y: pad, width: width, height: 22)
            x -= 5
        }
        stateLabel.frame = NSRect(x: pad, y: pad + 4, width: 180, height: 14)
        if let record = current {
            archiveButton.title2 = record.state == .active ? "Archive" : "Restore"
        }

        paper.frame = NSRect(x: pad, y: pad + 40,
                             width: bounds.width - pad * 2,
                             height: max(120, bounds.height - pad * 2 - 46))
        let inner: CGFloat = 18
        titleLabel.frame = NSRect(x: inner, y: paper.bounds.height - inner - 20,
                                  width: paper.bounds.width - inner * 2, height: 20)
        datesLabel.frame = NSRect(x: inner, y: inner - 4, width: paper.bounds.width - inner * 2, height: 16)
        bodyLabel.frame = NSRect(x: inner, y: inner + 26,
                                 width: paper.bounds.width - inner * 2,
                                 height: max(0, paper.bounds.height - inner * 2 - 52))
    }
}

extension ChromeButton {
    /// Lets the detail pane relabel Archive/Restore without rebuilding the row.
    var title2: String {
        get { title }
        set { relabel(newValue) }
    }
}
