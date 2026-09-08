import AppKit
import LedgeCore
import LedgeStore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: NoteStore?
    private var workspace: Workspace?
    private var watcher: FolderWatcher?
    private let hotkeys = Hotkeys()
    private var statusItem: StatusItemController?
    private var keyMonitor: Any?

    /// A scratch folder the self test owns, so it never writes into anyone's
    /// real notes and always starts from the same fixtures.
    private static let selfTestFolder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ledge-selftest")

    static var notesFolder: URL {
        if let override = ProcessInfo.processInfo.environment["LEDGE_FOLDER"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if CommandLine.arguments.contains("--selftest") { return selfTestFolder }
        if let chosen = Settings.notesFolderOverride { return chosen }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ledge")
    }

    /// Titles of deliberately different lengths: several checks are about a tab
    /// being as long as its own title needs.
    private static func writeSelfTestFixtures() {
        let folder = notesFolder
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let fixtures: [(String, NoteColor, String, String)] = [
            ("Office", .blue, "a0", "- understand all the apis listed"),
            ("Groceries", .green, "a1", "- apple\n- 4x banana\n- peanuts"),
            ("Hold", .lavender, "a2", "- work on the clamshell"),
            ("Side-projects", .butter, "a3", "- learn about the deck"),
            ("Reading list", .coral, "a4", "```swift\nlet answer = 42\n```"),
        ]
        for (title, color, rank, body) in fixtures {
            var note = Note(title: title, color: color, rank: rank)
            note.body = body
            try? Data(Frontmatter.serialize(note).utf8)
                .write(to: folder.appendingPathComponent("\(title).md"))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        MainMenu.install()                      // …but ⌘C still has to mean copy

        if CommandLine.arguments.contains("--selftest") {
            AppDelegate.writeSelfTestFixtures()
            // and never inherit whatever layout this machine happens to have
            UserDefaults.standard.removePersistentDomain(forName: "com.lisandro.Ledge.selftest")
        }

        do {
            let store = try NoteStore(folder: AppDelegate.notesFolder)
            self.store = store
            let workspace = Workspace(store: store)
            self.workspace = workspace

            if CommandLine.arguments.contains("--selftest") {
                Task {
                    _ = try? await store.scan()
                    workspace.start()
                    guard let deck = workspace.primaryDeck else { exit(1) }
                    await SelfTest.run(deck: deck)
                }
                return
            }

            Task {
                _ = try? await store.scan()
                await firstRunIfNeeded(store)
                workspace.start()
                startWatching(store, workspace: workspace)
            }

            statusItem = StatusItemController(workspace: workspace)
            registerHotkeys(workspace)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                for deck in workspace.decks where deck.handleKey(event) { return nil }
                return event
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Ledge could not open its notes folder"
            alert.informativeText = "\(AppDelegate.notesFolder.path)\n\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func registerHotkeys(_ workspace: Workspace) {
        hotkeys.register(.newNote) { workspace.newNote() }
        hotkeys.register(.allNotes) { workspace.showLibrary(filter: .all) }
        hotkeys.register(.archive) { workspace.showLibrary(filter: .archived) }
        hotkeys.register(.showDeck) {
            guard let deck = workspace.primaryDeck else { return }
            if deck.state == .rest { deck.fanOut(takingFocus: true) } else { deck.dismiss() }
        }
    }

    /// The deck reacts to a note edited in another app, or one arriving from
    /// iCloud, without a relaunch.
    private func startWatching(_ store: NoteStore, workspace: Workspace) {
        watcher = FolderWatcher(folder: AppDelegate.notesFolder) { names in
            Task { @MainActor in
                guard (try? await store.reconcile(filenames: names)) ?? 0 > 0 else { return }
                await workspace.refreshAll()
            }
        }
        watcher?.start()
    }

    /// No modal, no tour. One note that explains the deck, and then the deck
    /// fans itself open once so you see it happen.
    private func firstRunIfNeeded(_ store: NoteStore) async {
        guard (try? await store.count()) == 0 else { return }
        _ = try? await store.create(
            title: "Welcome",
            color: .butter,
            body: """
            This deck lives at the right edge of your screen.

            - At rest it is a thin stripe, one dash per note
            - Reach over and the notes fan out
            - Hover one to read it, click to write in it
            - ⌥⌘N makes a new note from anywhere

            Every note is a plain .md file in ~/Documents/Ledge.
            """
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        for deck in workspace?.decks ?? [] { deck.dismiss() }
        watcher?.stop()
        hotkeys.unregisterAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
