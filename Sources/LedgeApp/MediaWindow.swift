import AppKit
import LedgeCore

/// A drawing at a size you can actually read.
///
/// A note is a sticky note, and a form with four groups in it drawn at the
/// width of one is honest about the layout and useless for reading. So the
/// drawing gets somewhere to be looked at: its own window, scrolled and zoomed,
/// and nothing else in it.
///
/// Not a modal. A modal would stop you looking at the note the drawing came
/// from, which is the thing you are comparing it against. It floats, Esc
/// closes it, and there is only ever one — opening another drawing reuses it,
/// the way a preview pane would.
final class MediaWindow: NSPanel {

    /// What can be looked at this way. Each one is something that can be drawn
    /// again at any size, which is what makes zooming worth doing: the picture
    /// is decoded at the size asked for and the two drawn things are laid out
    /// again, rather than a bitmap being stretched.
    enum Subject: Equatable {
        case picture(URL)
        case diagram(String)
        case form(String)
    }

    private static var current: MediaWindow?

    private let zoomView = MediaZoomView()
    private let scroll = NSScrollView()
    private weak var returnFocusTo: NSWindow?

    static func show(_ subject: Subject, title: String, ink: NSColor, paper: NSColor,
                     dark: Bool) {
        let window = current ?? MediaWindow()
        current = window
        window.returnFocusTo = NSApp.keyWindow
        window.present(subject, title: title, ink: ink, paper: paper, dark: dark)
    }

    /// Whether anything is open, and what — for a check, and for closing it
    /// when the note it came from goes away.
    static var showing: Subject? { current?.isVisible == true ? current?.zoomView.subject : nil }
    static func closeAny() { current?.close() }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = false
        // The deck's panels never take focus; this one has to, because it is
        // driven by the keyboard once it is open.
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.documentView = zoomView
        contentView = scroll
    }

    private func present(_ subject: Subject, title: String, ink: NSColor, paper: NSColor,
                         dark: Bool) {
        self.title = title
        scroll.backgroundColor = paper
        zoomView.configure(subject, ink: ink, paper: paper, dark: dark)

        // Big enough to read, never bigger than the screen it opens on.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let room = screen.visibleFrame.insetBy(dx: 60, dy: 60)
            let wanted = zoomView.frame.size
            let size = NSSize(width: min(max(420, wanted.width + 24), room.width),
                              height: min(max(320, wanted.height + 24), room.height))
            setContentSize(size)
            if !isVisible { center() }
        }

        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(zoomView)
    }

    override var canBecomeKey: Bool { true }

    /// Esc, and the close button, both hand focus back where it came from —
    /// the same bargain closing a note makes.
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        let giveBack = returnFocusTo
        super.close()
        giveBack?.makeKeyAndOrderFront(nil)
    }

    /// The size keys, while a drawing is the thing in front.
    ///
    /// Called from the key monitor before the app-wide zoom, because that
    /// monitor reads the event and swallows it before any window sees a
    /// `keyDown` — so ⌘+ in here made the whole app bigger and left the form
    /// exactly the size it was. Reported precisely that way.
    ///
    /// Through `ZoomKeys` rather than by comparing characters: which key sends
    /// `+` depends on the layout, which is the entire reason that type exists.
    static func handleKey(_ event: NSEvent) -> Bool {
        guard let window = current, window.isVisible, window.isKeyWindow else { return false }
        if let command = ZoomKeys.command(for: event) {
            window.zoomView.apply(command)
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "1": window.zoomView.zoomToActualSize()
        case "c": window.zoomView.copyToClipboard()
        default: return false
        }
        return true
    }

    /// A check drives the view, never the window: creating a real panel inside
    /// `--selftest` is what hangs it.
    var debugZoomView: MediaZoomView { zoomView }
}

/// The drawing itself, at whatever size is being asked of it.
final class MediaZoomView: NSView {

    private(set) var subject: MediaWindow.Subject?
    private var ink: NSColor = .black
    private var paper: NSColor = .white
    private var dark = false
    private var content: NSImage?

    /// The width that `zoom == 1` means. For the two drawn things it is a
    /// readable column; for a picture it is the picture's own pixels, so 1 is
    /// life size and the number in the title means something.
    private var baseWidth: CGFloat = 620

