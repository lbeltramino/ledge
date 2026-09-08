import Foundation
import LedgeCore

/// The four ways a note leaves Ledge.
///
/// Three of them are lossy on purpose — they exist so other apps can read your
/// notes. The fourth, `.ledge`, is the folder plus a manifest, and comes back
/// with colours, states, tags and dates exactly as they went out.
public enum ExportFormat: String, Sendable, CaseIterable {
    case markdown
    case plainText
    case singleFile
    case archive

    public var name: String {
        switch self {
        case .markdown:   return "Markdown"
        case .plainText:  return "Plain text"
        case .singleFile: return "Single file"
        case .archive:    return "Ledge archive"
        }
    }

    public var detail: String {
        switch self {
        case .markdown:   return "One .md per note, without frontmatter"
        case .plainText:  return "One .txt per note"
        case .singleFile: return "Every note in one .md"
        case .archive:    return "A .ledge that imports back exactly"
        }
    }

    /// Whether the result is one file or a folder full of them.
    public var isSingleFile: Bool { self == .singleFile || self == .archive }
}

public enum Exporter {

    public static let archiveExtension = "ledge"
    public static let manifestName = "manifest.json"
    public static let formatVersion = 1

    public struct File: Sendable, Equatable {
        public var name: String
        public var contents: Data
    }

    // MARK: - the lossy three

    /// Frontmatter stripped, title promoted to an H1. For other apps.
    public static func markdown(_ note: Note) -> File {
        var text = ""
        if !note.title.isEmpty { text += "# \(note.title)\n\n" }
        text += note.body
        if !text.hasSuffix("\n") { text += "\n" }
        return File(name: unique(Filename.base(for: note.displayTitle), "md"),
                    contents: Data(text.utf8))
    }

    public static func plainText(_ note: Note) -> File {
        var text = note.displayTitle + "\n\n" + note.body
        if !text.hasSuffix("\n") { text += "\n" }
        return File(name: unique(Filename.base(for: note.displayTitle), "txt"),
                    contents: Data(text.utf8))
    }

    public static func singleFile(_ notes: [Note]) -> File {
        let body = notes.map { note -> String in
            var section = "## \(note.displayTitle)\n\n"
            section += note.body
            if !section.hasSuffix("\n") { section += "\n" }
            return section
        }.joined(separator: "\n---\n\n")
        return File(name: "Notes.md", contents: Data(body.utf8))
    }

    // MARK: - the lossless one

    /// The notes exactly as they sit on disk, plus a manifest. Nearly free: they
    /// are already Markdown files, so the archive is the folder.
    public static func archive(_ notes: [Note]) -> Data {
        var entries: [Zip.Entry] = []
        var taken = Set<String>()
        for note in notes {
            let name = Filename.unique(for: note.displayTitle, taken: taken)
            taken.insert(name.lowercased())
            entries.append(Zip.Entry(name: "notes/" + name,
                                     data: Data(Frontmatter.serialize(note).utf8)))
        }
        let manifest: [String: Any] = [
            "format": "ledge",
            "version": formatVersion,
            "exported": Frontmatter.string(from: Date()),
            "count": notes.count,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            entries.append(Zip.Entry(name: manifestName, data: data))
        }
        return Zip.archive(entries)
    }

    public enum ImportFailure: Error, Equatable {
        case notALedgeArchive
        case noNotesInside
    }

    /// Reads an archive back. Notes keep their colours, states, tags and dates;
    /// deciding what to do about ids that already exist is the store's job.
    public static func read(archive data: Data) throws -> [Note] {
        let entries: [Zip.Entry]
        do { entries = try Zip.entries(of: data) }
        catch { throw ImportFailure.notALedgeArchive }

        let notes = entries
            .filter { $0.name.lowercased().hasSuffix(".md") && !$0.name.hasPrefix("__MACOSX") }
            .map { entry -> Note in
                let filename = (entry.name as NSString).lastPathComponent
                return Frontmatter.parse(String(decoding: entry.data, as: UTF8.self),
                                         fallbackTitle: (filename as NSString).deletingPathExtension)
            }
        guard !notes.isEmpty else { throw ImportFailure.noNotesInside }
        return notes
    }

    // MARK: - files for a format

    public static func files(for format: ExportFormat, notes: [Note]) -> [File] {
        switch format {
        case .markdown:   return deduplicated(notes.map(markdown))
        case .plainText:  return deduplicated(notes.map(plainText))
        case .singleFile: return [singleFile(notes)]
        case .archive:    return [File(name: "Notes.\(archiveExtension)", contents: archive(notes))]
        }
    }

    private static func unique(_ base: String, _ ext: String) -> String { "\(base).\(ext)" }

    /// Two notes may share a title; two files may not share a name.
    private static func deduplicated(_ files: [File]) -> [File] {
        var taken = Set<String>()
        return files.map { file in
            let base = (file.name as NSString).deletingPathExtension
            let ext = (file.name as NSString).pathExtension
            var name = file.name
            var n = 2
            while taken.contains(name.lowercased()) {
                name = "\(base) \(n).\(ext)"
                n += 1
            }
            taken.insert(name.lowercased())
            return File(name: name, contents: file.contents)
        }
    }
}
