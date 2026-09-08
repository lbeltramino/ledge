import Foundation
import CryptoKit

/// Every read and write goes through `NSFileCoordinator` — not only when the
/// folder lives in iCloud Drive, so that nothing has to change the day the user
/// drags it there. Writes land atomically: temp file in the same directory,
/// then a replace. There is never a half-written note on disk.
public enum FileIO {

    public struct Stamp: Sendable, Equatable {
        public var mtime: Double
        public var size: Int
        public var hash: String
    }

    public struct Loaded: Sendable {
        public var text: String
        public var stamp: Stamp
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func stamp(of url: URL, text: String) -> Stamp {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? text.utf8.count
        return Stamp(mtime: mtime, size: size, hash: hash(text))
    }

    public static func read(_ url: URL) throws -> Loaded {
        var coordinationError: NSError?
        var result: Result<Loaded, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
            do {
                let data = try Data(contentsOf: actual)
                let text = String(decoding: data, as: UTF8.self)
                result = .success(Loaded(text: text, stamp: stamp(of: actual, text: text)))
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> Stamp {
        var coordinationError: NSError?
        var result: Result<Stamp, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { actual in
            do {
                let dir = actual.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let temp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
                try Data(text.utf8).write(to: temp, options: .atomic)
                if FileManager.default.fileExists(atPath: actual.path) {
                    _ = try FileManager.default.replaceItemAt(actual, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: actual)
                }
                result = .success(stamp(of: actual, text: text))
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    public static func move(from: URL, to: URL) throws {
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: from, options: .forMoving,
                                                          writingItemAt: to, options: .forReplacing,
                                                          error: &coordinationError) { src, dst in
            do { try FileManager.default.moveItem(at: src, to: dst) } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    public static func remove(_ url: URL) throws {
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { actual in
            do { try FileManager.default.removeItem(at: actual) } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown, (thrown as NSError).code != NSFileNoSuchFileError { throw thrown }
    }

    /// Note files in a folder, ignoring dotfiles and the index itself.
    public static func noteFilenames(in folder: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return names
            .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md") }
            .sorted()
    }
}
