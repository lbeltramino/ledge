import AppKit
import LedgeCore

/// A picture or a diagram, drawn on the paper under the markdown that asks for
/// it.
///
/// Deliberately not an `NSImageView`: when the file is missing or the mermaid
/// does not parse, this says so on the paper in the note's own ink. A blank
/// gap would be indistinguishable from a note that had not finished loading,
/// and that is exactly the report that came back the last time something was
/// drawn over text.
final class MediaView: NSView {

    enum Content {
        case picture(NSImage)
        /// Nothing to draw, and why — shown as a quiet line, not an alert.
        case missing(String)
    }

    /// Where this came from, so it can be put on the clipboard. A picture is
    /// copied from its file at full quality — what you want when you paste it
    /// somewhere else is the picture, not the thumbnail a note happened to
    /// draw.
    enum Origin { case file(URL), diagram(String), form(String) }
    var origin: Origin?

    private var content: Content = .missing("")
    var ink: NSColor = .labelColor
    var paper: NSColor = .white

    override var isFlipped: Bool { true }

    /// Drawings are scenery: clicks, selection and the caret belong to the text
    /// underneath, exactly as with a drawn table.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ content: Content) {
        self.content = content
        needsDisplay = true
    }

    /// What this wants to be drawn at, given the room — the number the text
    /// view reserves before it puts the view anywhere.
    static func height(of content: Content, available: CGFloat) -> CGFloat {
        switch content {
        case .picture(let image):
            return MediaStore.fit(image.size, into: available).height + padding * 2
        case .missing:
            return 22
        }
    }

    static let padding: CGFloat = 6

    /// Where the picture itself is, inside this view's full-width frame — the
    /// copy mark hangs off its corner, not off the paper beside it.
    var pictureRect: NSRect? {
        guard case .picture(let image) = content else { return nil }
        let size = MediaStore.fit(image.size, into: bounds.width)
        return NSRect(x: 0, y: Self.padding, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .picture(let image):
            let size = MediaStore.fit(image.size, into: bounds.width)
            let box = NSRect(x: 0, y: Self.padding,
                             width: size.width, height: size.height)
            // A hairline, the way a picture on a desk has an edge. Without it a
            // screenshot of a white app dissolves into the paper.
            ink.withAlphaComponent(0.10).setStroke()
            let edge = NSBezierPath(roundedRect: box.insetBy(dx: -0.5, dy: -0.5),
                                    xRadius: 3, yRadius: 3)
            edge.lineWidth = 1
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            edge.stroke()

        case .missing(let why):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: ink.withAlphaComponent(0.45),
            ]
            (why as NSString).draw(at: NSPoint(x: 2, y: 4), withAttributes: attributes)
        }
    }

    var debugContent: Content { content }
    var debugIsPicture: Bool { if case .picture = content { return true }; return false }
    var debugMissingReason: String? {
        if case .missing(let why) = content { return why }
        return nil
    }
}
