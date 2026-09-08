import AppKit
import LedgeCore
import LedgeIndex
import LedgeStore

/// Everything the strips share: the store, the notes currently floating on the
/// desk, the open editors, and the library window.
///
/// A strip owns only its own edge. Anything that spans them lives here.
extension NSRect {
    /// Zero when the rectangles touch, otherwise the gap between them.
    func ledgeDistance(to other: NSRect) -> CGFloat {
        let dx = max(0, max(other.minX - maxX, minX - other.maxX))
        let dy = max(0, max(other.minY - maxY, minY - other.maxY))
        return hypot(dx, dy)
    }
}

@MainActor
final class Workspace {

    private(set) var store: NoteStore
    private(set) var decks: [DeckController] = []

    var floating: [String: FloatingNote] = [:]
    var editors: [String: NoteEditorWindow] = [:]
    private var library: AllNotesWindow?

    init(store: NoteStore) {
        self.store = store
        NotificationCenter.default.addObserver(
            forName: Settings.stripsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildDecks() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildDecks() }
        }
    }

    func start() {
        rebuildDecks()
    }

    /// A strip whose display has been unplugged is not shown — but it is not
    /// forgotten either, and comes back when the screen does.
    func rebuildDecks() {
        let wanted = Settings.strips.filter { $0.screenIsPresent }
        for deck in decks where !wanted.contains(where: { $0.id == deck.strip.id }) {
            deck.tearDown()
        }
        var rebuilt: [DeckController] = []
        for config in wanted {
            if let existing = decks.first(where: { $0.strip.id == config.id }) {
                existing.strip = config   // relays out, and re-fans if newly pinned
                rebuilt.append(existing)
            } else {
                let deck = DeckController(workspace: self, strip: config)
                deck.start()
                rebuilt.append(deck)
            }
        }
        decks = rebuilt
        Task {
            // A strip that has been removed must not take its notes with it.
            let known = Set(Settings.strips.map(\.id))
            _ = try? await store.reassignOrphans(knownStrips: known)
            await refreshAll()
        }
    }

    func refreshAll() async {
        for deck in decks { await deck.refresh() }
    }

    func deck(for stripID: String) -> DeckController? {
        decks.first { $0.strip.id == stripID } ?? decks.first
    }

    var primaryDeck: DeckController? {
        decks.first { $0.strip.isPrimary } ?? decks.first
    }

    /// Which strip a floating note is being pushed towards, if any. This is what
    /// lets you drag a note from one edge of a 49-inch display to the other.
    /// Which strip a note dropped *here* belongs to.
    ///
    /// Measured from the pointer against each strip's actual rectangle. Two
    /// earlier versions of this were wrong in instructive ways: one measured
    /// every strip as if it were on a side edge, so a bottom strip could never
    /// be hit at all; the next measured the note's own rectangle, and since a
    /// card is 300 pt wide it kept overlapping the strip it came from and
    /// snapping back there. You aim with the pointer.
    func strip(near pointer: NSPoint) -> StripConfig? {
        var best: (config: StripConfig, distance: CGFloat)?
        for deck in decks {
            let distance = NSRect(origin: pointer, size: .zero)
                .ledgeDistance(to: deck.dockingRect)
            guard distance < FloatingNote.snapDistance else { continue }
            if best == nil || distance < best!.distance { best = (deck.strip, distance) }
        }
        return best?.config
    }

    /// Every strip a note could be sent to, for the menus.
    var stripChoices: [StripConfig] { decks.map(\.strip) }

    func move(note id: String, to strip: StripConfig) {
        Task {
            _ = try? await store.move(id: id, toStrip: strip.isPrimary ? "" : strip.id)
            await refreshAll()
        }
    }

    // MARK: - shared windows

    func showLibrary(filter: NoteIndex.Filter, query: String? = nil) {
        if let library, library.isVisible { library.show(filter: filter, query: query); return }
        let window = AllNotesWindow(store: store)
        window.onOpenInEditor = { [weak self] id in self?.openEditor(id) }
        window.onChanged = { [weak self] in Task { await self?.refreshAll() } }
        library = window
        window.show(filter: filter, query: query)
    }

    func openEditor(_ id: String) {
        Task {
            guard let deck = primaryDeck else { return }
            await deck.expandFromAnywhere(id)
        }
    }

    // MARK: - moving the notes folder

    /// Points Ledge at a different folder, optionally taking the notes along.
    ///
    /// The index is not moved: it is derived, and rebuilds from whatever is in
    /// the new folder. Everything on screen is closed first, because a floating
    /// note whose store has been swapped underneath it belongs to nothing.
    func relocate(to folder: URL, movingNotes: Bool) async throws {
        for editor in editors.values { editor.close() }
        editors.removeAll()
        for float in floating.values { float.close() }
        floating.removeAll()
        for deck in decks { deck.collapse() }

        if movingNotes {
            let source = await store.folder
            if source != folder {
                try NoteStore.relocateNotes(from: source, to: folder)
            }
        }

        Settings.setNotesFolder(folder)
        store = try NoteStore(folder: folder)
        _ = try? await store.scan()
        for deck in decks { deck.storeChanged() }
        rebuildDecks()
    }

    var hasFloatingNotes: Bool { !floating.isEmpty }

    func redockAll() {
        for deck in decks { deck.redockAllOnThisStrip() }
    }

    func newNote() {
        (primaryDeck ?? decks.first)?.newNote()
    }

    /// A note from whatever is on the clipboard.
    ///
    /// The cheap half of capture-first: no Accessibility permission, no reading
    /// anyone's selection — you copy, you press, it is a note.
    func newNoteFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        (primaryDeck ?? decks.first)?.newNote(body: text)
    }

    /// Opens the note a `[[link]]` or a `ledge://` URL points at, creating it if
    /// nothing matches — an unresolved link you can click into existence is what
    /// makes linking worth doing.
    func open(reference: String, creatingIfMissing: Bool = true) {
        Task {
            if let found = try? await store.find(reference: reference) {
                await deck(for: found.strip.isEmpty ? StripConfig.primaryID : found.strip)?
                    .reveal(id: found.id)
                return
            }
            guard creatingIfMissing else { NSSound.beep(); return }
            (primaryDeck ?? decks.first)?.newNote(title: reference)
        }
    }

    func handle(_ command: LedgeURL.Command) {
        switch command {
        case .new(let title, let text, let color, let strip):
            let target = strip.flatMap { name in decks.first { $0.strip.id == name || $0.strip.name == name } }
            (target ?? primaryDeck ?? decks.first)?
                .newNote(title: title ?? "", body: text ?? "", color: color)
        case .open(let reference):
            open(reference: reference)
        case .search(let query):
            showLibrary(filter: .all, query: query)
        }
    }
}
