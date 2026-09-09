import AppKit
import LedgeCore
import LedgeIndex
import LedgeStore

/// The deck's state machine.
///
/// Three states and one rule: **nothing takes focus until you click into a note
/// to write.** Hover, fan and preview all happen while the app you were typing
/// in stays key.
@MainActor
final class DeckController {

    enum State: Equatable {
        case rest
        case fanned
        case open(String)      // previewing — still no focus taken
        case editing(String)

        var noteID: String? {
            switch self {
            case .open(let id), .editing(let id): return id
            default: return nil
            }
        }
        var isFannedOrBeyond: Bool { self != .rest }
    }

    private(set) var state: State = .rest

    unowned let workspace: Workspace
    var strip: StripConfig {
        didSet {
            if strip.pinned && state == .rest { fanOut(takingFocus: false) }
            applyLayout(animated: false)
        }
    }

    private var store: NoteStore { workspace.store }
    private let panel = DeckPanel()
    private let root = DeckRootView()
    private let pill = PillView()
    private let plusButton = PlusButton()
    private let pinButton = PinButton()
    private var tabs: [NoteTabView] = []
    private var card: NoteCardView?

    private var records: [NoteRecord] = []
    private var bodies: [String: String] = [:]
    /// What the file said the last time this note's text and the file agreed.
    ///
    /// A save is not "put my copy on disk" any more. Something else may have
    /// written to the note since — and while it is open on screen is exactly
    /// when that is most likely — so the baseline is what makes the difference
    /// between my edits and theirs knowable. Without it, the only two options
    /// are overwriting them or overwriting you.
    private var baselines: [String: String] = [:]
    /// Shared across every strip: a note on the desk belongs to no edge.
    private var floating: [String: FloatingNote] {
        get { workspace.floating }
        set { workspace.floating = newValue }
    }
    private var editors: [String: NoteEditorWindow] {
        get { workspace.editors }
        set { workspace.editors = newValue }
    }

    private let focus = FocusReturn()

    private var dwell: Timer?
    private var grace: Timer?
    private var tabDwell: Timer?
    private var save: Timer?
    private var pendingSaveID: String?

    /// Keyboard navigation only exists when the deck was summoned by keyboard.
    /// Fanning by hover deliberately takes no focus, so there is no key window
    /// to route arrow keys through — that is the trade, not an oversight.
    private var keyboardDriven = false

    /// The fan animation belongs to the rest↔fanned transition alone. Replaying
    /// it whenever the pointer crosses a tab is what made the deck look broken.
    private var wasFanned = false
    private var _pendingCardSize: NSSize?

    init(workspace: Workspace, strip: StripConfig) {
        self.workspace = workspace
        self.strip = strip
        panel.contentView = root
        root.addSubview(pill)
        root.addSubview(plusButton)
        root.addSubview(pinButton)

        root.onPointerInside = { [weak self] point in self?.pointerInside(point) }
        root.onPointerOutside = { [weak self] in self?.pointerOutside() }
        plusButton.onClick = { [weak self] in self?.newNote() }
        pill.onClick = { [weak self] in self?.fanOut(takingFocus: false) }
        pinButton.onClick = { [weak self] in self?.togglePinned() }
        pinButton.onDrag = { [weak self] in self?.beginStripDrag() }

        NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    // MARK: - lifecycle

    func start() {
        Task {
            await seedIfNeeded()
            await refresh()
            if strip.pinned { fanOut(takingFocus: false) }
        }
        panel.orderFrontRegardless()
    }

    /// Shows you the movement once, rather than explaining it.
    ///
    /// A pinned strip is already fanned, so the thing worth demonstrating is a
    /// note coming out of its tab; an unpinned one fans and settles back.
    func demonstrate() async {
        guard !records.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(700))
        if state == .rest { fanOut(takingFocus: false) }
        try? await Task.sleep(for: .milliseconds(900))
        preview(records[0].id)
        try? await Task.sleep(for: .milliseconds(2200))
        closeNote()
        if !strip.pinned {
            try? await Task.sleep(for: .milliseconds(500))
            collapse()
        }
    }

    /// Gives a newly created strip something to hold.
    private func seedIfNeeded() async {
        guard !Settings.hasBeenSeeded(strip.id) else { return }
        Settings.markSeeded(strip.id)
        let existing = (try? await store.deck(strip: stripTag,
                                              collectingUnassigned: strip.isPrimary,
                                              knownStrips: knownStrips)) ?? []
        guard existing.isEmpty else { return }
        _ = try? await store.create(title: strip.isPrimary ? "Welcome" : strip.name,
                                    body: strip.isPrimary ? "" : "",
                                    strip: stripTag)
    }

    func refresh() async {
        records = (try? await store.deck(strip: strip.isPrimary ? "" : strip.id,
                                         collectingUnassigned: strip.isPrimary,
                                         knownStrips: knownStrips)) ?? []
        // A note edited outside Ledge should appear in whatever is showing it —
        // including while you are typing in it, which used to be the one case it
        // gave up on.
        if let open = state.noteID, let fresh = try? await store.load(id: open).body {
            adoptExternal(fresh, for: open)
        }
        if let open = state.noteID, let record = records.first(where: { $0.id == open }) {
            Settings.markSeen(open, at: record.updated)
        }
        rebuildTabs()
        pill.colors = records.map(\.color)
        applyLayout(animated: false)
        await prefetchBodies()
    }

    /// Bodies are read after the deck is already on screen, so opening the fan
    /// never waits on disk.
    private func prefetchBodies() async {
        for record in records where bodies[record.id] == nil {
            let loaded = (try? await store.load(id: record.id))?.body ?? ""
            bodies[record.id] = loaded
            baselines[record.id] = loaded
        }
    }

    private func rebuildTabs() {
        // Only a change in the shape of the deck justifies tearing views down.
        // A note whose text changed — which is what a feed does, over and over —
        // updates the tab it already has. Rebuilding under the pointer fires
        // mouseExited, and that is what used to collapse the deck mid-click.
        if tabs.count == records.count,
           zip(tabs, records).allSatisfy({ $0.record.id == $1.id }) {
            for (tab, record) in zip(tabs, records) {
                if tab.record != record { tab.record = record }
                tab.isFloating = floating[record.id] != nil
                tab.hasUnseen = Settings.hasUnseen(feed: record.feed, id: record.id,
                                                   updated: record.updated)
            }
            return
        }

        tabs.forEach { $0.removeFromSuperview() }
        tabs = records.map { record in
            let tab = NoteTabView(record: record)
            tab.onClick = { [weak self] in self?.tabClicked($0) }
            tab.onContextMenu = { [weak self] tab, event in self?.showTabMenu(tab, event) }
            tab.isFloating = floating[record.id] != nil
            tab.hasUnseen = Settings.hasUnseen(feed: record.feed, id: record.id,
                                               updated: record.updated)
            root.addSubview(tab, positioned: .below, relativeTo: plusButton)
            return tab
        }
        if let id = state.noteID, !records.contains(where: { $0.id == id }) {
            state = records.isEmpty ? .rest : .fanned
        }
    }

