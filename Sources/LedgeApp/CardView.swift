import AppKit
import LedgeCore
import LedgeIndex

/// A note at full size.
///
/// This is not a card *beside* a tab — it **is** the tab, grown. The coloured
/// strip down its leading edge carries the same vertical title the tab had, so
/// what you see is one object extending out of the screen edge rather than one
/// element vanishing and another appearing next to it.
///
/// It leans by its own `Jitter` while you are reading it and levels out the
/// moment the caret lands — crooked to read, straight to write, which is also
/// what makes the handwriting legible exactly when it matters.
final class NoteCardView: NSView {

    let record: NoteRecord
    let jitter: Jitter

    var onEdit: ((String) -> Void)?          // body changed
    var onTitle: ((String) -> Void)?         // title committed
    /// Clicking the coloured strip folds the note back into its tab, leaving
    /// the rest of the deck fanned.
    var onClose: (() -> Void)?
    /// Opens the note in a full editor.
    var onExpand: (() -> Void)?
    /// The strip was dragged rather than clicked — pull the note off the deck.
    var onStripDrag: (() -> Void)?

    private var isDetached = false
    /// True on a left-edge strip: the label strip rides the right edge instead.
    /// True on a bottom strip: the label strip runs along the bottom instead of
    /// down one side.
    var horizontal = false {
        didSet {
            updateCorners()
            needsLayout = true
            needsDisplay = true
        }
    }

    var mirrored = false {
        didSet {
            updateCorners()
            needsLayout = true
            needsDisplay = true
        }
    }
    private var stripDragOrigin: NSPoint?
    private let expandButton = ExpandButton()
    let resizeHandle = ResizeHandle()
    private lazy var chrome = NoteChromeBar(color: color)
    private lazy var findBar = FindBar()
    private var isFinding = false

    var onColor: ((NoteColor) -> Void)?
    var onDelete: (() -> Void)?
    var onArchive: (() -> Void)?
    var onBeginEditing: (() -> Void)?

    /// Kept separately from `record` so a rename shows immediately, without
    /// tearing the card down and losing the caret.
    var title: String { didSet { titleField.stringValue = title; needsDisplay = true } }

    /// Kept separately from `record` for the same reason as `title`: a recolour
    /// should repaint the paper you are looking at, not rebuild the card and
    /// take your caret with it.
    var color: NoteColor { didSet { applyColors(); needsDisplay = true } }

    private let titleField = NSTextField()
    private let scroll = NSScrollView()
    let textView = NoteTextView()

    private(set) var isEditing = false
    private var highlighter: MarkdownHighlighter?

    init(record: NoteRecord, body: String) {
        self.record = record
        self.title = record.displayTitle
        self.color = record.color
        self.jitter = Jitter(id: record.id)
        super.init(frame: .zero)
        wantsLayer = true
        setUp(body: body)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var isDark: Bool { effectiveAppearance.isDark }

    private func setUp(body: String) {
        layer?.cornerRadius = Metrics.Card.cornerRadius
        updateCorners()
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.30 * CGFloat(jitter.shadowScale))
            s.shadowBlurRadius = 26 * CGFloat(jitter.shadowScale)
            s.shadowOffset = NSSize(width: 0, height: -7)
            return s
        }()

        // The title is editable in place — click it and type. There is nowhere
        // else in the app to rename a note from the deck.
        titleField.font = .systemFont(ofSize: Metrics.Card.titleSize, weight: .semibold)
        titleField.stringValue = title
        titleField.placeholderString = "Title"
        titleField.isEditable = true
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.delegate = self
        titleField.target = self
        addSubview(titleField)


        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.font = Typography.noteBody(size: Metrics.Card.bodySize)
        textView.string = body
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        let dark = isDark
        let markdown = MarkdownHighlighter(
            baseFont: Typography.noteBody(size: Metrics.Card.bodySize),
            ink: Palette.ink(dark: dark),
            accent: Palette.tab(color).blended(withFraction: 0.4, of: Palette.ink(dark: dark))
                ?? Palette.ink(dark: dark)
        )
        markdown.highlight = MarkerStroke.colour(for: color, dark: dark)
        textView.strokeSeed = record.id
        textView.textStorage?.delegate = markdown
        if let storage = textView.textStorage { markdown.highlight(storage) }
        highlighter = markdown
        textView.onChange = { [weak self] in self?.onEdit?(self?.textView.string ?? "") }
        textView.onFind = { [weak self] in self?.beginFind() }
        textView.onStepFind = { [weak self] delta in self?.stepFind(delta) }
        textView.onBeginEditing = { [weak self] in
            self?.setEditing(true)
            self?.onBeginEditing?()
        }

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
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        addSubview(scroll)

