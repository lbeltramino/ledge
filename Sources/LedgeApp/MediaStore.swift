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
}