    /// Size and face changes take effect where you can see them, without
    /// closing whatever is open.
    private func settingsChanged() {
        let open = state.noteID
        if open != nil { tearDownCard() }
        applyLayout(animated: false)
        if let open { buildCard(for: open); applyLayout(animated: false) }
    }

    var notesFolder: URL { AppDelegate.notesFolder }

    /// The workspace swapped its store; nothing cached here still applies.
    func storeChanged() {
        bodies.removeAll()
        archivedCache.removeAll()
        tearDownCard()
        state = .rest
    }

    /// The strip's own rectangle on screen — the tabs and the pill, not the
    /// transparent panel around them. Dropping a floating note here docks it,
    /// which is what lets a note cross a wide display from one strip to another.
    var dockingRect: NSRect {
        panel.convertToScreen(root.convert(root.liveRegion, to: nil))
    }

    func redockAllOnThisStrip() {
        for id in floating.keys where records.contains(where: { $0.id == id }) { redock(id) }
    }

    func tearDown() {
        collapse()
        panel.orderOut(nil)
    }

    // MARK: - geometry

    private var screen: NSScreen? { strip.screen }
    private var mirrored: Bool { strip.edge.mirrored }
    private var horizontal: Bool { strip.edge.isHorizontal }

    /// Which way the deck folds away, in the root view's flipped coordinates.
    /// Every animation reads its direction from here, so a strip on any edge
    /// enters from that edge and nowhere else.
    private var hideDirection: CGVector {
        switch strip.edge {
        case .right:  return CGVector(dx: 1, dy: 0)
        case .left:   return CGVector(dx: -1, dy: 0)
        case .bottom: return CGVector(dx: 0, dy: 1)   // flipped: down is off-screen
        }
    }

    /// How far the strip can travel along its edge, in points either side of
    /// the middle. Mirrors the placement maths in `applyLayout`.
    private var positionTravel: CGFloat {
        let area = strip.placementFrame
        let panelSize = panel.frame.size
        let travel = horizontal
            ? (area.width - panelSize.width) / 2
            : (area.height - panelSize.height) / 2
        return max(1, travel)
    }

    /// Drag the pin and the whole strip slides along its edge — up and down on
    /// the sides, left and right along the bottom, which is how you park one to
    /// either side of the Dock by eye instead of by menu.
    private func beginStripDrag() {
        let startMouse = NSEvent.mouseLocation
        let startOffset = strip.offset
        let travel = positionTravel
        NSCursor.closedHand.push()

        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if event.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            let delta = horizontal
                ? (now.x - startMouse.x)
                : (startMouse.y - now.y)          // dragging down increases the offset
            var moved = strip
            moved.offset = min(0.5, max(-0.5, startOffset + Double(delta / (2 * travel))))
            strip = moved                          // relays out live
        }