        expandButton.onClick = { [weak self] in self?.onExpand?() }
        addSubview(expandButton)

        chrome.onColor = { [weak self] color in self?.onColor?(color) }
        chrome.onDelete = { [weak self] in self?.onDelete?() }
        chrome.onArchive = { [weak self] in self?.onArchive?() }
        chrome.onClose = { [weak self] in self?.onClose?() }
        addSubview(chrome)
        addSubview(resizeHandle)
        resizeHandle.alphaValue = 0

        findBar.isHidden = true
        findBar.onQuery = { [weak self] query in self?.runFind(query) }
        findBar.onStep = { [weak self] delta in self?.stepFind(delta) }
        findBar.onClose = { [weak self] in self?.endFind() }
        addSubview(findBar)

        textView.findColour = { [weak self] current in
            guard let self else { return .systemBlue.withAlphaComponent(0.3) }
            return MarkerStroke.findColour(for: color, dark: isDark, current: current)
        }

        // Nothing but paper until you commit to the note. Reading it should not
        // put five buttons in front of you.
        chrome.alphaValue = 0
        expandButton.alphaValue = 0

        applyColors()
        applyLean()
    }

    /// A floating note sits square: it is on the desk, not on the edge.
    private func updateCorners() {
        // Against an edge only the inner corners are rounded; on the desk the
        // card is a whole object again.
        let all: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner,
                                 .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        if isDetached { layer?.maskedCorners = all; return }
        // The rounded corners are the band's corners, so they follow it to the top.
        if horizontal { layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]; return }
        layer?.maskedCorners = mirrored
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }

    func setDetached(_ detached: Bool) {
        isDetached = detached
        updateCorners()
        if detached { layer?.transform = CATransform3DIdentity }
        needsLayout = true
        needsDisplay = true
    }

    /// Narrow enough and the controls start overlapping each other, so this is
    /// the floor the deck honours when it sizes a card.
    var minimumWidth: CGFloat {
        // The band costs width on every card except one on a bottom strip, where
        // it runs along the top. A *detached* card has it on the left like any
        // other — treating it as free is what collapsed the buttons on a note
        // pulled off the deck.
        chrome.minimumWidth + Metrics.Card.padding * 2 + Metrics.Card.overhang
            + (bandRunsAlongTheTop ? 0 : Metrics.Card.labelStrip)
    }

    /// True only on a bottom strip's card, where the band is horizontal.
    var bandRunsAlongTheTop: Bool { horizontal && !isDetached }

    var minimumHeight: CGFloat {
        Metrics.Card.padding * 3 + Metrics.Card.titleSize * 2.4
            + NoteChromeBar.height + 60 + (bandRunsAlongTheTop ? Metrics.Card.labelStrip : 0)
    }

    /// The colour the text is *actually* drawn in, and the paper it is actually
    /// drawn on — read back rather than recomputed, so a check on them means
    /// something.
    var paintedTextAndPaper: (text: NSColor, paper: NSColor)? {
        guard let storage = textView.textStorage, storage.length > 0,
              let background = layer?.backgroundColor.flatMap({ NSColor(cgColor: $0) })
        else { return nil }
        let applied = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        return (applied ?? textView.textColor ?? .black, background)
    }

    /// Forces an appearance the way moving between windows or displays does.
    func adopt(appearance: NSAppearance?) {
        self.appearance = appearance
        applyColors()
    }

    /// What a keystroke ends up doing: the highlighter repaints every character.
    /// `applyColors` sets `textColor` last and so papers over a stale
    /// highlighter — until the next key is pressed. That is the moment worth
    /// checking, not the moment right after a repaint.
    func repaintAsTypingWould() {
        guard let storage = textView.textStorage else { return }
        highlighter?.highlight(storage)
    }

    var chromeOverlaps: Bool {
        layoutSubtreeIfNeeded()
        return chrome.hasOverlappingControls
    }

    /// For the self test: how visible the controls currently are.
    var chromeAlpha: Double { Double(chrome.alphaValue) }

    private var trailingInset: CGFloat {
        isDetached ? Metrics.Card.padding : Metrics.Card.padding + Metrics.Card.overhang
    }

    func applyColors() {
        let dark = isDark
        layer?.backgroundColor = Palette.paper(color, dark: dark, tint: jitter.paperTint).cgColor
        let ink = Palette.ink(dark: dark)

        // The highlighter repaints every character on each keystroke, so it has
        // to follow the appearance too. Left with the ink it was born with, it
        // wrote dark-mode ink onto light paper — a caret that moved over text
        // nobody could see.
        highlighter?.ink = ink
        highlighter?.accent = Palette.tab(color).blended(withFraction: 0.4, of: ink) ?? ink
        highlighter?.highlight = MarkerStroke.colour(for: color, dark: dark)
        if let storage = textView.textStorage { highlighter?.highlight(storage) }
        titleField.textColor = ink
        textView.textColor = ink.withAlphaComponent(0.92)
        textView.insertionPointColor = ink
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: - find inside the note

    /// ⌘F inside a note. The matches are drawn with the same marker stroke as a
    /// highlight, in a different pen, so searching looks like the rest of the
    /// app rather than like a system find bar on a sticky note.
    func beginFind() {
        isFinding = true
        findBar.isHidden = false
        findBar.tint(paper: Palette.paper(color, dark: isDark), ink: Palette.ink(dark: isDark))
        needsLayout = true
        layoutSubtreeIfNeeded()
        findBar.focus()
        runFind(findBar.query)
    }

    func endFind() {
        isFinding = false
        findBar.isHidden = true
        textView.clearFind()
        needsLayout = true
        window?.makeFirstResponder(textView)
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

    func applyLean() {
        guard !isDetached else { layer?.transform = CATransform3DIdentity; return }
        let degrees = jitter.cardRotation(focused: isEditing)
        let rotate = CATransform3DMakeRotation(CGFloat(degrees) * .pi / 180, 0, 0, 1)
        if isEditing {
            let animation = Motion.animation("transform", spring: .card)
            animation.fromValue = layer?.presentation()?.transform ?? layer?.transform as Any
            animation.toValue = rotate
            layer?.add(animation, forKey: "lean")
        }
        layer?.transform = rotate
    }

    func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        applyLean()
        revealChrome(editing)
    }

    /// The controls appear when you click into a note, and only then. A click is
    /// the signal that you mean to work with it rather than glance at it.
    private func revealChrome(_ visible: Bool) {
        chrome.isInert = !visible
        expandButton.isInert = !visible
        resizeHandle.isInert = !visible
        let target: CGFloat = visible ? 1 : 0

        for view in [chrome as NSView, expandButton as NSView, resizeHandle as NSView] {
            view.wantsLayer = true
            // An explicit layer animation rather than `animator()`, so the value
            // is true the instant it is set and the fade is only presentation.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = view.layer?.presentation()?.opacity ?? view.layer?.opacity ?? 0
            fade.toValue = Float(target)
            fade.duration = Motion.reduceMotion ? 0.001 : (visible ? 0.16 : 0.12)
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(fade, forKey: "chromeFade")
            view.alphaValue = target
        }
    }

    /// The band rides the *leading* edge — the one that travelled outward — not
    /// the edge the tab was on. A right-hand card is flush right with its band on
    /// the left; a bottom card is flush to the bottom and grows upward, so its
    /// band belongs at the top.
    var stripRect: NSRect {
        if horizontal && !isDetached {
            return NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.Card.labelStrip)
        }
        return NSRect(x: mirrored && !isDetached ? bounds.width - Metrics.Card.labelStrip : 0,
                      y: 0, width: Metrics.Card.labelStrip, height: bounds.height)
    }

    var labelBox: NSRect {
        VerticalLabel.box(for: title, in: stripRect,
                          inset: Metrics.Tab.labelInset, size: Metrics.Tab.labelSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The strip that was the tab — the same paper, a shade deeper.
        Palette.stripe(color, dark: isDark).setFill()
        let strip = NSBezierPath(roundedRect: stripRect, xRadius: Metrics.Card.cornerRadius,
                                 yRadius: Metrics.Card.cornerRadius)
        strip.fill()
        // square off the side that meets the paper
        if horizontal && !isDetached {
            // square off where the band meets the paper below it
            NSRect(x: 0, y: stripRect.maxY - Metrics.Card.cornerRadius,
                   width: bounds.width, height: Metrics.Card.cornerRadius).fill()
        } else {
            let seam = mirrored && !isDetached ? stripRect.minX : stripRect.maxX - Metrics.Card.cornerRadius
            NSRect(x: seam, y: 0, width: Metrics.Card.cornerRadius, height: bounds.height).fill()
        }

        let stripInk = Palette.labelInk(color).withAlphaComponent(isDark ? 0.95 : 0.88)
        if horizontal && !isDetached {
            VerticalLabel.drawHorizontal(title, in: stripRect, inset: Metrics.Tab.labelInset,
                                         size: Metrics.Tab.labelSize, color: stripInk)
        } else {
            VerticalLabel.draw(title, in: stripRect, inset: Metrics.Tab.labelInset,
                               size: Metrics.Tab.labelSize, color: stripInk)
        }
    }

    override func layout() {
        super.layout()
        let pad = Metrics.Card.padding
        let horizontalStrip = bandRunsAlongTheTop
        let left = (horizontalStrip || (mirrored && !isDetached) ? 0 : Metrics.Card.labelStrip) + pad
        // On a bottom card the band is above the content, not below it.
        let above = horizontalStrip ? Metrics.Card.labelStrip : 0
        let contentWidth = bounds.width - left - trailingInset
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        let expand = Metrics.Card.titleSize * 1.15
        expandButton.frame = NSRect(x: bounds.width - trailingInset - expand,
                                    y: above + pad + 1, width: expand, height: expand)
        titleField.frame = NSRect(x: left - 3, y: above + pad,
                                  width: max(20, contentWidth - expand - 8), height: titleHeight)
        chrome.frame = NSRect(x: left, y: bounds.height - pad - NoteChromeBar.height,
                              width: contentWidth, height: NoteChromeBar.height)

        // The free corner: the one furthest from the screen edge the card is
        // pinned to.
        let grip: CGFloat = 16
        let gripX = (mirrored && !isDetached && !horizontal)
            ? bounds.width - grip - 2 : 2
        let gripY = horizontalStrip ? above + 2 : bounds.height - grip - 2
        resizeHandle.frame = NSRect(x: gripX, y: gripY, width: grip, height: grip)
        var top = above + pad + titleHeight + Metrics.Card.titleGap
        if isFinding {
            findBar.frame = NSRect(x: left, y: top, width: contentWidth, height: FindBar.height)
            top += FindBar.height + 6
        }
        scroll.frame = NSRect(x: left, y: top,
                              width: contentWidth,
                              height: max(0, bounds.height - top - pad - NoteChromeBar.height - 6))
        // Give the text view a real frame inside the clip view, and a container
        // as wide as it is.
        let content = scroll.contentSize
        textView.frame = NSRect(x: 0, y: 0, width: content.width,
                                height: max(content.height, textView.frame.height))
        textView.textContainer?.containerSize = NSSize(width: content.width,
                                                       height: .greatestFiniteMagnitude)
    }

    /// Clicking anywhere on the paper puts the caret in the note, the way a
    /// sticky note has no separate "text area".
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if stripRect.contains(point) {
            // Click puts the note away; drag pulls it off the deck. Which one it
            // was is only known on mouse-up.
            stripDragOrigin = NSEvent.mouseLocation
            return
        }
        window?.makeFirstResponder(textView)
        textView.onBeginEditing?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = stripDragOrigin else { return }
        let now = NSEvent.mouseLocation
        guard hypot(now.x - origin.x, now.y - origin.y) > 6 else { return }
        stripDragOrigin = nil
        onStripDrag?()
    }

    override func mouseUp(with event: NSEvent) {
        guard stripDragOrigin != nil else { return }
        stripDragOrigin = nil
        onClose?()
    }

    override func resetCursorRects() {
        addCursorRect(stripRect, cursor: isDetached ? .openHand : .pointingHand)
    }
}