    private(set) var zoom: CGFloat = 1

    static let minimum: CGFloat = 0.2
    static let maximum: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(_ subject: MediaWindow.Subject, ink: NSColor, paper: NSColor, dark: Bool) {
        self.subject = subject
        self.ink = ink
        self.paper = paper
        self.dark = dark
        self.zoom = 1
        self.baseWidth = Self.naturalWidth(of: subject)
        rebuild()
    }

    private static func naturalWidth(of subject: MediaWindow.Subject) -> CGFloat {
        switch subject {
        case .picture(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let size = MediaStore.pixelSize(of: source) else { return 620 }
            return max(120, size.width)
        case .form(let source): return MediaStore.formWidth(source) ?? 620
        // A column wide enough that a diagram's own text is not shrunk.
        case .diagram: return 620
        }
    }

    // MARK: - zooming

    func zoomIn() { set(zoom * 1.25) }
    func zoomOut() { set(zoom / 1.25) }
    func zoomToActualSize() { set(1) }

    /// The zoom at which the whole drawing fits the window, which is what you
    /// want the moment something is taller than the screen.
    func zoomToFit() {
        guard let clip = superview as? NSClipView, let content else { return }
        let scale = min(clip.bounds.width / (content.size.width / zoom),
                        clip.bounds.height / (content.size.height / zoom))
        set(scale)
    }

    private func set(_ wanted: CGFloat) {
        let next = min(max(wanted, Self.minimum), Self.maximum)
        guard abs(next - zoom) > 0.001 else { return }
        zoom = next
        rebuild()
    }

    override func magnify(with event: NSEvent) { set(zoom * (1 + event.magnification)) }

    override func scrollWheel(with event: NSEvent) {
        // ⌘ and the wheel is zoom everywhere else on this machine; without it
        // the wheel is the scroll view's.
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        set(zoom * (1 + event.scrollingDeltaY * 0.01))
    }

    /// ⌘0 is "fit", not "actual size": on a drawing, the thing you want back is
    /// the whole of it. ⌘1 is life size, where a picture is its own pixels.
    func apply(_ command: ZoomKeys.Command) {
        switch command {
        case .bigger: zoomIn()
        case .smaller: zoomOut()
        case .actualSize: zoomToFit()
        }
    }

    /// ⌘C takes the drawing, at a size worth pasting.
    ///
    /// Not what is on screen: you may be looking at it at 40% to see the whole
    /// thing, and what you want in the ticket is the drawing, legible. So it is
    /// drawn once more at twice life size, the same bargain the copy mark on
    /// the paper makes.
    @discardableResult
    func copyToClipboard(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let subject else { return false }
        let image: NSImage?
        switch subject {
        case .form(let source):
            image = MediaStore.formForCopying(source, ink: ink)
        case .diagram(let source):
            image = MediaStore.diagramForCopying(source, dark: dark)
        case .picture(let url):
            image = NSImage(contentsOf: url)
        }
        guard let image else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        return true
    }

    // MARK: - drawing

    /// Draws the subject again at the current zoom and takes the size it came
    /// to. Everything here can be laid out at any size, so this is a redraw
    /// rather than a stretch — text stays text at 4×.
    func rebuild() {
        guard let subject else { return }
        let width = baseWidth * zoom
        let backing = window?.backingScaleFactor ?? 2

        switch subject {
        case .form(let source):
            // Straight to the drawing: `MediaStore.form` never draws wider than
            // the form asks for, and here going wider is the whole point.
            content = UISchema.find(in: source).flatMap {
                FormDraw.image($0, width: width, scale: backing, ink: ink)
            }
        case .diagram(let source):
            content = MediaStore.diagram(source, available: width, scale: backing, dark: dark)
        case .picture(let url):
            content = MediaStore.picture(at: url, width: width, scale: backing)
        }

        frame.size = content?.size ?? NSSize(width: width, height: 40)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill()
        dirtyRect.fill()
        guard let content else {
            let message = "nothing to draw"
            (message as NSString).draw(at: NSPoint(x: 12, y: 12), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: ink.withAlphaComponent(0.5),
            ])
            return
        }
        content.draw(in: NSRect(origin: .zero, size: frame.size))
    }

    var debugContentSize: NSSize? { content?.size }
    var debugContent: NSImage? { content }
}