        NSCursor.pop()
        // Only written once, at the end: every write rebuilds every deck.
        Settings.update(strip.id) { $0.offset = self.strip.offset }
    }

    /// Pinned strips stay fanned. The fold-away is the idea; on a wide display
    /// there is room to leave it out, and the fan is worth looking at.
    private func togglePinned() {
        Settings.update(strip.id) { $0.pinned.toggle() }
    }

    /// x of the deck's inner content, measured from whichever edge it is on.
    private func inset(_ width: CGFloat, _ elementWidth: CGFloat) -> CGFloat {
        mirrored ? 0 : width - elementWidth
    }

    /// The panel's size perpendicular to its edge.
    private func panelDepth(for state: State) -> CGFloat {
        switch state {
        case .rest:                    return Metrics.Pill.panelWidth
        case .fanned:                  return Metrics.Tab.panelWidth
        case .open, .editing:
            return (horizontal ? effectiveCardHeight : effectiveCardWidth) + Metrics.z(26)
        }
    }

    /// Each tab is as long as its own title needs. When the stack would outgrow
    /// the screen — big sizes, or simply a lot of notes — every tab shrinks by
    /// the same factor, so the proportions between them survive.
    private func tabHeights() -> [CGFloat] {
        guard !tabs.isEmpty else { return [] }
        let natural = tabs.map { NoteTabView.naturalHeight(for: $0.displayTitle) }
        let overlaps = tabs.enumerated().map { index, tab in
            index == 0 ? 0 : min(CGFloat(tab.jitter.tabOverlap), natural[index] * 0.2)
        }
        let total = natural.reduce(0, +) - overlaps.reduce(0, +)

        // The stack gets at most a bit over half the display; the rest is the
        // room a card needs to sit centred on the top or bottom tab.
        let area = strip.placementFrame
        let available = (horizontal ? area.width : area.height) * 0.55
            - Metrics.Plus.gap - Metrics.Plus.size * 2
        guard total > available, total > 0 else { return natural }
        let factor = available / total
        let floor = Metrics.Tab.width * 0.9
        return natural.map { max(floor, $0 * factor) }
    }

    /// A note is a sticky note. Past a certain width it stops being one, however
    /// far the size preference is turned up.
    private var effectiveCardWidth: CGFloat {
        // Never narrower than the controls need, whatever the size preference or
        // the screen says — a card whose buttons overlap is not smaller, it is
        // broken.
        let floor = card?.minimumWidth ?? Metrics.Card.minWidth
        let wanted = _pendingCardSize?.width ?? storedSize?.width ?? Metrics.Card.width
        // The screen has the last word. On a display too small to give the card
        // its natural width, the controls shrink to fit — a card wider than the
        // screen is not a bigger note, it is one you cannot read.
        let ceiling = (screen?.visibleFrame.width ?? 1440) * 0.42
        return min(max(floor, min(wanted, ceiling)), ceiling)
    }

    /// A size the note was dragged to, if it has one. Kept in the index, which
    /// is disposable — losing it on a rebuild costs nothing but the default.
    private var storedSize: NSSize? {
        guard let id = state.noteID,
              let record = records.first(where: { $0.id == id }),
              let width = record.width, let height = record.height else { return nil }
        return NSSize(width: width, height: height)
    }

    /// Never taller than the room left beside the stack. You cannot have both
    /// enormous tabs and an enormous note on one screen, and the note is the
    /// thing that yields.
    private var effectiveCardHeight: CGFloat {
        if let stored = _pendingCardSize?.height ?? storedSize?.height {
            return max(card?.minimumHeight ?? Metrics.Card.minHeight,
                       min(stored, strip.placementFrame.height - Metrics.panelPadding * 2))
        }
        let room = horizontal
            ? strip.placementFrame.height - Metrics.Tab.width - Metrics.panelPadding * 2
            : strip.placementFrame.height - stackContentHeight - Metrics.panelPadding * 2
        return max(Metrics.Card.minHeight, min(Metrics.Card.height, room))
    }

    private var tabStackHeight: CGFloat {
        let heights = tabHeights()
        guard !heights.isEmpty else { return 0 }
        var y: CGFloat = 0
        for (i, tab) in tabs.enumerated() {
            if i > 0 { y -= min(CGFloat(tab.jitter.tabOverlap), heights[i] * 0.2) }
            y += heights[i]
        }
        return y
    }

    private var stackContentHeight: CGFloat {
        tabStackHeight + Metrics.Plus.gap + Metrics.Plus.size
    }

    /// The panel keeps a card's worth of headroom around the tab stack, so a
    /// note opening off the top or bottom tab is never yanked back into frame.
    /// The extra is transparent and clicks fall straight through it.
    /// The panel's size along its edge.
    private func panelAlong(for state: State) -> CGFloat {
        let area = strip.placementFrame
        let limit = horizontal ? area.width : area.height
        switch state {
        case .rest:
            return PillView.length(for: records.count) + Metrics.panelPadding * 2
        case .fanned, .open, .editing:
            let cardAlong = horizontal ? effectiveCardWidth : effectiveCardHeight
            return min(stackContentHeight + cardAlong + Metrics.panelPadding * 2, limit)
        }
    }

    private func applyLayout(animated: Bool) {
        let depth = panelDepth(for: state)
        let along = panelAlong(for: state)
        let width = horizontal ? along : depth
        let height = horizontal ? depth : along

        // A bottom strip shares the Dock's band and would otherwise be covered.
        panel.level = horizontal ? DeckPanel.aboveDock : .floating

        let area = strip.placementFrame
        if horizontal {
            // Sits in the Dock's band, so it can be placed to either side of it.
            let travel = (area.width - width) / 2
            let x = area.midX - width / 2 + CGFloat(strip.offset) * 2 * travel
            panel.setFrame(NSRect(x: max(area.minX, min(x, area.maxX - width)),
                                  y: area.minY, width: width, height: height),
                           display: true)
        } else {
            let x = mirrored ? area.minX : area.maxX - width
            let travel = (area.height - height) / 2
            let y = area.midY - height / 2 - CGFloat(strip.offset) * 2 * travel
            panel.setFrame(NSRect(x: x, y: max(area.minY, min(y, area.maxY - height)),
                                  width: width, height: height),
                           display: true)
        }
        root.frame = NSRect(x: 0, y: 0, width: width, height: height)
        layoutSubviews(animated: animated)
    }

    private func layoutSubviews(animated: Bool) {
        let fanned = state.isFannedOrBeyond
        let bounds = root.bounds

        pill.mirrored = mirrored
        pill.horizontal = horizontal
        let pillLength = PillView.length(for: records.count)
        pill.frame = horizontal
            ? NSRect(x: (bounds.width - pillLength) / 2,
                     y: bounds.height - Metrics.Pill.visibleWidth,
                     width: pillLength, height: Metrics.Pill.visibleWidth)
            : NSRect(x: inset(bounds.width, Metrics.Pill.visibleWidth),
                     y: (bounds.height - pillLength) / 2,
                     width: Metrics.Pill.visibleWidth, height: pillLength)
        pill.alphaValue = fanned ? 0 : 1

        // The stack, laid along the edge, each tab as long as its own title.
        let heights = tabHeights()
        var along = fanned
            ? max(Metrics.panelPadding,
                  ((horizontal ? bounds.width : bounds.height) - stackContentHeight) / 2)
            : Metrics.panelPadding

        for (i, tab) in tabs.enumerated() {
            let length = i < heights.count ? heights[i] : Metrics.Tab.minHeight
            if i > 0 { along -= min(CGFloat(tab.jitter.tabOverlap), length * 0.2) }
            let poke = CGFloat(tab.jitter.tabProtrusion)
            let depth = Metrics.Tab.width + poke

            tab.mirrored = mirrored
            tab.horizontal = horizontal
            tab.frame = horizontal
                ? NSRect(x: along, y: bounds.height - depth, width: length, height: depth)
                : NSRect(x: inset(bounds.width, depth), y: along, width: depth, height: length)

            tab.applyLean()
            tab.isSelected = tab.record.id == state.noteID
            tab.isInteractive = fanned
            // The open note's tab is not drawn beside its card — the card is
            // that tab, extended.
            tab.isHidden = tab.record.id == state.noteID
            tab.isFloating = floating[tab.record.id] != nil
            along += length
        }

        // The two controls, after the last tab along the edge.
        let lastEnd = tabs.last.map { horizontal ? $0.frame.maxX : $0.frame.maxY }
            ?? Metrics.panelPadding
        let size = Metrics.Plus.size
        let controlDepth = inset(horizontal ? bounds.height : bounds.width, Metrics.Tab.width)
            + (mirrored && !horizontal ? Metrics.Tab.width - size - 1 : 1)

        plusButton.frame = horizontal
            ? NSRect(x: lastEnd + Metrics.Plus.gap, y: bounds.height - size - 2, width: size, height: size)
            : NSRect(x: controlDepth, y: lastEnd + Metrics.Plus.gap, width: size, height: size)
        pinButton.frame = horizontal
            ? plusButton.frame.offsetBy(dx: size + 5, dy: 0)
            : plusButton.frame.offsetBy(dx: 0, dy: size + 5)

        for control in [plusButton as NSView, pinButton] { control.alphaValue = fanned ? 1 : 0 }
        plusButton.isInteractive = fanned
        pinButton.isInteractive = fanned
        pinButton.isPinned = strip.pinned

        layoutCard()
        updateLiveRegion()

        let fanChanged = fanned != wasFanned
        wasFanned = fanned
        if fanChanged || !animated {
            animateTabs(fanningOut: fanned, animated: animated && fanChanged)
        }
    }

    private func layoutCard() {
        guard let card, let id = state.noteID,
              let tab = tabs.first(where: { $0.record.id == id }) else { return }
        let bounds = root.bounds
        card.mirrored = mirrored
        card.horizontal = horizontal

        let cardWidth = effectiveCardWidth
        let cardHeight = effectiveCardHeight

        if horizontal {
            // Grows upward out of its tab, flush with the bottom of the screen.
            var x = tab.frame.midX - cardWidth / 2 + CGFloat(card.jitter.cardOffsetX)
            x = min(x, bounds.width - cardWidth - Metrics.panelPadding)
            x = max(x, Metrics.panelPadding)
            card.frame = NSRect(x: x, y: bounds.height - cardHeight + Metrics.Card.overhang,
                                width: cardWidth, height: cardHeight)
        } else {
            let x = mirrored ? -Metrics.Card.overhang : bounds.width - cardWidth + Metrics.Card.overhang
            var y = tab.frame.midY - cardHeight / 2 + CGFloat(card.jitter.cardOffsetY)
            y = min(y, bounds.height - cardHeight - Metrics.panelPadding)
            y = max(y, Metrics.panelPadding)
            card.frame = NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
        }
        card.needsLayout = true
    }

    /// Only the pill, the tabs, the plus and any open card count as "inside".
    /// The rest of the panel is transparent and must not hold the deck open.
    private func updateLiveRegion() {
        // Only the strip actually occupied by the deck counts as inside — not
        // the full height of a panel that is mostly transparent headroom.
        var region: NSRect
        let bounds = root.bounds
        if state.isFannedOrBeyond {
            let start = (tabs.first.map { horizontal ? $0.frame.minX : $0.frame.minY } ?? 0) - 14
            let end = max(horizontal ? pinButton.frame.maxX : pinButton.frame.maxY,
                          tabs.last.map { horizontal ? $0.frame.maxX : $0.frame.maxY } ?? 0) + 14
            region = horizontal
                ? NSRect(x: start, y: bounds.height - Metrics.Tab.panelWidth,
                         width: end - start, height: Metrics.Tab.panelWidth)
                : NSRect(x: inset(bounds.width, Metrics.Tab.panelWidth), y: start,
                         width: Metrics.Tab.panelWidth, height: end - start)
        } else {
            region = horizontal
                ? NSRect(x: 0, y: bounds.height - Metrics.Pill.panelWidth,
                         width: bounds.width, height: Metrics.Pill.panelWidth)
                : NSRect(x: inset(bounds.width, Metrics.Pill.panelWidth), y: 0,
                         width: Metrics.Pill.panelWidth, height: bounds.height)
        }
        if let card { region = region.union(card.frame.insetBy(dx: -6, dy: -6)) }
        root.liveRegion = region
    }

    // MARK: - animation

    private func animateTabs(fanningOut: Bool, animated: Bool) {
        for (i, tab) in tabs.enumerated() {
            let travel = Metrics.Tab.width + 8
            let hidden = CGVector(dx: hideDirection.dx * travel, dy: hideDirection.dy * travel)
            let delay = animated ? Motion.stagger(i, of: tabs.count, fanningOut: fanningOut) : 0
            tab.slide(hiddenBy: hidden, alpha: fanningOut ? 1 : 0, animated: animated,
                      delay: delay, fanningOut: fanningOut)
        }
    }

    // MARK: - pointer

    private func pointerInside(_ point: NSPoint) {
        grace?.invalidate(); grace = nil

        if state.isFannedOrBeyond {
            if case .editing = state { return }
            // Which tab is under the pointer is decided here, from one tracking
            // area on the root, so relayout under a stationary pointer can never
            // strand the hover.
            if let tab = tabs.last(where: { $0.frame.insetBy(dx: 0, dy: -1).contains(point) }) {
                tabHovered(tab)
            }
            return
        }

        guard state == .rest, dwell == nil else { return }
        dwell = .scheduledTimer(withTimeInterval: Motion.hoverDwell, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dwell = nil
                self?.fanOut(takingFocus: false)
            }
        }
    }

    private func pointerOutside() {
        dwell?.invalidate(); dwell = nil
        tabDwell?.invalidate(); tabDwell = nil
        guard state.isFannedOrBeyond else { return }
        if case .editing = state { return }         // an open caret holds the deck
        grace?.invalidate()
        grace = .scheduledTimer(withTimeInterval: Motion.leaveGrace, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.grace = nil
                // Re-check: the caret may have landed in a note during the grace
                // period, and an open caret always holds the deck open.
                if case .editing = self.state { return }
                self.collapse()
            }
        }
    }

    private func tabHovered(_ tab: NoteTabView) {
        guard state.isFannedOrBeyond else { return }
        if case .editing = state { return }
        // A note that is out on the desk does not re-open on the edge.
        guard floating[tab.record.id] == nil else { return }
        guard state.noteID != tab.record.id else { return }
        tabDwell?.invalidate()
        tabDwell = .scheduledTimer(withTimeInterval: Motion.tabDwell, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.tabDwell = nil
                self?.preview(tab.record.id)
            }
        }
    }

    private func tabClicked(_ tab: NoteTabView) {
        if let float = floating[tab.record.id] {
            float.front()                      // bring the one on the desk forward
            return
        }
        beginEditing(tab.record.id)
    }

    /// Right-clicking a tab. Dragging a note across the screen already moves it
    /// between strips; this is the same thing for people who would never guess
    /// that, and the only place the gesture is named.
    private func showTabMenu(_ tab: NoteTabView, _ event: NSEvent) {
        cancelCollapse()
        let id = tab.record.id
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = id
        menu.addItem(open)

        let pull = NSMenuItem(title: "Pull off the deck", action: #selector(menuDetach(_:)), keyEquivalent: "")
        pull.target = self
        pull.representedObject = id
        menu.addItem(pull)

        let others = workspace.stripChoices.filter { $0.id != strip.id }
        if !others.isEmpty {
            menu.addItem(.separator())
            let parent = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for other in others {
                let item = NSMenuItem(title: "\(other.name) — \(other.subtitle)",
                                      action: #selector(menuMove(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["note": id, "strip": other.id]
                submenu.addItem(item)
            }
            let hint = NSMenuItem(title: "…or just drag it there", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            submenu.addItem(.separator())
            submenu.addItem(hint)
            parent.submenu = submenu
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        let archive = NSMenuItem(title: "Archive", action: #selector(menuArchive(_:)), keyEquivalent: "")
        archive.target = self
        archive.representedObject = id
        menu.addItem(archive)
        let delete = NSMenuItem(title: "Delete…", action: #selector(menuDelete(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = id
        menu.addItem(delete)

        NSMenu.popUpContextMenu(menu, with: event, for: tab)
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        beginEditing(id)
    }

    @objc private func menuDetach(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        preview(id)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.detach(id) } }
    }

    @objc private func menuMove(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["note"], let stripID = info["strip"],
              let target = workspace.stripChoices.first(where: { $0.id == stripID }) else { return }
        if state.noteID == id { closeNote() }
        // Same ordering as `redock`: land any pending edit before moving.
        let pending = pendingSaveID == id
        save?.invalidate(); save = nil; pendingSaveID = nil
        Task {
            if pending { await persist(id: id, naming: true) }
            workspace.move(note: id, to: target)
        }
    }

    @objc private func menuArchive(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        archive(id)
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        confirmDelete(id)
    }

    private func cancelCollapse() {
        grace?.invalidate(); grace = nil
        dwell?.invalidate(); dwell = nil
    }

    // MARK: - transitions

    func fanOut(takingFocus: Bool) {
        guard state == .rest else { return }
        keyboardDriven = takingFocus
        state = .fanned
        applyLayout(animated: true)
        if takingFocus {
            focus.capture()
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func collapse() { collapse(evenIfPinned: false) }

    func collapse(evenIfPinned: Bool) {
        guard state != .rest else { return }
        if strip.pinned && !evenIfPinned {
            // Fold the open note away, but leave the tabs out.
            if state.noteID != nil { closeNote() }
            return
        }
        commitPendingSave()
        endEditingIfNeeded()
        state = .rest
        keyboardDriven = false
        tearDownCard()
        applyLayout(animated: true)
    }

    private func preview(_ id: String) {
        guard state.isFannedOrBeyond, records.contains(where: { $0.id == id }) else { return }
        cancelCollapse()
        commitPendingSave()
        state = .open(id)
        if let record = records.first(where: { $0.id == id }) {
            Settings.markSeen(id, at: record.updated)
            tabs.first { $0.record.id == id }?.hasUnseen = false
        }
        buildCard(for: id)
        applyLayout(animated: true)
        if let card {
            // The note starts exactly covering its tab and grows away from the
            // same edge the tabs came from.
            let travel = (horizontal ? card.bounds.height : card.bounds.width)
                - Metrics.Tab.width - Metrics.Card.overhang
            card.slideIn(from: CGVector(dx: hideDirection.dx * travel,
                                        dy: hideDirection.dy * travel))
        }
    }

    /// The only place focus changes hands.
    func beginEditing(_ id: String) {
        cancelCollapse()
        if state.noteID != id { preview(id) }
        guard let card else { return }
        state = .editing(id)
        focus.capture()                       // while the other app is still front
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(card.textView)
        card.setEditing(true)
        tabs.forEach { $0.isSelected = $0.record.id == id }
    }

    private func endEditingIfNeeded() {
        guard case .editing = state else { return }
        panel.makeFirstResponder(nil)
        card?.setEditing(false)
        panel.resignKey()
        focus.restore()
    }

    private func buildCard(for id: String) {
        tearDownCard()
        guard let record = records.first(where: { $0.id == id }) else { return }
        let view = NoteCardView(record: record, body: bodies[id] ?? "")
        view.onEdit = { [weak self, weak view] text in
            self?.scheduleSave(id: id, body: text, from: view)
        }
        view.onBeginEditing = { [weak self] in self?.beginEditing(id) }
        view.textView.onEscape = { [weak self] in self?.dismiss() }
        view.textView.onOpenLink = { [weak self] name in self?.workspace.open(reference: name) }
        view.onClose = { [weak self] in self?.closeNote() }
        view.onTitle = { [weak self] title in self?.rename(id: id, to: title) }
        view.onExpand = { [weak self] in self?.expand(id) }
        view.resizeHandle.onResize = { [weak self] delta in self?.resizeCard(by: delta) }
        view.resizeHandle.onFinished = { [weak self] in self?.commitCardSize(id) }
        view.onColor = { [weak self] color in self?.recolor(id, to: color) }
        view.onArchive = { [weak self] in self?.archive(id) }
        view.onDelete = { [weak self] in self?.confirmDelete(id) }
        view.onStripDrag = { [weak self] in
            // Let the originating mouseDragged return before the card that sent
            // it is removed and a nested drag loop starts.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.detach(id) } }
        }
        root.addSubview(view, positioned: .below, relativeTo: nil)
        card = view
    }

    private func tearDownCard() {
        card?.removeFromSuperview()
        card = nil
    }

    /// Puts the note away but leaves the deck fanned — the tabs stay on the
    /// edge, ready for the next one. This is the common exit; collapsing all the
    /// way to a stripe is the second press.
    func closeNote() {
        guard state.noteID != nil else { return }
        commitPendingSave()
        endEditingIfNeeded()
        state = .fanned
        tearDownCard()
        applyLayout(animated: true)
    }

    /// Escape, twice: the first press folds the note back into its tab, the
    /// second sends the whole deck back to a stripe.
    func dismiss() {
        if state.noteID != nil {
            closeNote()
        } else {
            collapse()
        }
    }

    // MARK: - editing

    fileprivate func scheduleSave(id: String, body: String, from source: AnyObject? = nil) {
        bodies[id] = body
        propagate(body: body, of: id, from: source)
        // A save already pending for a *different* note must land, not be
        // dropped because a second note started typing.
        if let other = pendingSaveID, other != id {
            save?.invalidate(); save = nil
            Task { await persist(id: other, naming: true) }
        }
        pendingSaveID = id
        save?.invalidate()
        save = .scheduledTimer(withTimeInterval: 0.250, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.save = nil
                self?.pendingSaveID = nil
                await self?.persist(id: id)
            }
        }
    }

    /// One note can be on screen three times at once — as a tab's card, as a
    /// floating copy, and in the editor. They all have to agree as you type, or
    /// the stale one silently overwrites the fresh one the moment you touch it.
    /// Takes a change that arrived from outside into the note on screen.
    ///
    /// Merged rather than assigned: you may have typed since, and the whole
    /// point of the exercise is that neither writer has to lose.
    private func adoptExternal(_ fresh: String, for id: String) {
        let mine = bodies[id] ?? fresh
        guard fresh != mine else {
            baselines[id] = fresh
            return
        }
        let merged = Merge.lines(base: baselines[id] ?? mine, mine: mine, theirs: fresh)
        bodies[id] = merged.text
        baselines[id] = fresh
        propagate(merged: merged, from: mine, of: id)

        // The merged text is not on disk yet when both sides had changed.
        if merged.text != fresh { scheduleSave(id: id, body: merged.text) }
    }

    /// Like `propagate`, but the views are told where the caret should end up,
    /// so lines arriving above it do not drag it through your own sentence.
    private func propagate(merged: Merge.Result, from mine: String, of id: String) {
        if let card, card.record.id == id { card.textView.syncBody(merged, from: mine) }
        if let float = floating[id] { float.cardView.textView.syncBody(merged, from: mine) }
        if let editor = editors[id] { editor.textView.syncBody(merged, from: mine) }
    }

    private func propagate(body: String, of id: String, from source: AnyObject?) {
        if let card, card.record.id == id, card !== source {
            card.textView.syncBody(body)
        }
        if let float = floating[id], float.cardView !== source {
            float.cardView.textView.syncBody(body)
        }
        if let editor = editors[id], editor !== source {
            editor.syncBody(body)
        }
    }

    func commitPendingSave() {
        guard save != nil, let id = pendingSaveID else { return }
        save?.invalidate(); save = nil
        pendingSaveID = nil
        Task { await persist(id: id, naming: true) }
    }

    /// `naming` gives an untitled note its title from its first line, but only
    /// on commit — doing it per keystroke would rename the file as you type.
    private func persist(id: String, naming: Bool = false) async {
        guard let body = bodies[id] else { return }
        do {
            var note = try await store.load(id: id)

            // Merge rather than overwrite. `note.body` is what the file says
            // right now, which is not necessarily what it said when this note
            // was opened.
            let merged = Merge.lines(base: baselines[id] ?? note.body,
                                     mine: body, theirs: note.body)
            note.body = merged.text
            if merged.text != body {
                bodies[id] = merged.text
                propagate(merged: merged, from: body, of: id)
            }
            baselines[id] = merged.text
            if naming, note.title.isEmpty {
                let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
                note.title = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
            }
            _ = try await store.save(note)
            records = (try? await store.deck(strip: strip.isPrimary ? "" : strip.id,
                                             collectingUnassigned: strip.isPrimary,
                                             knownStrips: knownStrips)) ?? records
        } catch {}
    }

    /// Brings a note to the front of whatever strip it lives on, opened and
    /// ready to write in. What a followed link lands on.
    func reveal(id: String) async {
        await refresh()
        guard records.contains(where: { $0.id == id }) else { return }
        if let float = floating[id] { float.front(); return }
        if state == .rest { fanOut(takingFocus: true) }
        preview(id)
        beginEditing(id)
    }

    /// Renaming a note renames its file. Identity lives in the frontmatter, so
    /// the note survives it — see `Frontmatter`.
    private func rename(id: String, to title: String) {
        Task {
            guard var note = try? await store.load(id: id) else { return }
            note.title = title
            _ = try? await store.save(note)
            records = (try? await store.deck(strip: strip.isPrimary ? "" : strip.id,
                                             collectingUnassigned: strip.isPrimary,
                                             knownStrips: knownStrips)) ?? records
            // Refresh the tab under the card without tearing the card down.
            if let index = records.firstIndex(where: { $0.id == id }),
               let tab = tabs.first(where: { $0.record.id == id }) {
                _ = index
                tab.overrideTitle = title
            }
            card?.title = title
        }
    }

    // MARK: - pulling a note off the deck

    /// Peels the note off the edge into its own floating window, starting a drag
    /// so it comes away under the pointer. Its tab stays in the deck, dimmed.
    fileprivate func detach(_ id: String) {
        guard floating[id] == nil,
              let card, let record = records.first(where: { $0.id == id }) else { return }

        var onScreen = panel.convertToScreen(root.convert(card.frame, to: nil))
        // A card that was fine against an edge may be too narrow once it grows
        // its own band on the desk.
        card.setDetached(true)
        onScreen.size.width = max(onScreen.width, card.minimumWidth)
        onScreen.size.height = max(onScreen.height, card.minimumHeight)
        let title = card.title
        let body = card.textView.string
        bodies[id] = body

        closeNote()

        let float = FloatingNote(record: record, title: title, body: body, size: onScreen.size)
        float.onEdit = { [weak self, weak float] text in
            self?.scheduleSave(id: id, body: text, from: float?.cardView)
        }
        float.onTitle = { [weak self] text in self?.rename(id: id, to: text) }
        float.onExpand = { [weak self] in self?.expand(id) }
        float.onRedock = { [weak self] in self?.redock(id) }
        float.onResized = { [weak self] size in
            Task { try? await self?.store.setGeometry(id: id, width: size.width, height: size.height) }
        }
        float.shouldRedock = { [weak self] pointer in self?.workspace.strip(near: pointer) != nil }
        float.onColor = { [weak self] color in self?.recolor(id, to: color) }
        float.onArchive = { [weak self] in self?.redock(id); self?.archive(id) }
        float.onDelete = { [weak self] in self?.confirmDelete(id) }
        floating[id] = float
        float.show(at: onScreen.origin)
        tabs.first { $0.record.id == id }?.isFloating = true

        NSApp.activate()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { float.trackDrag() }
        }
    }

    /// Pushed back to an edge. If that edge belongs to another strip, the note
    /// moves there — its tab lights up on the strip it was dropped on, not the
    /// one it came from.
    private func redock(_ id: String) {
        guard let float = floating[id] else { return }
        let target = workspace.strip(near: float.dropPoint)
        floating.removeValue(forKey: id)

        bodies[id] = float.body
        float.close()
        tabs.first { $0.record.id == id }?.isFloating = false

        // The body save and the strip move both read the note, change one field
        // and write it back. Run concurrently they race, and the loser's change
        // is silently overwritten — which showed up as a note that refused to
        // move. So: save, *then* move, in that order, awaited.
        save?.invalidate(); save = nil; pendingSaveID = nil

        Task {
            await persist(id: id, naming: true)
            if let target, target.id != strip.id {
                _ = try? await store.move(id: id, toStrip: target.isPrimary ? "" : target.id)
            }
            await workspace.refreshAll()
        }
    }

    /// The same note with room to think in.
    func expand(_ id: String) {
        if let existing = editors[id], existing.isVisible { existing.show(); return }
        guard let record = records.first(where: { $0.id == id }) ?? archivedCache[id] else { return }
        let title = floating[id] != nil ? record.displayTitle : (card?.title ?? record.displayTitle)
        let editor = NoteEditorWindow(record: record, title: title, body: bodies[id] ?? "")
        editor.onEdit = { [weak self, weak editor] text in
            self?.scheduleSave(id: id, body: text, from: editor)
        }
        editor.onTitle = { [weak self] text in self?.rename(id: id, to: text) }
        editor.onOpenLink = { [weak self] name in self?.workspace.open(reference: name) }
        editor.onClose = { [weak self] in
            self?.editors[id] = nil
            self?.commitPendingSave()
            Task { await self?.refresh() }
        }
        editors[id] = editor
        editor.show()
    }

    func expandFromAnywhere(_ id: String) async {
        expandFromLibrary(id)
    }

    private func expandFromLibrary(_ id: String) {
        Task {
            if bodies[id] == nil {
                let loaded = (try? await store.load(id: id))?.body ?? ""
                bodies[id] = loaded
                baselines[id] = loaded
            }
            if records.first(where: { $0.id == id }) == nil,
               let all = try? await store.records(.all),
               let record = all.first(where: { $0.id == id }) {
                archivedCache[id] = record
            }
            expand(id)
        }
    }

    func expandCurrent() {
        if let id = state.noteID { expand(id) }
    }

    /// A note opened from the library may be archived, and so absent from the
    /// deck's own records.
    private var archivedCache: [String: NoteRecord] = [:]

    /// A new note is born on the strip that made it.
    private var stripTag: String { strip.isPrimary ? "" : strip.id }

    /// Growing a card always means growing it *inward*, away from the edge it
    /// is pinned to — the only direction it has.
    private func resizeCard(by delta: CGSize) {
        guard let card else { return }
        let inward: CGFloat
        var width = card.frame.width
        var height = card.frame.height

        switch strip.edge {
        case .right:  inward = -delta.width;  width += inward; height += -delta.height
        case .left:   inward = delta.width;   width += inward; height += -delta.height
        case .bottom: inward = -delta.height; height += inward; width += delta.width
        }

        width = max(card.minimumWidth, min(width, Metrics.Card.maxWidth))
        height = max(card.minimumHeight, min(height, Metrics.Card.maxHeight))
        pendingCardSize = NSSize(width: width, height: height)
        layoutCard()
    }

    private var pendingCardSize: NSSize? {
        get { _pendingCardSize }
        set { _pendingCardSize = newValue }
    }

    private func commitCardSize(_ id: String) {
        guard let size = pendingCardSize else { return }
        pendingCardSize = nil
        Task {
            try? await store.setGeometry(id: id, width: size.width, height: size.height)
            records = (try? await store.deck(strip: stripTag,
                                             collectingUnassigned: strip.isPrimary,
                                             knownStrips: knownStrips)) ?? records
        }
    }

    /// Repaints everything showing this note straight away, then writes it.
    /// Rebuilding the card instead made the new colour arrive only after you
    /// closed the note and opened it again.
    private func recolor(_ id: String, to color: NoteColor) {
        if let card, card.record.id == id { card.color = color }
        floating[id]?.setColor(color)
        editors[id]?.setColor(color)
        tabs.first { $0.record.id == id }?.overrideColor = color
        pill.colors = records.map { $0.id == id ? color : $0.color }

        Task {
            guard var note = try? await store.load(id: id) else { return }
            note.color = color
            _ = try? await store.save(note, touch: false)
            await workspace.refreshAll()
        }
    }

    /// Archiving is reversible and quiet; deleting is neither, so it asks.
    private func confirmDelete(_ id: String) {
        let title = records.first { $0.id == id }?.displayTitle ?? "this note"
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "The .md file is removed from your notes folder. Archiving keeps it, off the deck but still searchable."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Archive instead")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                if let float = floating.removeValue(forKey: id) { float.close() }
                editors[id]?.close()
                closeNote()
                try? await store.delete(id: id)
                await refresh()
                if records.isEmpty { collapse() }
            }
        case .alertSecondButtonReturn:
            archive(id)
        default:
            break
        }
    }

    func newNote(title: String = "", body: String = "", color: NoteColor? = nil) {
        Task {
            guard let note = try? await store.create(title: title, color: color,
                                                     body: body, strip: stripTag) else { return }
            bodies[note.id] = body
            await refresh()
            if state == .rest { fanOut(takingFocus: true) }
            preview(note.id)
            beginEditing(note.id)
        }
    }

    // MARK: - inspection

    var panelFrame: NSRect { panel.frame }
    var pillFrame: NSRect { pill.frame }
    var tabFrames: [NSRect] { tabs.map(\.frame) }
    var tabRotations: [Double] { tabs.map(\.jitter.tabRotation) }
    var tabAlphas: [Double] { tabs.map { Double($0.layer?.opacity ?? 0) } }
    var plusFrame: NSRect { plusButton.frame }
    var cardFrame: NSRect? { card?.frame }
    var cardRotationDegrees: Double { card.map { $0.jitter.cardRotation(focused: $0.isEditing) } ?? 0 }
    var liveRegionRect: NSRect { root.liveRegion }
    /// Every strip that exists right now. The primary deck needs it to know
    /// which notes are strays.
    private var knownStrips: Set<String> { Set(Settings.strips.map(\.id)) }

    var openNoteID: String? { state.noteID }

    /// One-based, because the keys are ⌘1 to ⌘9.
    func openNote(at position: Int) {
        guard position >= 1, position <= records.count else { return }
        if state == .rest { fanOut(takingFocus: true) }
        preview(records[position - 1].id)
        beginEditing(records[position - 1].id)
    }

    var recordsForTesting: [NoteRecord] { records }
    /// The tab views themselves, so a check can ask whether they are the same
    /// objects after a refresh or fresh ones.
    var tabsForTesting: [NoteTabView] { tabs }

    /// What the folder watcher does when a file changes underneath the app,
    /// so a check can write a file the way an agent would and see the deck
    /// react the way it will in the real thing.
    func reconcileForTesting(_ filenames: [String]) async {
        _ = try? await store.reconcile(filenames: filenames)
        await refresh()
    }
    func previewForTesting(_ id: String) { preview(id) }

    // MARK: - keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        // While the caret is in a note, the keyboard belongs to the note.
        // Swallowing Return here is what stopped Enter making a new line.
        if case .editing = state {
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                expandCurrent(); return true                    // cmd-return
            }
            guard event.keyCode == 53 else { return false }     // esc
            dismiss()
            return true
        }
        if event.keyCode == 36, event.modifierFlags.contains(.command), state.noteID != nil {
            expandCurrent(); return true
        }
        guard keyboardDriven || state.noteID != nil else { return false }
        switch event.keyCode {
        case 53:                                  // esc
            dismiss(); return true
        case 126:                                 // up
            step(-1); return true
        case 125:                                 // down
            step(1); return true
        case 36:                                  // return
            if let id = state.noteID { beginEditing(id) }
            return true
        case 51 where event.modifierFlags.contains(.command):   // cmd-delete
            if let id = state.noteID { archive(id) }
            return true
        default:
            return false
        }
    }

    private func step(_ delta: Int) {
        guard !records.isEmpty else { return }
        let current = state.noteID.flatMap { id in records.firstIndex { $0.id == id } }
        let next = ((current ?? -1) + delta + records.count) % records.count
        preview(records[next].id)
    }

    func archive(_ id: String) {
        Task {
            _ = try? await store.archive(id: id)
            await refresh()
            if records.isEmpty { collapse() } else { closeNote(); applyLayout(animated: true) }
        }
    }
}