extension NoteCardView: NSTextFieldDelegate {

    func controlTextDidEndEditing(_ notification: Notification) {
        commitTitle()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            commitTitle()
            window?.makeFirstResponder(self.textView)   // straight into the body
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            titleField.stringValue = title              // put it back
            window?.makeFirstResponder(self.textView)
            return true
        default:
            return false
        }
    }

    private func commitTitle() {
        let typed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != title else { return }
        title = typed
        onTitle?(typed)
    }
}

/// Reports the two moments the deck cares about: the caret arriving, and the
/// text changing.
final class NoteTextView: NSTextView {
    /// The rectangles a run of characters occupies, in view coordinates.
    ///
    /// TextKit 1, because that is what these views are: the highlighter needs
    /// `textStorage`, and touching it downgrades an NSTextView from TextKit 2.
    /// The first version of this handled only TextKit 2 and so drew nothing at
    /// all — the guard failed silently on every note.
    private func rects(for range: NSRange) -> [NSRect] {
        guard let manager = layoutManager, let container = textContainer else { return [] }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var boxes: [NSRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { box, _ in
            boxes.append(box.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
        }
        return boxes
    }

    /// How many stroke segments would be drawn. Diagnostic only.
    func markerSegmentCount() -> Int {
        guard let storage = textStorage else { return -1 }
        var count = 0
        storage.enumerateAttribute(MarkerStroke.attribute,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value is NSColor else { return }
            count += rects(for: range).count
        }
        return count
    }

    /// Marker strokes go behind the glyphs, so they are drawn before the text
    /// rather than as a background colour attribute — which would be a
    /// rectangle, and would look like a selection rather than a pen.
    ///
    /// Not `drawBackground(in:)`: these views have `drawsBackground = false` so
    /// the note's paper shows through, and AppKit never calls it.
    override func draw(_ dirtyRect: NSRect) {
        drawMarkerStrokes(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawMarkerStrokes(in rect: NSRect) {
        // Search results first, so a real highlight sits on top of one.
        for (index, match) in findMatches.enumerated() {
            let colour = findColour(index == currentMatch)
            for box in rects(for: match) where box.intersects(rect) && box.width > 1 {
                MarkerStroke.draw(in: box, colour: colour, seed: strokeSeed, index: 900 + index)
            }
        }

        guard let storage = textStorage else { return }
        var run = 0
        storage.enumerateAttribute(MarkerStroke.attribute,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let colour = value as? NSColor else { return }
            let index = run
            run += 1
            for box in rects(for: range) where box.intersects(rect) && box.width > 1 {
                MarkerStroke.draw(in: box, colour: colour, seed: strokeSeed, index: index)
            }
        }
    }

    var onChange: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onEscape: (() -> Void)?
    /// A `[[link]]` was followed.
    var onOpenLink: ((String) -> Void)?
    /// ⌘F, and ⌘G / ⇧⌘G once it is open.
    var onFind: (() -> Void)?
    var onStepFind: ((Int) -> Void)?
    /// Keeps a highlight's wobble the same on every redraw.
    var strokeSeed: String = ""

    /// Search results, kept beside the text rather than in it.
    ///
    /// Marking matches as attributes would edit the text storage, which would
    /// make every search look like a change and start the save timer. Nothing
    /// about finding should be able to touch the file.
    private(set) var findMatches: [NSRange] = []
    private(set) var currentMatch = 0
    var findColour: (Bool) -> NSColor = { _ in .systemBlue.withAlphaComponent(0.3) }

    @discardableResult
    func find(_ query: String) -> Int {
        let text = string as NSString
        findMatches = []
        currentMatch = 0
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { needsDisplay = true; return 0 }

        var from = 0
        while from < text.length {
            let found = text.range(of: needle, options: [.caseInsensitive],
                                   range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            findMatches.append(found)
            from = found.location + max(1, found.length)
        }
        needsDisplay = true
        return findMatches.count
    }

    /// Steps to the next or previous match, wrapping around.
    @discardableResult
    func stepMatch(_ delta: Int) -> Int {
        guard !findMatches.isEmpty else { return 0 }
        currentMatch = (currentMatch + delta + findMatches.count) % findMatches.count
        scrollRangeToVisible(findMatches[currentMatch])
        needsDisplay = true
        return currentMatch
    }

    func clearFind() {
        findMatches = []
        currentMatch = 0
        needsDisplay = true
    }


    /// Enter inside a list continues it, the way every editor worth using does.
    override func insertNewline(_ sender: Any?) {
        if MarkdownEditing.continueList(self) { return }
        super.insertNewline(sender)
    }

    /// Tab moves a list item in, Shift-Tab moves it back out, and anywhere else
    /// Tab is still Tab.
    override func insertTab(_ sender: Any?) {
        if MarkdownEditing.shiftIndent(self, by: 1) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if MarkdownEditing.shiftIndent(self, by: -1) { return }
        super.insertBacktab(sender)
    }

    /// Backspace at the start of an item gives up a level of indent, then the
    /// marker, before it starts eating the line above.
    override func deleteBackward(_ sender: Any?) {
        if MarkdownEditing.outdentOrUnmark(self) { return }
        super.deleteBackward(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)

        // ⌘-click follows a link, the way it already does for markdown ones.
        if event.modifierFlags.contains(.command),
           let link = Wikilink.link(in: string, at: index) {
            onOpenLink?(link.name)
            return
        }

        // A plain click on the `- [ ]` marker ticks it. Anywhere else on the
        // line still just places the caret.
        if let item = Checkbox.item(in: string, at: index),
           index <= item.box.upperBound,
           let flip = Checkbox.toggle(in: string, at: index) {
            if shouldChangeText(in: flip.range, replacementString: flip.replacement) {
                textStorage?.replaceCharacters(in: flip.range, with: flip.replacement)
                didChangeText()
            }
            return
        }

        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let characters = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = flags.contains(.shift)
        switch characters.lowercased() {
        case "b": MarkdownEditing.wrap(self, with: "**"); return true
        case "i": MarkdownEditing.wrap(self, with: "*"); return true
        case "k": MarkdownEditing.link(self); return true
        case "e": MarkdownEditing.code(self); return true
        case "l" where shift: MarkdownEditing.togglePrefix(self, "- "); return true
        case "t" where shift: MarkdownEditing.toggleTask(self); return true
        case "h" where shift: MarkdownEditing.wrap(self, with: "=="); return true
        case "f" where !shift: onFind?(); return true
        case "g": onStepFind?(shift ? -1 : 1); return true
        case "." where shift: MarkdownEditing.togglePrefix(self, "> "); return true
        case "1" where shift: MarkdownEditing.togglePrefix(self, "# "); return true
        case "2" where shift: MarkdownEditing.togglePrefix(self, "## "); return true
        case "3" where shift: MarkdownEditing.togglePrefix(self, "### "); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBeginEditing?() }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Takes new text from somewhere else showing the same note — the big
    /// editor, a floating copy — without disturbing whoever is typing.
    func syncBody(_ text: String) {
        guard string != text else { return }
        // Never pull text out from under a *live* caret — which means the key
        // window's first responder, not merely its own window's. Every window
        // keeps a first responder while it sits in the background, so the wider
        // test blocked the sync exactly when it was needed.
        let isBeingTypedIn = window?.isKeyWindow == true && window?.firstResponder === self
        guard !isBeingTypedIn else { return }
        let caret = selectedRange().location
        string = text
        setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        if let storage = textStorage, let highlighter = storage.delegate as? MarkdownHighlighter {
            highlighter.highlight(storage)
        }
    }
}
