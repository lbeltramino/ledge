import AppKit
import LedgeCore
import LedgeIndex

/// Renders the deck to PNG files without a screen.
///
/// These are not mockups: the tabs, the card and the pill are the same views the
/// app runs, laid out and drawn into a bitmap. Anything that changes in the
/// drawing code changes here too, which is the only way an image in a README
/// stays true. Run with `--render <directory>`.
@MainActor
enum Renderer {

    struct Sample {
        let title: String
        let color: NoteColor
        let body: String
    }

    static let samples: [Sample] = [
        Sample(title: "Office", color: .blue,
               body: "- understand all the apis listed\n- create tickets for #prd"),
        Sample(title: "Groceries", color: .green,
               body: "- apple\n- 4x banana\n- dry fruits\n- peanuts"),
        Sample(title: "Hold my lid", color: .lavender, body: "- work on the clamshell"),
        Sample(title: "Side-projects", color: .butter,
               body: "- learn about the deck\n- `swift run ledge-tests`"),
    ]

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        write(deck(state: .rest), to: directory.appendingPathComponent("deck-rest.png"))
        write(deck(state: .fanned), to: directory.appendingPathComponent("deck-fanned.png"))
        write(deck(state: .open), to: directory.appendingPathComponent("deck-open.png"))
        write(palette(), to: directory.appendingPathComponent("palette.png"))
        print("rendered 4 images into \(directory.path)")
    }

    enum DeckState { case rest, fanned, open }

    // MARK: - the deck, on a desktop

    static func deck(state: DeckState) -> NSImage {
        // At rest the deck is a 16 pt stripe. Shown at full width it is honest
        // and invisible, so that one frame is a closer crop.
        let size = state == .rest
            ? NSSize(width: 360, height: 360)
            : NSSize(width: 640, height: 640)
        return image(size: size) { context in
            wallpaper(in: NSRect(origin: .zero, size: size))

            let records = samples.enumerated().map { index, sample -> NoteRecord in
                var note = Note(title: sample.title, color: sample.color,
                                rank: "a\(index)")
                note.body = sample.body
                return NoteRecord(note: note, filename: "\(sample.title).md",
                                  mtime: 0, size: 0, hash: "")
            }

            switch state {
            case .rest:
                drawPill(records: records, in: size)
            case .fanned:
                drawTabs(records: records, in: size, opening: nil, context: context)
            case .open:
                drawTabs(records: records, in: size, opening: 1, context: context)
            }
        }
    }

    private static func wallpaper(in rect: NSRect) {
        let gradient = NSGradient(colors: [
            .srgb(0x6E74B4), .srgb(0x7C6FA8), .srgb(0xC9557E),
        ], atLocations: [0, 0.45, 1], colorSpace: .sRGB)
        gradient?.draw(in: rect, angle: -58)

        // a soft band, so the paper has something to sit against
        NSColor.white.withAlphaComponent(0.07).setFill()
        let band = NSBezierPath()
        band.move(to: NSPoint(x: 0, y: rect.height * 0.34))
        band.curve(to: NSPoint(x: rect.width, y: rect.height * 0.72),
                   controlPoint1: NSPoint(x: rect.width * 0.4, y: rect.height * 0.1),
                   controlPoint2: NSPoint(x: rect.width * 0.7, y: rect.height * 0.9))
        band.line(to: NSPoint(x: rect.width, y: rect.height))
        band.line(to: NSPoint(x: 0, y: rect.height))
        band.close()
        band.fill()
    }

    private static func drawPill(records: [NoteRecord], in size: NSSize) {
        let height = PillView.height(for: records.count)
        // Drawn straight into the image: the pill's backing is translucent, and
        // a bitmap cache flattens that against whatever it started as.
        PillView.render(colors: records.map(\.color),
                        in: NSRect(x: size.width - Metrics.Pill.visibleWidth,
                                   y: (size.height - height) / 2,
                                   width: Metrics.Pill.visibleWidth, height: height),
                        topDown: false)
    }

    private static func drawTabs(records: [NoteRecord], in size: NSSize,
                                 opening: Int?, context: NSGraphicsContext) {
        let heights = records.map { NoteTabView.naturalHeight(for: $0.displayTitle) }

        // Lay the stack out from zero, measure what it came to, then centre it.
        // Guessing the total up front is how it ended up hanging off both edges.
        var frames: [NSRect] = []
        var cursor: CGFloat = 0
        for (index, record) in records.enumerated() {
            let jitter = Jitter(id: record.id)
            if index > 0 { cursor -= CGFloat(jitter.tabOverlap) }
            let poke = CGFloat(jitter.tabProtrusion)
            frames.append(NSRect(x: size.width - Metrics.Tab.width - poke, y: cursor,
                                 width: Metrics.Tab.width + poke, height: heights[index]))
            cursor += heights[index]
        }
        let offset = (size.height - cursor) / 2
        frames = frames.map { $0.offsetBy(dx: 0, dy: offset) }

        for (index, record) in records.enumerated() where index != opening {
            let tab = NoteTabView(record: record)
            tab.appearance = NSAppearance(named: .aqua)
            tab.frame = NSRect(origin: .zero, size: frames[index].size)
            // the lean is a layer transform in the app; here it is the context
            drawRotated(tab, at: flip(frames[index], in: size),
                        by: -Jitter(id: record.id).tabRotation)
        }

        guard let opening else { return }
        let record = records[opening]
        let jitter = Jitter(id: record.id)
        let card = NoteCardView(record: record, body: record.snippet)
        card.appearance = NSAppearance(named: .aqua)
        let cardSize = NSSize(width: 300, height: 210)
        card.frame = NSRect(origin: .zero, size: cardSize)
        card.textView.string = samples[opening].body
        card.applyColors()
        card.layoutSubtreeIfNeeded()

        let tabFrame = frames[opening]
        let placed = NSRect(x: size.width - cardSize.width + Metrics.Card.overhang,
                            y: tabFrame.midY - cardSize.height / 2,
                            width: cardSize.width, height: cardSize.height)
        drawRotated(card, at: flip(placed, in: size), by: -jitter.cardRotation, shadow: true)
    }

    // MARK: - the palette

    static func palette() -> NSImage {
        let swatch = NSSize(width: 150, height: 108)
        let gap: CGFloat = 12
        let size = NSSize(width: (swatch.width + gap) * CGFloat(NoteColor.allCases.count) - gap + 40,
                          height: swatch.height + 40)
        return image(size: size) { _ in
            NSColor.srgb(0x1A1D26).setFill()
            NSRect(origin: .zero, size: size).fill()

            for (index, color) in NoteColor.allCases.enumerated() {
                let box = NSRect(x: 20 + (swatch.width + gap) * CGFloat(index), y: 20,
                                 width: swatch.width, height: swatch.height)
                Palette.paper(color, dark: false).setFill()
                NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: VerticalLabel.font(size: 12),
                    .foregroundColor: Palette.labelInk(color),
                    .kern: 1.0,
                ]
                let name = color.rawValue.uppercased() as NSString
                name.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 14), withAttributes: attributes)

                let body = "Aa" as NSString
                body.draw(at: NSPoint(x: box.minX + 14, y: box.maxY - 46), withAttributes: [
                    .font: Typography.noteBody(size: 30),
                    .foregroundColor: Palette.ink(dark: false),
                ])
            }
        }
    }

    // MARK: - drawing plumbing

    private static func image(size: NSSize, _ body: (NSGraphicsContext) -> Void) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        // README images are of the light papers whatever this machine is set to.
        let previous = NSAppearance.currentDrawing()
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            if let context = NSGraphicsContext.current { body(context) }
        }
        previous.performAsCurrentDrawingAppearance {}
        image.unlockFocus()
        return image
    }

    /// Layout is worked out top-down, like the app's own flipped views; the
    /// image context runs bottom-up. Converting at the moment of drawing keeps
    /// the maths readable and stops the bitmaps coming out mirrored.
    private static func flip(_ frame: NSRect, in size: NSSize) -> NSRect {
        NSRect(x: frame.minX, y: size.height - frame.maxY,
               width: frame.width, height: frame.height)
    }

    private static func draw(_ view: NSView, at origin: NSPoint) {
        // A view resolves its colours from its own appearance, not from whatever
        // the drawing context is set to — so a Mac in dark mode was rendering
        // dark green paper into the README.
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }

        // cacheDisplay does not clear the rep first, so a translucent view —
        // the pill's smoked backing, for one — comes out over whatever was in
        // the buffer. Clear it to transparent first.
        if let scratch = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = scratch
            scratch.compositingOperation = .copy
            NSColor.clear.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        view.cacheDisplay(in: view.bounds, to: rep)
        rep.draw(in: NSRect(origin: origin, size: view.bounds.size))
    }

    /// Applies the lean the app applies with a layer transform.
    private static func drawRotated(_ view: NSView, at frame: NSRect, by degrees: Double,
                                    shadow: Bool = false) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        if shadow {
            let drop = NSShadow()
            drop.shadowColor = NSColor.black.withAlphaComponent(0.34)
            drop.shadowBlurRadius = 26
            drop.shadowOffset = NSSize(width: -6, height: -8)
            drop.set()
        }
        let transform = NSAffineTransform()
        transform.translateX(by: frame.midX, yBy: frame.midY)
        transform.rotate(byDegrees: CGFloat(degrees))
        transform.concat()
        draw(view, at: NSPoint(x: -frame.width / 2, y: -frame.height / 2))
        context.restoreGraphicsState()
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