// MARK: - self test hooks

extension DeckController {

    struct Geometry {
        var state: String
        var panel: NSRect
        var pill: NSRect
        var tabs: [NSRect]
        var rotations: [Double]
        var tabAlpha: [Double]
        var plus: NSRect
        var card: NSRect?
        var cardRotation: Double
        var liveRegion: NSRect
        var hiddenTabs: Int
        var otherTabsVisible: Bool
        var chromeAlpha: Double
    }

    func debugGeometry() -> Geometry {
        Geometry(
            state: {
                switch state {
                case .rest: return "rest"
                case .fanned: return "fanned"
                case .open(let id): return "open(\(id))"
                case .editing(let id): return "editing(\(id))"
                }
            }(),
            panel: panelFrame,
            pill: pillFrame,
            tabs: tabFrames,
            rotations: tabRotations,
            tabAlpha: tabAlphas,
            plus: plusFrame,
            card: cardFrame,
            cardRotation: cardRotationDegrees,
            liveRegion: liveRegionRect,
            hiddenTabs: tabs.filter(\.isHidden).count,
            otherTabsVisible: tabs.filter { !$0.isHidden }.allSatisfy { ($0.layer?.opacity ?? 0) > 0.9 },
            chromeAlpha: card?.chromeAlpha ?? 0
        )
    }

