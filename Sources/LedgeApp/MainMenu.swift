import AppKit

/// An app with `LSUIElement` shows no menu bar — but the main menu is still
/// where ⌘C, ⌘V, ⌘Z and ⌘A are *defined*. Without one, those keys never become
/// `copy:`, `paste:`, `undo:` or `selectAll:`, and every text view in the app
/// silently ignores them.
///
/// So the menu exists purely to carry key equivalents. Nobody ever sees it.
@MainActor
enum MainMenu {

    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Hide Ledge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Ledge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        // These must be the responder-chain selectors, not UndoManager's own
        // no-argument methods, or ⌘Z quietly does nothing.
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "Z")
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Paste and Match Style",
            #selector(NSTextView.pasteAsPlainText(_:)), "V", [.command, .option, .shift])
        add(edit, "Delete", #selector(NSText.delete(_:)), "")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())

        // Find is handled by the note itself — see NoteTextView.performKeyEquivalent
        // — so this entry exists to show the shortcut, not to route it.
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "Find")
        find.addItem(NSMenuItem(title: "Find in note   ⌘F", action: nil, keyEquivalent: ""))
        find.addItem(NSMenuItem(title: "Next   ⌘G", action: nil, keyEquivalent: ""))
        find.addItem(NSMenuItem(title: "Previous   ⇧⌘G", action: nil, keyEquivalent: ""))
        findItem.submenu = find
        edit.addItem(findItem)

        editItem.submenu = edit
        main.addItem(editItem)

        // The keys every Mac app has, which this one did not. The zoom entries
        // in the status menu printed ⌘+ and ⌘- beside them and never fired: a
        // status item's menu is not consulted for key equivalents. These are.
        let noteItem = NSMenuItem()
        let note = NSMenu(title: "Note")
        add(note, "New Note", #selector(AppDelegate.newNote(_:)), "n")
        add(note, "Save", #selector(AppDelegate.saveNow(_:)), "s")
        add(note, "Put Away", #selector(AppDelegate.putAway(_:)), "w")
        note.addItem(.separator())
        let goItem = NSMenuItem(title: "Go to", action: nil, keyEquivalent: "")
        let go = NSMenu(title: "Go to")
        for n in 1...9 {
            let item = NSMenuItem(title: "Note \(n)", action: #selector(AppDelegate.openNoteAt(_:)),
                                  keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = n
            go.addItem(item)
        }
        goItem.submenu = go
        note.addItem(goItem)
        noteItem.submenu = note
        main.addItem(noteItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        // ⌘+ depends on the keyboard, and getting this wrong is invisible until
        // someone with a different one tries it.
        //
        //   US:      + is ⇧= — the event carries shift, and "=" underneath
        //   Spanish: + is its own unshifted key, and ⇧ gives *
        //
        // A single declaration serves one of those and silently fails the other,
        // which is exactly what happened: an item declaring "+" under ⌘⇧ works
        // in New York and does nothing in Buenos Aires. So all three spellings
        // are claimed, and only one of them can ever match a given press.
        add(view, "Bigger", #selector(AppDelegate.zoomIn(_:)), "+", [.command])
        for (key, modifiers) in [("+", NSEvent.ModifierFlags([.command, .shift])),
                                 ("=", NSEvent.ModifierFlags([.command]))] {
            let also = NSMenuItem(title: "Bigger", action: #selector(AppDelegate.zoomIn(_:)),
                                  keyEquivalent: key)
            also.keyEquivalentModifierMask = modifiers
            also.isHidden = true
            view.addItem(also)
        }
        add(view, "Smaller", #selector(AppDelegate.zoomOut(_:)), "-")
        add(view, "Actual Size", #selector(AppDelegate.zoomReset(_:)), "0")
        view.addItem(.separator())
        add(view, "Settings…", #selector(AppDelegate.openSettings(_:)), ",")
        viewItem.submenu = view
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                            _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }
}
