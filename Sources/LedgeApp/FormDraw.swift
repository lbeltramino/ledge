import AppKit
import LedgeCore

/// A JSONForms uiSchema, drawn as the form it describes.
///
/// A wireframe, deliberately: no field takes the caret, nothing validates and
/// no rule is evaluated. What it answers is the question you actually have
/// while writing a uiSchema — *what does this lay out as* — and it answers it
/// while you type, which is the part a round trip through a front end does not
/// give you.
///
/// Measuring and drawing are one walk, not two: a layout measured in one
/// function and drawn in another is a layout that will disagree with itself.
/// The walk emits shapes and returns where it ended; the height is that number
/// and the drawing is those shapes.
enum FormDraw {

    /// The colour a form marks something out in, given the note's ink — for
    /// the check that it is never anything but that ink.
    static func attentionColour(ink: NSColor, dark: Bool) -> NSColor {
        Pen(ink: ink, dark: dark).attention
    }

    // MARK: - what the walk emits

    private enum Shape {
        case box(NSRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?, dashed: Bool)
        /// `wrap` false is one line, cut with an ellipsis — a field label in a
        /// narrow column has to lose its tail rather than its neighbour's room.
        case text(String, NSRect, NSFont, NSColor, wrap: Bool)
    }

    /// Type and spacing, at the size the form is *designed* at rather than at
    /// whatever room a note happens to have.
    ///
    /// The numbers are the ones swift-mermaid lays a diagram out with — 16 pt
    /// for a node's text, 13 for a label on an edge, 16 semibold for the title
    /// of a subgraph, 18 by 12 of padding. That is why a diagram in a note is
    /// legible and the first version of this was not: mermaid designs big and
    /// scales the finished drawing down to fit, and this measured itself
    /// against the width it had and shrank the type to 10 pt to get there.
    ///
    /// So: laid out at these sizes, always, and scaled once at the end.
    private struct Pen {
        let ink: NSColor
        let dark: Bool

        var faint: NSColor { ink.withAlphaComponent(0.42) }
        var mid: NSColor { ink.withAlphaComponent(0.62) }
        var strong: NSColor { ink.withAlphaComponent(0.85) }
        var rule: NSColor { ink.withAlphaComponent(0.16) }
        var well: NSColor { ink.withAlphaComponent(0.05) }
        /// What is worth looking at twice — in the note's own ink, like
        /// everything else here.
        ///
        /// It was red, then indigo. Both were wrong for the same reason: a
        /// colour of its own belongs to no note, so it does not change when the
        /// note's colour does and it fights whichever paper it lands on. (Red
        /// also measured 2.0 to one against coral, which is barely legible —
        /// the one thing worth reading, in the one colour you could not.)
        ///
        /// So there is no second colour. What marks something out is weight and
        /// the ⚠ beside it, which survive every scheme because they are not
        /// colours at all.
        var attention: NSColor { ink.withAlphaComponent(0.9) }

        var small: NSFont { .systemFont(ofSize: 13) }
        var label: NSFont { .systemFont(ofSize: 14, weight: .medium) }
        var title: NSFont { .systemFont(ofSize: 16, weight: .semibold) }
        var value: NSFont { .systemFont(ofSize: 14) }
    }

    // MARK: - the one entry point