    /// Drives the same debounced save the editor and the cards use.
    func debugEdit(id: String, body: String) {
        scheduleSave(id: id, body: body)
    }

    func debugCommit() { commitPendingSave() }

    func debugTitles() -> [String] { tabs.map(\.displayTitle) }

    func debugHideDirection() -> CGVector { hideDirection }

    /// The real editor window for a note, as `expand` created it.
    func debugEditor(_ id: String) -> NoteEditorWindow? { editors[id] }

    func debugCardBody() -> String? { card?.textView.string }

    func debugCardMinimumWidth() -> CGFloat? { card?.minimumWidth }

    func debugChromeOverlaps() -> Bool? { card?.chromeOverlaps }

    /// Ink and paper as painted, optionally after being forced into the other
    /// appearance — which is what caught the invisible text.
    func debugInkOnPaper(forcing appearance: NSAppearance?) -> (text: NSColor, paper: NSColor)? {
        guard let card else { return nil }
        if let appearance { card.adopt(appearance: appearance) }
        card.repaintAsTypingWould()
        return card.paintedTextAndPaper
    }

    func debugRecolor(_ id: String, to color: NoteColor) { recolor(id, to: color) }

    func debugOpenNoteID() -> String? { state.noteID }

    /// What the open card is *actually* painted, straight off its layer, and
    /// which colour its tab believes it is. Deliberately not recomputed from the
    /// palette: a check that derives the expected value the same way the drawing
    /// does proves nothing.
    func debugPaintedColors() -> (card: NSColor?, tabColor: NoteColor?)? {
        guard let card, let id = state.noteID else { return nil }
        let painted = card.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
        return (painted, tabs.first { $0.record.id == id }?.displayColor)
    }

