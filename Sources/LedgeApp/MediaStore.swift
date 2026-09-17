import AppKit
import CoreGraphics
import ImageIO
import LedgeCore
import Mermaid

/// Turns what a note points at into something the right size to draw, and
/// remembers it so scrolling is not decoding.
///
/// The whole cost of pictures is here. A decoded image costs `width × height ×
/// 4` bytes no matter what the file weighs — a 4000×3000 photo is 48 MB in
/// memory and 1.9 MB at the width a note actually draws it. So nothing is ever
/// decoded at its own size: the file's dimensions are read from its header,
/// the display size is worked out from those, and ImageIO is asked for a
/// thumbnail of exactly that many pixels. The full-size bitmap never exists.
@MainActor
enum MediaStore {

    /// The tallest a picture may be drawn, so one photograph cannot take over
    /// a note. Wider than this it scales down; taller than this it is fitted.
    static let maximumHeight: CGFloat = 420

    /// What the cache may hold before it starts dropping the least recent.
    /// Twenty-four megabytes is about a dozen full-width pictures — generous
    /// for a deck of sticky notes, and a hard ceiling either way.
    private static let budget = 24 * 1024 * 1024

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = budget
        return cache
    }()

    /// Drops everything. The folder changed under us, or a check wants to
    /// measure a cold read.
    static func empty() { cache.removeAllObjects() }

    /// Where `resources/img/…` is resolved from.
    ///
    /// Set once, when the app learns its notes folder, rather than handed to
    /// each view: a per-view property is one more thing to forget to wire on
    /// the third surface, and forgetting exactly that is how the last feature
    /// shipped broken on notes pulled onto the desk.
    static var notesFolder: URL?

    /// The file a note's markdown points at, or nil if it points outside the
    /// folder — see `Media.isLocal`.
    static func url(for path: String) -> URL? {
        guard let notesFolder, Media.isLocal(path) else { return nil }
        return notesFolder.appendingPathComponent(path)
    }

    // MARK: - keeping a picture

    /// File types worth keeping as they are. Anything else on the clipboard is
    /// written out as a PNG.
    private static let keepable: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"]

    /// The largest edge a picture is kept at.
    ///
    /// A ceiling, not a compression setting. Measured before it was picked: a
    /// full-screen screenshot is 1.6 MB as PNG and 1.2 MB shrunk to 2048 px —
    /// a quarter saved for a real loss of sharpness on text, which is a bad
    /// trade. What this is for is the other case: a twelve-megapixel photograph
    /// that a sticky note will never draw above 800 px. Above 4000 the file is
    /// resized; below it, nothing is touched and a file is copied byte for
    /// byte, because re-encoding somebody's picture is not ours to do.
    static let largestEdge = 4000

    /// Saves whatever picture is on `pasteboard` into the notes folder and
    /// answers the path a note should reference.
    ///
    /// A file that was copied in Finder is copied across untouched — re-encoding
    /// somebody's JPEG to paste it into a note would be a quiet loss. A picture
    /// copied out of an app arrives as pixels, and those are written as PNG.
    static func save(from pasteboard: NSPasteboard) -> String? {
        guard let notesFolder else { return nil }
        let folder = notesFolder.appendingPathComponent(Media.folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let source = urls.first(where: { keepable.contains($0.pathExtension.lowercased()) }) {
            let destination = free(source.deletingPathExtension().lastPathComponent,
                                   extension: source.pathExtension.lowercased(), in: folder)
            guard copy(source, to: destination) else { return nil }
            return "\(Media.folder)/\(destination.lastPathComponent)"
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let data = png(from: capped(image)) else { return nil }
        let destination = free(stamped(), extension: "png", in: folder)
        guard (try? data.write(to: destination)) != nil else { return nil }
        return "\(Media.folder)/\(destination.lastPathComponent)"
    }

    /// Copies a file in, resizing it only if it is enormous. Under the ceiling
    /// the bytes are copied exactly as they are — same format, same quality,
    /// same metadata.
    private static func copy(_ source: URL, to destination: URL) -> Bool {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let size = pixelSize(of: image),
              max(size.width, size.height) > CGFloat(largestEdge) else {
            return (try? FileManager.default.copyItem(at: source, to: destination)) != nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: largestEdge,
        ]
        guard let smaller = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let type = CGImageSourceGetType(image),
              let out = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil)
        else {
            // Anything unexpected and the original goes in untouched: a picture
            // that is too big is a far smaller problem than one that is gone.
            return (try? FileManager.default.copyItem(at: source, to: destination)) != nil
        }
        CGImageDestinationAddImage(out, smaller, nil)
        return CGImageDestinationFinalize(out)
    }

    /// The same ceiling for pixels off the clipboard.
    private static func capped(_ image: NSImage) -> NSImage {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              max(cg.width, cg.height) > largestEdge else { return image }
        let scale = CGFloat(largestEdge) / CGFloat(max(cg.width, cg.height))
        let size = NSSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let smaller = NSImage(size: size)
        smaller.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        smaller.unlockFocus()
        return smaller
    }

    private static func png(from image: NSImage) -> Data? {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// `pasted-20260912-153045`, which sorts and says when.
    private static func stamped() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "pasted-\(formatter.string(from: Date()))"
    }

    /// A name nothing is using. Pasting twice in the same second, or twice from
    /// the same file, must not quietly replace the first one — the note that
    /// pointed at it would change picture underneath you.
    private static func free(_ base: String, extension ext: String, in folder: URL) -> URL {
        let safe = base.isEmpty ? "picture" : base
        var candidate = folder.appendingPathComponent("\(safe).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safe)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - pictures

    /// The picture at `url`, decoded no larger than it will be drawn.
    ///
    /// `available` is the width the note has for it and `scale` the screen's
    /// backing scale, so what comes back is exactly the pixels that will be
    /// put on glass — the number the footprint is made of.
    static func image(at url: URL, available: CGFloat, scale: CGFloat) -> NSImage? {
        let width = max(1, available)
        let backing = max(1, scale)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0?.timeIntervalSince1970 } ?? 0
        // The mtime is in the key so editing a picture in place shows the new
        // one rather than the one we happened to decode first.
        let key = "img|\(url.path)|\(stamp)|\(Int(width))|\(Int(backing))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let size = pixelSize(of: source) else { return nil }

        let fitted = fit(size, into: width)
        // The longest edge in pixels, which is what ImageIO's thumbnail limit
        // means. Asking for the fitted size in points instead would hand back a
        // blurry picture on every Mac made in the last decade.
        let longest = Int((max(fitted.width, fitted.height) * backing).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = NSImage(cgImage: thumb, size: fitted)
        cache.setObject(image, forKey: key, cost: thumb.height * thumb.bytesPerRow)
        return image
    }

    /// What a picture will be drawn at, given the room. Never upscaled: a small
    /// screenshot blown up to the width of a note looks like a mistake.
    static func fit(_ size: CGSize, into available: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(available / size.width, maximumHeight / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(),
                      height: (size.height * scale).rounded())
    }

    /// The file's own dimensions, read from its header. No pixels are decoded
    /// to answer this, which is the point of asking.
    static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        // A photograph carries its rotation in EXIF rather than its pixels.
        switch properties[kCGImagePropertyOrientation] as? Int {
        case 5, 6, 7, 8: return CGSize(width: height, height: width)
        default: return CGSize(width: width, height: height)
        }
    }

    // MARK: - diagrams

    /// A mermaid block, laid out and drawn by swift-mermaid and rasterised at
    /// the size it will appear.
    ///
    /// Same bargain as a picture: the diagram is drawn once at the pixels it
    /// needs rather than kept as a texture to be scaled. Re-drawing it costs a
    /// couple of milliseconds, so the cache is about scrolling, not about
    /// whether this is affordable.
    static func diagram(_ source: String, available: CGFloat, scale: CGFloat,
                        dark: Bool) -> NSImage? {
        let width = max(1, available)
        let backing = max(1, scale)
        let key = "mmd|\(dark)|\(Int(width))|\(Int(backing))|\(source.hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let scene = try? Mermaid.render(source, theme: dark ? .dark : .default),
              scene.size.width > 0, scene.size.height > 0 else { return nil }

        let fitted = fit(scene.size, into: width)
        guard fitted.width > 0 else { return nil }
        // `cgImage(scale:)` multiplies the scene's own size, so the factor that
        // lands it on the fitted size at this screen's density is both together.
        let factor = (fitted.width / scene.size.width) * backing
        guard let raster = scene.cgImage(scale: factor) else { return nil }

        let image = NSImage(cgImage: raster, size: fitted)
        cache.setObject(image, forKey: key, cost: raster.height * raster.bytesPerRow)
        return image
    }

    /// The diagram at its own size, for the clipboard.
    ///
    /// Not the one on screen: that is fitted to the width of a sticky note, and
    /// pasting it into anything else should give the diagram, at a density that
    /// survives being looked at.
    static func diagramForCopying(_ source: String, dark: Bool) -> NSImage? {
        guard let scene = try? Mermaid.render(source, theme: dark ? .dark : .default),
              scene.size.width > 0, scene.size.height > 0,
              let raster = scene.cgImage(scale: 2) else { return nil }
        return NSImage(cgImage: raster, size: scene.size)
    }

    /// Whether a block of mermaid says something this can draw, without drawing
    /// it — for telling "not a diagram yet" from "a diagram that failed".
    static func canDraw(_ source: String) -> Bool {
        (try? Mermaid.render(source)) != nil
    }

    // MARK: - forms

    /// A JSONForms uiSchema drawn as the form it describes, at the width it
    /// will appear. Cached on everything the drawing depends on, because this
    /// is asked for again on every relayout of the note.
    static func form(_ source: String, available: CGFloat, scale: CGFloat,
                     ink: NSColor, font: NSFont) -> NSImage? {
        guard let form = UISchema.find(in: source) else { return nil }
        let width = max(1, available)
        let backing = max(1, scale)
        let key = "form|\(Int(width))|\(Int(backing))|\(Int(font.pointSize * 10))"
            + "|\(ink.hashValue)|\(source.hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let image = FormDraw.image(form, available: width, scale: backing,
                                         ink: ink, font: font) else { return nil }
        cache.setObject(image, forKey: key,
                        cost: Int(image.size.width * backing * image.size.height * backing * 4))
        return image
    }

    /// The form at a size worth pasting into a ticket, rather than at the width
    /// of a sticky note. Same bargain as `diagramForCopying`.
    static func formForCopying(_ source: String, ink: NSColor, font: NSFont) -> NSImage? {
        guard let form = UISchema.find(in: source) else { return nil }
        return FormDraw.image(form, available: 620, scale: 2, ink: ink, font: font)
    }
}
