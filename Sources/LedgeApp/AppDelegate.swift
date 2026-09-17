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

    // MARK: - the keys everyone's fingers already know
    //
    // These live on the app delegate because that is where the main menu can
    // reach them: a status item's menu is not in the key equivalent chain, so
    // the ⌘+ and ⌘- printed beside its zoom entries never actually fired.

    @objc func zoomIn(_ sender: Any?)    { Settings.stepZoom(1) }
    @objc func zoomOut(_ sender: Any?)   { Settings.stepZoom(-1) }
    @objc func zoomReset(_ sender: Any?) { Settings.resetSizes() }

    @objc func openSettings(_ sender: Any?) { statusItem?.openMenu() }

    @objc func newNote(_ sender: Any?) { workspace?.newNote() }

    /// ⌘S. It already saved — the note has been on disk since 250 ms after you
    /// stopped typing. But the hand goes there on its own, and a key that does
    /// nothing is worse than one that confirms what already happened.
    @objc func saveNow(_ sender: Any?) { workspace?.commitAllSaves() }

    /// ⌘W puts the note away rather than closing a window: there is no window.
    @objc func putAway(_ sender: Any?) { workspace?.putAwayOpenNote() }

    @objc func openNoteAt(_ sender: NSMenuItem) {
        workspace?.openNote(at: sender.tag)
    }

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
    /// A plain PNG of a given size, for the checks about pictures.
    private static func writePNG(width: Int, height: Int, to url: URL) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                         pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: max(1, height / 4)).fill()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

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

        // Pictures for the media checks. Deliberately not a sixth fixture note:
        // several checks are about "the first note" or how five tabs lay out,
        // and adding one to the deck to test something unrelated is how this
        // suite has polluted itself before.
        let pictures = folder.appendingPathComponent(Media.folder)
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        writePNG(width: 80, height: 40, to: pictures.appendingPathComponent("small.png"))
        // Big enough that decoding it whole would be obvious: 2000x1500 is
        // 11.4 MB of pixels, and a note draws it in well under two.
        writePNG(width: 2000, height: 1500, to: pictures.appendingPathComponent("big.png"))

        // A crowded deck on demand. The fixtures are five notes, so every check
        // about how the stack is laid out has only ever seen a deck that fits —
        // which is how a deck of two hundred notes could put most of them, and
        // the plus button with them, past the bottom of the screen without a
        // single check noticing.
        let extra = ProcessInfo.processInfo.environment["LEDGE_SELFTEST_NOTES"]
            .flatMap(Int.init) ?? 0
        for i in 0..<extra {
            // Titles of different lengths, like the five fixtures: several
            // checks are about a tab being as long as its own words, and a
            // crowd of identical titles cannot tell them anything.
            let words = ["Crowd", "Crowd of people", "A rather longer title here",
                         "Six", "Middling title"][i % 5]
            var note = Note(title: "\(words) \(i)", color: NoteColor.allCases[i % 5],
                            rank: String(format: "b%04d", i))
            note.body = "- one\n- two"
            try? Data(Frontmatter.serialize(note).utf8)
                .write(to: folder.appendingPathComponent("Crowd \(i).md"))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        MainMenu.install()                      // …but ⌘C still has to mean copy

        if CommandLine.arguments.contains("--diagnose") {
            Diagnose.run()
            NSApp.terminate(nil)
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-icon") {
            let target = index + 1 < CommandLine.arguments.count
                ? URL(fileURLWithPath: CommandLine.arguments[index + 1])
                : URL(fileURLWithPath: "AppIcon.iconset")
            Renderer.renderIconSet(into: target)
            NSApp.terminate(nil)
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render") {
            let target = index + 1 < CommandLine.arguments.count
                ? URL(fileURLWithPath: CommandLine.arguments[index + 1])
                : URL(fileURLWithPath: "docs")
            Renderer.run(into: target)
            NSApp.terminate(nil)
            return
        }

        // TEMPORARY, for iterating on the form drawing against real payloads.
        if let index = CommandLine.arguments.firstIndex(of: "--render-form"),
           index + 2 < CommandLine.arguments.count {
            let json = (try? String(contentsOfFile: CommandLine.arguments[index + 1],
                                    encoding: .utf8)) ?? ""
            let width = CommandLine.arguments.count > index + 3
                ? CGFloat(Double(CommandLine.arguments[index + 3]) ?? 420) : 420
            if let image = MediaStore.form(json, available: width, scale: 2,
                                           ink: .black, font: .systemFont(ofSize: 13)),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                print("drew \(Int(image.size.width))×\(Int(image.size.height))")
            } else {
                print("no form in that JSON")
            }
            NSApp.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--selftest") {
            AppDelegate.writeSelfTestFixtures()
            // and never inherit whatever layout this machine happens to have
            UserDefaults.standard.removePersistentDomain(forName: "com.lisandro.Ledge.selftest")
        }

        do {
            let store = try NoteStore(folder: AppDelegate.notesFolder)
            self.store = store
            // Pictures are resolved against the notes folder, so every surface
            // that draws a note draws them — the deck's card, one pulled onto
            // the desk, and the big editor — without any of the three having to
            // be told.
            MediaStore.notesFolder = AppDelegate.notesFolder
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
                let isFirstRun = await firstRunIfNeeded(store)
                workspace.start()
                startWatching(store, workspace: workspace)
                if isFirstRun, let deck = workspace.primaryDeck {
                    await deck.demonstrate()
                }
            }

            statusItem = StatusItemController(workspace: workspace)
            registerHotkeys(workspace)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Before the decks and before the menu: the size keys are read
                // off the event rather than declared, because which character a
                // keyboard sends for ⌘+ is not something a menu item can be
                // told. See ZoomKeys.
                if ZoomKeys.handle(event) { return nil }
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
        hotkeys.register(.search) { workspace.showLibrary(filter: .all, query: "") }
        hotkeys.register(.paste) { workspace.newNoteFromClipboard() }
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
    @discardableResult
    private func firstRunIfNeeded(_ store: NoteStore) async -> Bool {
        guard (try? await store.count()) == 0 else { return false }
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
            Type a # in front of a word to tag it, like #welcome.
            """
        )
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for deck in workspace?.decks ?? [] { deck.dismiss() }
        watcher?.stop()
        hotkeys.unregisterAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// `ledge://` — how anything else on the machine reaches Ledge.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let workspace else { return }
        for url in urls {
            guard let command = LedgeURL.parse(url) else { continue }
            workspace.handle(command)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