    /// What the open card needs docked, and what the same card would need once
    /// pulled off onto the desk.
    func debugDetachedWidths() -> (docked: CGFloat, detached: CGFloat, detachedGrowsBand: Bool)? {
        guard let card else { return nil }
        let docked = card.minimumWidth
        card.setDetached(true)
        let detached = card.minimumWidth
        let grows = !card.bandRunsAlongTheTop
        card.setDetached(false)
        return (docked, detached, grows)
    }

    /// Types into the deck's card exactly as a person would.
    func debugTypeIntoCard(_ text: String) {
        guard let card else { return }
        card.window?.makeFirstResponder(card.textView)
        card.textView.setSelectedRange(NSRange(location: (card.textView.string as NSString).length,
                                               length: 0))
        card.textView.insertText(text, replacementRange: card.textView.selectedRange())
    }

    /// The card's coloured band, in the card's own coordinates.
    func debugCardStripRect() -> (strip: NSRect, card: NSRect)? {
        guard let card else { return nil }
        return (card.stripRect, card.bounds)
    }

    /// Drives the same save-then-move ordering the drag and the menu use.
    func debugMoveWithPendingEdit(id: String, to target: StripConfig) {
        let pending = pendingSaveID == id
        save?.invalidate(); save = nil; pendingSaveID = nil
        Task {
            if pending { await persist(id: id, naming: true) }
            workspace.move(note: id, to: target)
        }
    }

    /// Where a tab actually sits, on screen, while the deck is folded away.
    func debugHiddenTabCentre() -> NSPoint? {
        guard let tab = tabs.first, let layer = tab.layer else { return nil }
        let t = layer.transform
        return NSPoint(x: tab.frame.midX + t.m41, y: tab.frame.midY + t.m42)
    }

    func debugLabelBoxes() -> [(box: NSRect, bounds: NSRect)] {
        tabs.map { (box: $0.labelBox, bounds: $0.bounds) }
    }

    func debugPreviewLast() {
        guard let last = recordsForTesting.last else { return }
        previewForTesting(last.id)
    }

    func debugPreviewFirst() {
        guard let first = recordsForTesting.first else { return }
        previewForTesting(first.id)
    }

    func debugBeginEditingFirst() {
        guard let first = recordsForTesting.first else { return }
        beginEditing(first.id)
    }
}
