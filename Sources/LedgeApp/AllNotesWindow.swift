import AppKit
import LedgeCore
import LedgeIndex
import LedgeStore

/// Every note in one list. ⌥⌘A opens it on everything, ⌥⌘L on the archive.
///
/// The deck is for the handful of notes you are working on. This is where the
/// other two hundred live: search runs over titles, bodies and tags, so an
/// archived note from March is one query away.
@MainActor
final class AllNotesWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let window: NSWindow
    private let store: NoteStore
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["All", "Active", "Archived"],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let importButton = ChromeButton(title: "Import…")
    private let exportButton = ChromeButton(title: "Export…")
    private let table = NSTableView()
    private let detail = DetailPane()
    private let focus = FocusReturn()

    private var rows: [NoteRecord] = []
    private var excerpts: [String: String] = [:]
    private var searchDebounce: Timer?

    var onOpenInEditor: ((String) -> Void)?
    var onChanged: (() -> Void)?

    init(store: NoteStore) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()

        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 440)
        window.delegate = self
        window.center()

        let content = NSView()
        window.contentView = content

        let heading = NSTextField(labelWithString: "All Notes")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.identifier = NSUserInterfaceItemIdentifier("heading")
        content.addSubview(heading)

        search.placeholderString = "Search all notes"
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = false
        content.addSubview(search)

        filter.target = self
        filter.action = #selector(filterChanged)
        filter.selectedSegment = 0
        filter.segmentDistribution = .fit
        content.addSubview(filter)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        content.addSubview(countLabel)

        importButton.onClick = { [weak self] in self?.runImport() }
        content.addSubview(importButton)
        exportButton.onClick = { [weak self] in self?.runExport() }
        content.addSubview(exportButton)

        table.headerView = nil
        table.rowHeight = 54
        table.style = .inset
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note")))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.identifier = NSUserInterfaceItemIdentifier("scroll")
        content.addSubview(scroll)

        detail.onArchive = { [weak self] id in self?.setState(id, .archived) }
        detail.onRestore = { [weak self] id in self?.setState(id, .active) }
        detail.onDelete = { [weak self] id in self?.delete(id) }
        detail.onOpen = { [weak self] id in self?.onOpenInEditor?(id) }
        content.addSubview(detail)

        layout()
    }

    // MARK: - layout

    private func layout() {
        guard let content = window.contentView else { return }
        let sidebar: CGFloat = max(320, content.bounds.width * 0.42)
        let pad: CGFloat = 18
        let top = content.bounds.height - 46

        content.subviews.first { $0.identifier?.rawValue == "heading" }?
            .frame = NSRect(x: pad, y: top, width: 160, height: 22)
        let importWidth = importButton.intrinsicContentSize.width
        importButton.frame = NSRect(x: sidebar - pad - importWidth, y: top, width: importWidth, height: 22)
        countLabel.frame = NSRect(x: pad + 240, y: top - 65, width: sidebar - pad - 240 - pad, height: 16)
        let exportWidth = exportButton.intrinsicContentSize.width
        exportButton.frame = NSRect(x: sidebar - pad - exportWidth, y: top - 68, width: exportWidth, height: 24)
        search.frame = NSRect(x: pad, y: top - 34, width: sidebar - pad * 2, height: 24)
        filter.frame = NSRect(x: pad, y: top - 68, width: 230, height: 24)
        exportButton.isHidden = table.selectedRowIndexes.isEmpty

        let listTop = top - 78
        content.subviews.first { $0.identifier?.rawValue == "scroll" }?
            .frame = NSRect(x: pad - 8, y: pad, width: sidebar - pad * 2 + 16, height: listTop - pad)

        detail.frame = NSRect(x: sidebar, y: 0,
                              width: content.bounds.width - sidebar, height: content.bounds.height)
    }

    func windowDidResize(_ notification: Notification) { layout() }

    func windowWillClose(_ notification: Notification) { focus.restore() }

    // MARK: - showing

    func show(filter selected: NoteIndex.Filter) {
        filter.selectedSegment = selected == .archived ? 2 : (selected == .active ? 1 : 0)
        focus.capture()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
        Task { await reload() }
    }

    var isVisible: Bool { window.isVisible }

    private var currentFilter: NoteIndex.Filter {
        switch filter.selectedSegment {
        case 1: return .active
        case 2: return .archived
        default: return .all
        }
    }

    func reload() async {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            rows = (try? await store.records(currentFilter)) ?? []
            excerpts = [:]
        } else {
            let hits = (try? await store.search(query, filter: currentFilter)) ?? []
            rows = hits.map(\.record)
            excerpts = Dictionary(uniqueKeysWithValues: hits.map { ($0.record.id, $0.excerpt) })
        }
        countLabel.stringValue = rows.count == 1 ? "1 note" : "\(rows.count) notes"
        let previous = table.selectedRow
        table.reloadData()
        if !rows.isEmpty {
            let index = min(max(previous, 0), rows.count - 1)
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            detail.show(nothing: search.stringValue.isEmpty ? "No notes yet" : "Nothing matches")
        }
    }

    @objc private func searchChanged() {
        searchDebounce?.invalidate()
        searchDebounce = .scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    @objc private func filterChanged() { Task { await reload() } }

    @objc private func openSelected() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        onOpenInEditor?(rows[table.selectedRow].id)
    }

    // MARK: - export and import

    private var selectedRecords: [NoteRecord] {
        let indexes = table.selectedRowIndexes
        guard !indexes.isEmpty else { return rows }
        return indexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    private func runExport() {
        let chosen = selectedRecords
        guard !chosen.isEmpty else { return }

        let picker = NSAlert()
        picker.messageText = chosen.count == 1
            ? "Export “\(chosen[0].displayTitle)”"
            : "Export \(chosen.count) notes"
        picker.informativeText = "Only a Ledge archive comes back with colours, states and dates intact."
        for format in ExportFormat.allCases {
            picker.addButton(withTitle: format.name)
        }
        picker.addButton(withTitle: "Cancel")

        let index = picker.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < ExportFormat.allCases.count else { return }
        let format = ExportFormat.allCases[index]

        Task {
            let notes = (try? await store.notes(ids: chosen.map(\.id))) ?? []
            guard !notes.isEmpty else { return }
            let files = Exporter.files(for: format, notes: notes)
            write(files, singleFile: format.isSingleFile)
        }
    }

    private func write(_ files: [Exporter.File], singleFile: Bool) {
        if singleFile, let file = files.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? file.contents.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose a folder for \(files.count) file\(files.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var written: [URL] = []
        for file in files {
            let url = folder.appendingPathComponent(file.name)
            if (try? file.contents.write(to: url)) != nil { written.append(url) }
        }
        if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.prompt = "Import"
        panel.message = "Choose a .ledge archive"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        Task {
            do {
                let notes = try Exporter.read(archive: data)
                let count = try await store.importNotes(notes)
                await reload()
                onChanged?()
                let done = NSAlert()
                done.messageText = count == 1 ? "1 note imported" : "\(count) notes imported"
                done.informativeText = "Notes whose ids were already here came in as copies."
                done.runModal()
            } catch {
                let failed = NSAlert()
                failed.messageText = "That is not a Ledge archive"
                failed.informativeText = url.lastPathComponent
                failed.runModal()
            }
        }
    }

    // MARK: - actions

    private func setState(_ id: String, _ state: NoteState) {
        Task {
            _ = try? await store.setState(id: id, to: state)
            await reload()
            onChanged?()
        }
    }

    private func delete(_ id: String) {
        let title = rows.first { $0.id == id }?.displayTitle ?? "this note"
        let alert = NSAlert()
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "The .md file is removed from your notes folder. Archiving keeps it, off the deck but still searchable."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Archive instead")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { try? await store.delete(id: id); await reload(); onChanged?() }
        case .alertSecondButtonReturn:
            setState(id, .archived)
        default: break
        }
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = rows[row]
        let view = NoteRowView()
        view.configure(record: record, excerpt: excerpts[record.id] ?? record.snippet)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRowIndexes
        exportButton.isHidden = selected.isEmpty
        exportButton.relabel(selected.count > 1 ? "Export \(selected.count)…" : "Export…")
        if selected.count > 1 {
            detail.show(nothing: "\(selected.count) notes selected")
            return
        }
        guard let index = selected.first, index < rows.count else { return }
        let record = rows[index]
        Task {
            let body = (try? await store.load(id: record.id))?.body ?? record.snippet
            detail.show(record: record, body: body)
        }
    }
}
