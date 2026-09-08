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

        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "Find")
        let findAction = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findAction.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        find.addItem(findAction)
        findItem.submenu = find
        edit.addItem(findItem)

        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                            _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }
}
