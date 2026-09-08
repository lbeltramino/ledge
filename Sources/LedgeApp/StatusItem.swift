import AppKit
import LedgeCore
import LedgeIndex

/// The menu bar item.
///
/// The original design says no Dock icon and nothing visibly running, and the
/// deck itself is still the whole interface. But an app with no window and no
/// Dock tile needs *somewhere* to keep its size controls, its notes folder and
/// its quit — and hunting for a hidden shortcut is worse than a 16 pt glyph.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
        item.button?.image = StatusItemController.icon()
        item.button?.toolTip = "Ledge"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// A template glyph of the deck itself: the stripe on the edge, with its
    /// dashes. Drawn rather than an SF Symbol so it is unmistakably this app.
    private static func icon() -> NSImage {
        let size = NSSize(width: 17, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let strip = NSRect(x: rect.maxX - 8, y: 1, width: 10, height: rect.height - 2)
            NSColor.black.withAlphaComponent(0.30).setFill()
            NSBezierPath(roundedRect: strip, xRadius: 2.5, yRadius: 2.5).fill()
            NSColor.black.setFill()
            var y = strip.minY + 2.5
            for _ in 0..<3 {
                NSBezierPath(roundedRect: NSRect(x: strip.minX + 2.5, y: y, width: 5, height: 1.8),
                             xRadius: 0.9, yRadius: 0.9).fill()
                y += 3.6
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        add(menu, "New note", #selector(newNote), key: "n", modifiers: [.option, .command])
        add(menu, "Show deck", #selector(showDeck), key: "d", modifiers: [.option, .command])
        menu.addItem(.separator())
        add(menu, "All notes…", #selector(allNotes), key: "a", modifiers: [.option, .command])
        add(menu, "Archive…", #selector(archive), key: "l", modifiers: [.option, .command])
        menu.addItem(.separator())

        let zoom = NSMenuItem(title: "Size — \(Int(Settings.zoom * 100))%", action: nil, keyEquivalent: "")
        zoom.isEnabled = false
        menu.addItem(zoom)
        add(menu, "Bigger", #selector(zoomIn), key: "+", modifiers: [.command], indent: 1)
        add(menu, "Smaller", #selector(zoomOut), key: "-", modifiers: [.command], indent: 1)
        add(menu, "Reset", #selector(zoomReset), key: "0", modifiers: [.command], indent: 1)

        menu.addItem(sizeSubmenu("Tab size", current: Settings.tabScale, action: #selector(setTabSize(_:))))
        menu.addItem(sizeSubmenu("Card size", current: Settings.cardScale, action: #selector(setCardSize(_:))))
        menu.addItem(lengthSubmenu())
        menu.addItem(stripsSubmenu())
        menu.addItem(faceSubmenu())
        menu.addItem(.separator())

        if workspace.hasFloatingNotes {
            add(menu, "Put floating notes back", #selector(redockAll), key: "")
        }
        add(menu, "Open notes folder", #selector(openFolder), key: "")
        add(menu, "Choose notes folder…", #selector(chooseFolder), key: "")
        menu.addItem(.separator())
        add(menu, "Quit Ledge", #selector(quit), key: "q", modifiers: [.command])
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     key: String, modifiers: NSEvent.ModifierFlags = [],
                     indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.indentationLevel = indent
        menu.addItem(item)
        return item
    }

    private func sizeSubmenu(_ title: String, current: CGFloat, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for preset in Settings.sizePresets {
            let item = NSMenuItem(title: preset.name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = preset.value
            item.state = abs(preset.value - current) < 0.01 ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// How far a tab may grow before its title starts truncating.
    private func lengthSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Tab length", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for preset in Settings.lengthPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(setTabLength(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.value
            item.state = abs(preset.value - Settings.tabMaxLength) < 0.5 ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// Add a strip to any edge of any display, and take one away again. The
    /// primary strip cannot be removed: it is where unassigned notes live.
    private func stripsSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Strips", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for strip in Settings.strips {
            let item = NSMenuItem(title: "\(strip.name) — \(strip.subtitle)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            let pin = NSMenuItem(title: strip.pinned ? "Tabs stay out" : "Tabs fold away",
                                 action: #selector(togglePin(_:)), keyEquivalent: "")
            pin.target = self
            pin.representedObject = strip.id
            pin.state = strip.pinned ? .on : .off
            pin.indentationLevel = 1
            submenu.addItem(pin)

            let along = strip.edge.isHorizontal
                ? [("Left", -0.5), ("Middle", 0.0), ("Right", 0.5)]
                : [("Top", -0.5), ("Middle", 0.0), ("Bottom", 0.5)]
            for (name, value) in along {
                let item = NSMenuItem(title: name, action: #selector(setPosition(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["strip": strip.id, "offset": value] as [String: Any]
                item.state = abs(strip.offset - value) < 0.2 ? .on : .off
                item.indentationLevel = 2
                submenu.addItem(item)
            }
            let nudgeBack = NSMenuItem(title: strip.edge.isHorizontal ? "Nudge left" : "Nudge up",
                                       action: #selector(nudge(_:)), keyEquivalent: "")
            nudgeBack.target = self
            nudgeBack.representedObject = ["strip": strip.id, "delta": -0.06] as [String: Any]
            nudgeBack.indentationLevel = 2
            submenu.addItem(nudgeBack)
            let nudgeOn = NSMenuItem(title: strip.edge.isHorizontal ? "Nudge right" : "Nudge down",
                                     action: #selector(nudge(_:)), keyEquivalent: "")
            nudgeOn.target = self
            nudgeOn.representedObject = ["strip": strip.id, "delta": 0.06] as [String: Any]
            nudgeOn.indentationLevel = 2
            submenu.addItem(nudgeOn)

            if !strip.isPrimary {
                let remove = NSMenuItem(title: "Remove", action: #selector(removeStrip(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = strip.id
                remove.indentationLevel = 1
                submenu.addItem(remove)
            }
            submenu.addItem(.separator())
        }

        submenu.addItem(.separator())
        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() {
            for edge in [StripEdge.left, StripEdge.right, StripEdge.bottom] {
                let where_ = screens.count > 1
                    ? "\(edge.label) edge, display \(index + 1)"
                    : "\(edge.label) edge"
                let item = NSMenuItem(title: "Add strip · \(where_)",
                                      action: #selector(addStrip(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["edge": edge.rawValue, "screen": screen.ledgeDisplayID] as [String: Any]
                submenu.addItem(item)
            }
        }

        parent.submenu = submenu
        return parent
    }

    @objc private func addStrip(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let raw = info["edge"] as? String, let edge = StripEdge(rawValue: raw),
              let id = info["screen"] as? UInt32,
              let screen = NSScreen.screens.first(where: { $0.ledgeDisplayID == id })
        else { return }
        Settings.addStrip(edge: edge, screen: screen)
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.update(id) { $0.pinned.toggle() }
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["strip"] as? String, let offset = info["offset"] as? Double else { return }
        Settings.update(id) { $0.offset = offset }
    }

    @objc private func nudge(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["strip"] as? String, let delta = info["delta"] as? Double else { return }
        Settings.update(id) { $0.offset = min(0.5, max(-0.5, $0.offset + delta)) }
    }

    @objc private func removeStrip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.removeStrip(id: id)
    }

    private func faceSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Note face", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (face, name) in [(Typography.Face.casual, "Handwritten"), (.legible, "Legible")] {
            let item = NSMenuItem(title: name, action: #selector(setFace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = face.rawValue
            item.state = Settings.noteFace == face ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - actions

    @objc private func newNote()  { workspace.newNote() }
    @objc private func showDeck() {
        guard let deck = workspace.primaryDeck else { return }
        if deck.state == .rest { deck.fanOut(takingFocus: true) } else { deck.dismiss() }
    }
    @objc private func zoomIn()    { Settings.stepZoom(1) }
    @objc private func zoomOut()   { Settings.stepZoom(-1) }
    @objc private func zoomReset() { Settings.resetSizes() }

    @objc private func setTabSize(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? CGFloat { Settings.tabScale = value }
    }
    @objc private func setCardSize(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? CGFloat { Settings.cardScale = value }
    }
    @objc private func setTabLength(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? CGFloat { Settings.tabMaxLength = value }
    }

    @objc private func setFace(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let face = Typography.Face(rawValue: raw) { Settings.noteFace = face }
    }

    @objc private func allNotes() { workspace.showLibrary(filter: .all) }
    @objc private func archive()  { workspace.showLibrary(filter: .archived) }
    @objc private func redockAll() { workspace.redockAll() }

    @objc private func openFolder() {
        NSWorkspace.shared.open(AppDelegate.notesFolder)
    }

    /// Points Ledge at a different folder — the one thing needed to keep notes
    /// in iCloud Drive, since all file access is already coordinated.
    @objc private func chooseFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AppDelegate.notesFolder.deletingLastPathComponent()
        panel.prompt = "Use this folder"
        panel.message = "Where should Ledge keep your notes?"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        guard chosen != AppDelegate.notesFolder else { return }

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: AppDelegate.notesFolder.path))?
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.count ?? 0

        var moveNotes = false
        if existing > 0 {
            let alert = NSAlert()
            alert.messageText = existing == 1
                ? "Move your note to the new folder?"
                : "Move your \(existing) notes to the new folder?"
            alert.informativeText = """
                Move them and the files go with you. Leave them and Ledge shows \
                whatever is already in the folder you picked; the old notes stay \
                where they are, untouched.
                """
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Leave them")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: moveNotes = true
            case .alertSecondButtonReturn: moveNotes = false
            default: return
            }
        }

        Task {
            do {
                try await workspace.relocate(to: chosen, movingNotes: moveNotes)
            } catch {
                let failed = NSAlert()
                failed.messageText = "Ledge could not use that folder"
                failed.informativeText = error.localizedDescription
                failed.runModal()
            }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
