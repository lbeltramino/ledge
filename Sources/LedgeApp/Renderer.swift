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

    /// Every size an .iconset wants, named the way iconutil expects.
    static func renderIconSet(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2),
                                   (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
        for (point, scale) in sizes {
            let pixels = CGFloat(point * scale)
            let name = scale == 1 ? "icon_\(point)x\(point).png" : "icon_\(point)x\(point)@2x.png"
            write(icon(size: pixels), to: directory.appendingPathComponent(name))
        }
        print("rendered \(sizes.count) icon sizes into \(directory.path)")
    }

    /// A card showing the syntax, for looking at what the marker stroke does.
    static func syntax() -> NSImage {
        let size = NSSize(width: 430, height: 400)
        return image(size: size) { _ in
            var note = Note(title: "Groceries", color: .green)
            note.body = """
            # Shopping
            Bring the ==reusable bags== this time.

            - [x] bread and butter
            - [ ] call the #plumber
            - [ ] see [[Office]]

            ```swift
            let answer = 42
            ```
            """
            let record = NoteRecord(note: note, filename: "Groceries.md",
                                    mtime: 0, size: 0, hash: "")
            let card = NoteCardView(record: record, body: note.body)
            card.appearance = NSAppearance(named: .aqua)
            card.frame = NSRect(origin: .zero, size: size)
            card.textView.string = note.body
            card.applyColors()
            draw(card, at: .zero)
        }
    }

    /// A project: the mother, with what she keeps along the bottom.
    static func project() -> NSImage {
        let size = NSSize(width: 430, height: 330)
        return image(size: size) { _ in
            var note = Note(title: "Bedrock en el IDP", color: .butter)
            note.body = """
            La idea es exponerlo como una dependencia más,
            no como un servicio aparte.

            - [x] hablar con seguridad
            - [/] escribir el módulo
            - [ ] medir la latencia

            El detalle está en [[Modelo de permisos]].
            """
            let record = NoteRecord(note: note, filename: "Bedrock en el IDP.md",
                                    mtime: 0, size: 0, hash: "")
            let card = NoteCardView(record: record, body: note.body)
            card.appearance = NSAppearance(named: .aqua)
            card.frame = NSRect(origin: .zero, size: size)
            card.textView.string = note.body

            let hijas = ["Modelo de permisos": NoteColor.blue,
                         "Terraform del gateway": .green,
                         "Pruebas de carga": .lavender]
            let registros = hijas.map { nombre, color -> NoteRecord in
                var hija = Note(title: nombre, color: color)
                hija.parent = note.id
                return NoteRecord(note: hija, filename: "\(nombre).md", mtime: 0, size: 0, hash: "")
            }.sorted { $0.title < $1.title }
            card.family.show(children: registros, mother: nil, isOnStrip: false)
            card.applyColors()
            draw(card, at: .zero)
        }
    }

    /// Linking as you type: the notes you could mean, and the one you would make.
    static func linking() -> NSImage {
        let size = NSSize(width: 430, height: 300)
        return image(size: size) { _ in
            var note = Note(title: "Incidente 4/9", color: .coral)
            note.body = """
            21:04 alertó la latencia del gateway.
            21:11 rollback del ESM.

            Ver [[perm
            """
            let record = NoteRecord(note: note, filename: "Incidente.md",
                                    mtime: 0, size: 0, hash: "")
            let card = NoteCardView(record: record, body: note.body)
            card.appearance = NSAppearance(named: .aqua)
            card.frame = NSRect(origin: .zero, size: size)
            card.textView.string = note.body
            card.applyColors()
            card.layoutSubtreeIfNeeded()

            let view = card.textView
            view.titlesForLinking = { ["Modelo de permisos", "Permisos de KMS", "Office"] }
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.offerLinks()
            card.layoutSubtreeIfNeeded()
            draw(card, at: .zero)
        }
    }

    /// A diagram in a note: the fence still there, the drawing under it.
    static func diagram() -> NSImage {
        let size = NSSize(width: 430, height: 385)
        return image(size: size) { _ in
            var note = Note(title: "Deploy del gateway", color: .blue)
            note.body = """
            El camino que hace un release:

            ```mermaid
            flowchart LR
              A[push] --> B[CI]
              B --> C{tests}
              C -->|ok| D[deploy]
              C -->|falla| E[rollback]
            ```
            """
            draw(card(note, size: size, filename: "Deploy.md") { card in
                card.textView.refreshMedia()
            }, at: .zero)
        }
    }

    /// A table, drawn — and the note still says pipes and dashes.
    static func table() -> NSImage {
        let size = NSSize(width: 430, height: 235)
        return image(size: size) { _ in
            var note = Note(title: "Capacidad", color: .green)
            note.body = """
            | Servicio | Réplicas | p99 |
            |---|---:|:---:|
            | gateway | 6 | 180 ms |
            | permisos | 3 | 42 ms |
            | billing | 2 | 310 ms |
            """
            draw(card(note, size: size, filename: "Capacidad.md") { card in
                card.textView.refreshTables()
            }, at: .zero)
        }
    }

    /// The headings of a long note, as somewhere to jump.
    static func outline() -> NSImage {
        let size = NSSize(width: 430, height: 300)
        return image(size: size) { _ in
            var note = Note(title: "Runbook del ESM", color: .lavender)
            note.body = """
            # Runbook del ESM

            ## Síntomas
            La latencia del gateway se va por encima de 2 s.

            ## Qué mirar
            ### Métricas
            ### Logs

            ## Rollback
            """
            draw(card(note, size: size, filename: "Runbook.md") { card in
                card.debugOpenOutline()
            }, at: .zero)
        }
    }

    /// A uiSchema in a note, drawn as the form it describes.
    ///
    /// Not in `run` yet: at 430 pt the JSON that defines the form is forty
    /// lines of text and the drawing lands below the bottom of the card. It
    /// becomes a README image the day a fenced block can be folded.
    static func form() -> NSImage {
        let size = NSSize(width: 430, height: 1250)
        return image(size: size) { _ in
            var note = Note(title: "Nueva dependencia", color: .coral)
            note.body = """
            Probando el alta:

            ```json
            {
              "name": "Redis",
              "required": ["cluster"],
              "properties": {
                "cluster": { "type": "string", "title": "Cluster",
                             "description": "Dónde vive la instancia" },
                "tls": { "type": "boolean", "title": "TLS" },
                "tier": { "type": "string", "title": "Tier",
                          "enum": ["cache", "session", "queue"] },
                "eviction": { "type": "string", "title": "Eviction",
                              "readOnly": true }
              },
              "uiSchema": {
                "type": "VerticalLayout",
                "elements": [
                  { "type": "Group", "label": "Conexión", "elements": [
                    { "type": "Control", "scope": "#/properties/cluster" },
                    { "type": "HorizontalLayout", "elements": [
                      { "type": "Control", "scope": "#/properties/tier" },
                      { "type": "Control", "scope": "#/properties/tls" } ] } ] },
                  { "type": "Control", "scope": "#/properties/evicton" }
                ]
              }
            }
            ```
            """
            draw(card(note, size: size, filename: "Redis.md") { card in
                card.textView.refreshMedia()
            }, at: .zero)
        }
    }

    /// A card laid out the way the app lays one out, ready to be drawn.
    ///
    /// The extra pass is not ceremony: tables, drawings and the outline are all
    /// put in place from the text view's layout, so they need the card to have
    /// a size before they are asked for, and a second layout after.
    private static func card(_ note: Note, size: NSSize, filename: String,
                             _ then: (NoteCardView) -> Void = { _ in }) -> NoteCardView {
        let record = NoteRecord(note: note, filename: filename, mtime: 0, size: 0, hash: "")
        let card = NoteCardView(record: record, body: note.body)
        card.appearance = NSAppearance(named: .aqua)
        card.frame = NSRect(origin: .zero, size: size)
        card.textView.string = note.body
        card.applyColors()
        card.layoutSubtreeIfNeeded()
        then(card)
        card.layoutSubtreeIfNeeded()
        return card
    }

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        write(deck(state: .rest), to: directory.appendingPathComponent("deck-rest.png"))
        write(deck(state: .fanned), to: directory.appendingPathComponent("deck-fanned.png"))
        write(deck(state: .open), to: directory.appendingPathComponent("deck-open.png"))
        write(palette(), to: directory.appendingPathComponent("palette.png"))
        write(icon(size: 512), to: directory.appendingPathComponent("icon.png"))
        write(syntax(), to: directory.appendingPathComponent("syntax.png"))
        write(project(), to: directory.appendingPathComponent("project.png"))
        write(linking(), to: directory.appendingPathComponent("linking.png"))
        write(diagram(), to: directory.appendingPathComponent("diagram.png"))
        write(table(), to: directory.appendingPathComponent("table.png"))
        write(outline(), to: directory.appendingPathComponent("outline.png"))
        print("rendered 11 images into \(directory.path)")
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

    // MARK: - the app icon

    /// The mark, drawn at any size.
    ///
    /// Three tabs against a warm ground, sized in proportion rather than in
    /// points so it reads the same at 1024 and at 16 — where the fan, the fold
    /// lines and the titles would all be mud.
    static func icon(size side: CGFloat) -> NSImage {
        image(size: NSSize(width: side, height: side)) { _ in
            let rect = NSRect(x: 0, y: 0, width: side, height: side)
            let unit = side / 512

            // Apple's grille: the artwork sits inside the full canvas with a
            // margin, and the system rounds the corners.
            let plate = rect.insetBy(dx: 42 * unit, dy: 42 * unit)
            let plateRadius = 96 * unit
            NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)
                .addClip()

            let ground = NSGradient(colors: [.srgb(0xFBF9F5), .srgb(0xEFE9DE)],
                                    atLocations: [0, 1], colorSpace: .sRGB)
            ground?.draw(in: plate, angle: -90)

            // Three tabs, flush with the right edge of the plate, each as long
            // as a title would make it.
            let colors: [NoteColor] = [.blue, .green, .butter]
            let lengths: [CGFloat] = [150, 118, 186]
            let tabWidth = 116 * unit
            let gap = 22 * unit
            let total = lengths.reduce(0) { $0 + $1 * unit } + gap * CGFloat(colors.count - 1)
            var top = plate.midY + total / 2

            // The lean is the product's signature; without it this is three
            // rectangles rather than three pieces of paper.
            let leans: [CGFloat] = [-1.1, 0.9, -0.7]

            for (index, color) in colors.enumerated() {
                let length = lengths[index] * unit
                top -= length
                let tab = NSRect(x: plate.maxX - tabWidth, y: top, width: tabWidth + plateRadius,
                                 height: length)
                let radius = 30 * unit

                NSGraphicsContext.current?.saveGraphicsState()
                let lean = NSAffineTransform()
                lean.translateX(by: tab.midX, yBy: tab.midY)
                lean.rotate(byDegrees: side >= 64 ? leans[index] : 0)
                lean.translateX(by: -tab.midX, yBy: -tab.midY)
                lean.concat()

                Palette.paper(color, dark: false).setFill()
                NSBezierPath(roundedRect: tab, xRadius: radius, yRadius: radius).fill()

                // the perforation, only where it can still be seen
                if side >= 128 {
                    let fold = NSBezierPath()
                    let x = tab.minX + 34 * unit
                    fold.move(to: NSPoint(x: x, y: tab.minY + 20 * unit))
                    fold.line(to: NSPoint(x: x, y: tab.maxY - 20 * unit))
                    fold.lineWidth = 3 * unit
                    fold.setLineDash([7 * unit, 9 * unit], count: 2, phase: 0)
                    Palette.labelInk(color).withAlphaComponent(0.38).setStroke()
                    fold.stroke()
                }
                NSGraphicsContext.current?.restoreGraphicsState()
                top -= gap
            }
        }
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