    /// The form drawn to exactly `width`.
    ///
    /// Laid out at its natural size and then scaled to get there, the way
    /// mermaid does — so the type keeps its proportions instead of being
    /// squeezed, and scaling is a redraw of vectors rather than a stretched
    /// bitmap. Under its natural width it shrinks; above it, it grows, which is
    /// what the window that zooms one asks for.
    static func image(_ form: UISchema.Form, width: CGFloat, scale: CGFloat,
                      ink: NSColor, dark: Bool) -> NSImage? {
        // Narrow the layout before shrinking the type. Given 350 pt for a form
        // that would like 468, laying it out at 350 gives two columns of 151 pt
        // with the text at its proper size; laying it out at 468 and scaling
        // gives two roomy columns of 10 pt text, which is the complaint that
        // started all of this. Only below one usable column does the type give
        // way.
        let wanted = max(0.05, width)
        let layout = max(minimumWidth, min(wanted, naturalWidth(of: form)))
        let pen = Pen(ink: ink, dark: dark)

        var shapes: [Shape] = []
        let height = walk(form, width: layout, pen: pen, into: &shapes)
        guard height > 1 else { return nil }

        var shrink = wanted / layout
        var size = NSSize(width: (layout * shrink).rounded(),
                          height: (height * shrink).rounded())

        // A ceiling on the bitmap, because a form is as tall as it needs to be
        // and the window that zooms one multiplies both sides. A long payload
        // at 8× comes to half a gigabyte of pixels in a single allocation, and
        // nothing else in this app allocates like that.
        //
        // Density goes first — at that size there is nothing left to resolve —
        // and only then the drawing itself.
        var backing = max(1, scale)
        if size.width * size.height * backing * backing > Self.pixelBudget, backing > 1 {
            backing = 1
        }
        let pixels = size.width * size.height * backing * backing
        if pixels > Self.pixelBudget {
            let over = (Self.pixelBudget / pixels).squareRoot()
            shrink *= over
            size = NSSize(width: (layout * shrink).rounded(), height: (height * shrink).rounded())
        }
        guard size.width >= 1, size.height >= 1 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * backing), pixelsHigh: Int(size.height * backing),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The walk lays out top-down like the text view does; the context runs
        // bottom-up. One flip here rather than arithmetic at every shape.
        let flip = NSAffineTransform()
        flip.scaleX(by: backing, yBy: backing)
        flip.translateX(by: 0, yBy: size.height)
        flip.scaleX(by: 1, yBy: -1)
        // …and then into the layout's own coordinates, so everything below can
        // go on thinking in the sizes it was designed at.
        flip.scaleX(by: shrink, yBy: shrink)
        flip.concat()
        for shape in shapes { paint(shape) }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func paint(_ shape: Shape) {
        switch shape {
        case let .box(rect, radius, fill, stroke, dashed):
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            if let fill { fill.setFill(); path.fill() }
            if let stroke {
                stroke.setStroke()
                path.lineWidth = 1
                if dashed { path.setLineDash([2, 2.5], count: 2, phase: 0) }
                path.stroke()
            }
        case let .text(string, rect, font, colour, wrap):
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: colour, .paragraphStyle: style,
            ]
            // Text in a flipped context comes out upside down, so each run is
            // flipped back about its own rect — which maps the rect onto itself
            // and nothing else has to move.
            guard let context = NSGraphicsContext.current else { return }
            context.saveGraphicsState()
            let back = NSAffineTransform()
            back.translateX(by: 0, yBy: rect.minY + rect.maxY)
            back.scaleX(by: 1, yBy: -1)
            back.concat()
            (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                                      attributes: attributes)
            context.restoreGraphicsState()
        }
    }

    // MARK: - the walk

    // swift-mermaid's node padding, for the same reason as the fonts.
    private static let pad: CGFloat = 18
    private static let gap: CGFloat = 12

    /// The narrowest column a field is worth drawing in, before the whole
    /// drawing is scaled. Below this a two-column row stops being two columns
    /// of anything.
    private static let column: CGFloat = 210

    /// The most pixels one drawing may be rasterised into: eight million,
    /// which is 32 MB and about a 2000 by 2000 point drawing at retina
    /// density. Everything this app draws normally is a fraction of it — a
    /// form on a note is around two million — and what it exists for is the
    /// zoomed window, where the two sides multiply.
    private static let pixelBudget: CGFloat = 8 * 1024 * 1024

    /// One column, with its padding: narrower than this and the type has to
    /// give way instead.
    static var minimumWidth: CGFloat { pad * 2 + column }

    /// The width this form wants, from what is in it.
    ///
    /// A hand-written uiSchema of four stacked fields asks for one column and
    /// is drawn at very nearly full size in a note; the payload with three
    /// two-column groups asks for two and is scaled down to fit. The form
    /// decides, not the note.
    static func naturalWidth(of form: UISchema.Form) -> CGFloat {
        pad * 2 + column * CGFloat(columns(in: form.root)) 
            + gap * CGFloat(columns(in: form.root) - 1)
    }

    private static func columns(in element: UISchema.Element) -> Int {
        switch element {
        case .horizontal(let children):
            // A row of rows is not six columns wide: what matters is how many
            // fields end up side by side at the widest point.
            return max(1, children.map { max(1, columns(in: $0)) }.reduce(0, +))
        case .vertical(let children):
            return children.map { columns(in: $0) }.max() ?? 1
        case .group(_, let children):
            return children.map { columns(in: $0) }.max() ?? 1
        case .categorization(let categories):
            return categories.flatMap(\.elements).map { columns(in: $0) }.max() ?? 1
        case .control, .note, .unknown:
            return 1
        }
    }

    private static func walk(_ form: UISchema.Form, width: CGFloat, pen: Pen,
                             into shapes: inout [Shape]) -> CGFloat {
        let left = pad
        let inner = width - pad * 2
        var y = pad

        if let title = form.title, !title.isEmpty {
            y += line(title, x: left, y: y, width: inner, font: pen.title,
                      colour: pen.strong, into: &shapes) + 5
        }

        y += place(form.root, x: left, y: y, width: inner, pen: pen, into: &shapes)

        for warning in form.warnings {
            y += 5
            let height = measure(warning, font: pen.small, width: inner - 12)
            shapes.append(.text("⚠︎ " + warning, NSRect(x: left, y: y, width: inner, height: height),
                                pen.small, pen.faint, wrap: true))
            y += height
        }
        return y + pad
    }

    /// Lays one element out at `y` and says how tall it came to.
    private static func place(_ element: UISchema.Element, x: CGFloat, y: CGFloat,
                              width: CGFloat, pen: Pen, into shapes: inout [Shape]) -> CGFloat {
        switch element {

        case .vertical(let children):
            var used: CGFloat = 0
            for (index, child) in children.enumerated() {
                if index > 0 { used += gap }
                used += place(child, x: x, y: y + used, width: width, pen: pen, into: &shapes)
            }
            return used

        case .horizontal(let children):
            guard !children.isEmpty else { return 0 }
            let count = CGFloat(children.count)
            let column = (width - gap * (count - 1)) / count
            // A row that will not fit stacks instead. On a sticky note three
            // columns of 40 pt is not a preview of anything.
            guard column >= Self.column * 0.7 else {
                return place(.vertical(children), x: x, y: y, width: width, pen: pen, into: &shapes)
            }
            var tallest: CGFloat = 0
            for (index, child) in children.enumerated() {
                let left = x + (column + gap) * CGFloat(index)
                tallest = max(tallest, place(child, x: left, y: y, width: column,
                                             pen: pen, into: &shapes))
            }
            return tallest

        case let .group(label, children):
            var used: CGFloat = 0
            if let label, !label.isEmpty {
                used += line(label, x: x + pad, y: y, width: width - pad * 2,
                             font: pen.title, colour: pen.mid, into: &shapes) + 2
            }
            let top = y + used
            // Where the box belongs: after the label, before everything the
            // children are about to add, so its outline sits behind them.
            let behind = shapes.count

            var body: CGFloat = pad
            for (index, child) in children.enumerated() {
                if index > 0 { body += gap }
                body += place(child, x: x + pad, y: top + body,
                              width: width - pad * 2, pen: pen, into: &shapes)
            }
            body += pad

            shapes.insert(.box(NSRect(x: x, y: top, width: width, height: body),
                               radius: 5, fill: nil, stroke: pen.rule, dashed: false),
                          at: behind)
            return used + body

        case .control(let control):
            return field(control, x: x, y: y, width: width, pen: pen, into: &shapes)

        case .note(let text):
            let height = measure(text, font: pen.small, width: width)
            shapes.append(.text(text, NSRect(x: x, y: y, width: width, height: height),
                                pen.small, pen.mid, wrap: true))
            return height

        case .categorization(let categories):
            let tab = pen.label.pointSize * 2.1
            var left = x
            for (index, category) in categories.enumerated() {
                let width = measure(category.label, font: pen.label) + pad * 2
                shapes.append(.box(NSRect(x: left, y: y, width: width, height: tab),
                                   radius: 4, fill: index == 0 ? pen.well : nil,
                                   stroke: pen.rule, dashed: false))
                shapes.append(.text(category.label,
                                    NSRect(x: left + pad, y: centred(pen.label, in: y, height: tab),
                                           width: width - pad * 2, height: pen.label.pointSize * 1.4),
                                    pen.label, index == 0 ? pen.strong : pen.faint, wrap: false))
                left += width + 4
            }
            var used = tab + gap
            // Only the first category: a drawing cannot have a tab pressed, and
            // stacking them all would say the form shows them at once.
            if let first = categories.first {
                used += place(.vertical(first.elements), x: x, y: y + used,
                              width: width, pen: pen, into: &shapes)
            }
            return used

        case .unknown(let type):
            let height = pen.label.pointSize * 2.2
            shapes.append(.box(NSRect(x: x, y: y, width: width, height: height),
                               radius: 4, fill: nil, stroke: pen.attention, dashed: true))
            shapes.append(.text("⚠ " + type,
                                NSRect(x: x + 8, y: centred(pen.label, in: y, height: height),
                                       width: width - 16, height: pen.label.pointSize * 1.4),
                                pen.label, pen.attention, wrap: false))
            return height
        }
    }

    // MARK: - one field

    private static func field(_ control: UISchema.Control, x: CGFloat, y: CGFloat,
                              width: CGFloat, pen: Pen, into shapes: inout [Shape]) -> CGFloat {
        let labelHeight = pen.label.pointSize * 1.5
        let boxHeight = max(20, pen.value.pointSize * 2.1)

        guard let field = control.field else {
            // A scope that resolves to nothing, drawn as the scope itself:
            // that string is the thing that has to change.
            _ = line(control.name.isEmpty ? "Control" : control.name, x: x, y: y,
                     width: width, font: pen.label, colour: pen.attention, into: &shapes)
            let box = NSRect(x: x, y: y + labelHeight, width: width, height: boxHeight)
            shapes.append(.box(box, radius: 4, fill: nil, stroke: pen.attention, dashed: true))
            shapes.append(.text(control.scope.isEmpty ? "no scope" : control.scope,
                                NSRect(x: box.minX + 7, y: centred(pen.small, in: box.minY, height: boxHeight),
                                       width: box.width - 26, height: pen.small.pointSize * 1.4),
                                pen.small, pen.attention, wrap: false))
            // Read-only fields are dashed as well, so without a colour of its
            // own this needs a mark to tell them apart.
            shapes.append(.text("⚠", NSRect(x: box.maxX - 18,
                                            y: centred(pen.small, in: box.minY, height: boxHeight),
                                            width: 14, height: pen.small.pointSize * 1.4),
                                pen.small, pen.attention, wrap: false))
            return labelHeight + boxHeight
        }

        var caption = field.title
        if field.isRequired { caption += " *" }
        _ = line(caption, x: x, y: y, width: width, font: pen.label,
                 colour: field.isHidden ? pen.faint : pen.mid, into: &shapes)

        let box = NSRect(x: x, y: y + labelHeight, width: width, height: boxHeight)
        let kind = field.type ?? "string"

        if kind == "boolean" {
            // A checkbox is the shape of the field, not a well with a tick in
            // it.
            let side = pen.value.pointSize * 1.15
            shapes.append(.box(NSRect(x: box.minX, y: box.midY - side / 2, width: side, height: side),
                               radius: 3, fill: pen.well, stroke: pen.rule, dashed: false))
            shapes.append(.text(field.isReadOnly ? "read only" : "off",
                                NSRect(x: box.minX + side + 6,
                                       y: centred(pen.small, in: box.minY, height: boxHeight),
                                       width: box.width - side - 6, height: pen.small.pointSize * 1.4),
                                pen.small, pen.faint, wrap: false))
            return labelHeight + boxHeight
        }

        // Read-only is drawn as a well that is not filled in, with a dashed
        // edge: the field is there, and nothing goes into it.
        shapes.append(.box(box, radius: 4, fill: field.isReadOnly ? nil : pen.well,
                           stroke: pen.rule, dashed: field.isReadOnly))

        // What sits inside says what kind of field it is, in the schema's own
        // words: the type, or the choices when it has them.
        var hint = field.choices.isEmpty ? kind : field.choices.prefix(3).joined(separator: " · ")
        if field.choices.count > 3 { hint += " …" }
        if field.isHidden { hint = "hidden" }
        let room = field.choices.isEmpty ? box.width - 14 : box.width - 26
        shapes.append(.text(hint, NSRect(x: box.minX + 7,
                                         y: centred(pen.small, in: box.minY, height: boxHeight),
                                         width: max(10, room), height: pen.small.pointSize * 1.4),
                            pen.small, pen.faint, wrap: false))

        if !field.choices.isEmpty {
            shapes.append(.text("▾", NSRect(x: box.maxX - 16,
                                            y: centred(pen.small, in: box.minY, height: boxHeight),
                                            width: 12, height: pen.small.pointSize * 1.4),
                                pen.small, pen.faint, wrap: false))
        }

        // The description under the field, the way JSONForms renders it — one
        // line, cut. It is the half of the schema that says what the field is
        // *for*, and a wireframe of fourteen wells all saying "string" is a
        // picture of the layout and of nothing else.
        guard let detail = field.detail, !detail.isEmpty else {
            return labelHeight + boxHeight
        }
        let help = pen.small.pointSize * 1.5
        shapes.append(.text(detail, NSRect(x: box.minX + 1, y: box.maxY + 2,
                                           width: box.width - 2, height: help),
                            pen.small, pen.faint, wrap: false))
        return labelHeight + boxHeight + help + 2
    }

    // MARK: - small helpers

    /// One line of text, cut rather than wrapped. Returns its height.
    @discardableResult
    private static func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                             font: NSFont, colour: NSColor, into shapes: inout [Shape]) -> CGFloat {
        let height = font.pointSize * 1.45
        shapes.append(.text(text, NSRect(x: x, y: y, width: width, height: height),
                            font, colour, wrap: false))
        return height
    }

    /// The y that puts one line of `font` in the middle of a box.
    private static func centred(_ font: NSFont, in top: CGFloat, height: CGFloat) -> CGFloat {
        top + (height - font.pointSize * 1.4) / 2
    }

    private static func measure(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(20, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .paragraphStyle: style])
        return ceil(rect.height) + 2
    }

    private static func measure(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
