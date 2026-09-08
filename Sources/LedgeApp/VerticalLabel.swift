import AppKit

/// The rotated title that rides the edge of a tab, and then the edge of the
/// card that tab grows into.
///
/// The geometry is a pure function so it can be asserted rather than eyeballed —
/// the first version pushed every label a full text-height to the right, which
/// on the rightmost tab meant the title was sliced off by the screen edge.
enum VerticalLabel {

    /// A typewriter face, not the UI sans. The labels are part of the paper.
    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "AmericanTypewriter-Bold", size: size)
            ?? NSFont(name: "AmericanTypewriter", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .semibold)
    }

    static func attributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font(size: size), .foregroundColor: color, .kern: size * 0.08]
    }

    /// Fits `text` into `available` points of run length, with an ellipsis when
    /// it will not go.
    static func fitted(_ text: String, available: CGFloat,
                       attributes: [NSAttributedString.Key: Any]) -> NSString {
        let full = text.uppercased() as NSString
        guard full.size(withAttributes: attributes).width > available else { return full }
        var trimmed = full as String
        while !trimmed.isEmpty,
              ((trimmed + "…") as NSString).size(withAttributes: attributes).width > available {
            trimmed.removeLast()
        }
        return (trimmed + "…") as NSString
    }

    /// Where the label will land, in the view's own (flipped) coordinates.
    ///
    /// In a flipped context the reflection reverses handedness, so the rotation
    /// that makes text read *downward* is +90°, and a point (u, v) maps to
    /// (tx − v, ty + u). Centring the run therefore puts the translation at
    /// `midX + textHeight/2`, not `midX + textHeight/2` past the centre.
    static func layout(in bounds: NSRect, textSize: NSSize, inset: CGFloat)
        -> (translate: NSPoint, box: NSRect) {
        let translate = NSPoint(x: bounds.midX + textSize.height / 2, y: bounds.minY + inset)
        let box = NSRect(x: bounds.midX - textSize.height / 2,
                         y: bounds.minY + inset,
                         width: textSize.height,
                         height: textSize.width)
        return (translate, box)
    }

    /// A bottom strip's tabs are wide and short, so their titles simply read
    /// across. Same measuring, no rotation.
    @discardableResult
    static func drawHorizontal(_ text: String, in bounds: NSRect, inset: CGFloat,
                               size: CGFloat, color: NSColor) -> NSRect {
        let attributes = attributes(size: size, color: color)
        let string = fitted(text, available: bounds.width - inset * 2, attributes: attributes)
        let textSize = string.size(withAttributes: attributes)
        // `bounds` is in the *view's* coordinates, so its origin matters. Leaving
        // it out worked for tabs, whose rect starts at zero, and put the title of
        // a bottom card at the top of the card while its handle stayed at the
        // bottom — the two coming apart.
        let box = NSRect(x: bounds.minX + inset,
                         y: bounds.minY + (bounds.height - textSize.height) / 2,
                         width: textSize.width, height: textSize.height)
        string.draw(at: box.origin, withAttributes: attributes)
        return box
    }

    static func horizontalBox(for text: String, in bounds: NSRect,
                              inset: CGFloat, size: CGFloat) -> NSRect {
        let attributes = attributes(size: size, color: .black)
        let string = fitted(text, available: bounds.width - inset * 2, attributes: attributes)
        let textSize = string.size(withAttributes: attributes)
        return NSRect(x: bounds.minX + inset,
                      y: bounds.minY + (bounds.height - textSize.height) / 2,
                      width: textSize.width, height: textSize.height)
    }

    @discardableResult
    static func draw(_ text: String, in bounds: NSRect, inset: CGFloat,
                     size: CGFloat, color: NSColor) -> NSRect {
        let attributes = attributes(size: size, color: color)
        let available = bounds.height - inset * 2
        let string = fitted(text, available: available, attributes: attributes)
        let textSize = string.size(withAttributes: attributes)
        let (translate, box) = layout(in: bounds, textSize: textSize, inset: inset)

        guard let context = NSGraphicsContext.current else { return box }
        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: translate.x, yBy: translate.y)
        transform.rotate(byDegrees: 90)
        transform.concat()
        string.draw(at: .zero, withAttributes: attributes)
        context.restoreGraphicsState()
        return box
    }

    /// For the self test: the box a label of this title would occupy.
    static func box(for text: String, in bounds: NSRect, inset: CGFloat, size: CGFloat) -> NSRect {
        let attributes = attributes(size: size, color: .black)
        let string = fitted(text, available: bounds.height - inset * 2, attributes: attributes)
        return layout(in: bounds, textSize: string.size(withAttributes: attributes), inset: inset).box
    }
}
