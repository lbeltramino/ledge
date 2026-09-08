import Foundation
import Compression

/// A minimal ZIP container, so a `.ledge` archive is a real zip anyone can
/// double-click in the Finder rather than a private blob.
///
/// Writes stored (uncompressed) entries — notes are small, and it keeps the
/// writer honest. Reads both stored and deflated entries, so an archive that has
/// been through Finder or another tool still imports.
public enum Zip {

    public struct Entry: Sendable, Equatable {
        public var name: String
        public var data: Data
        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public enum Failure: Error, Equatable {
        case notAnArchive
        case unsupportedCompression(UInt16)
        case corrupt(String)
    }

    // MARK: - writing

    public static func archive(_ entries: [Entry]) -> Data {
        var payload = Data()
        var central = Data()

        for entry in entries {
            let name = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(payload.count)

            payload.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            payload.append(contentsOf: uint16(20))              // version needed
            payload.append(contentsOf: uint16(0))               // flags
            payload.append(contentsOf: uint16(0))               // stored
            payload.append(contentsOf: uint16(0))               // mod time
            payload.append(contentsOf: uint16(0x21))            // mod date (1 Jan 1980)
            payload.append(contentsOf: uint32(crc))
            payload.append(contentsOf: uint32(UInt32(entry.data.count)))
            payload.append(contentsOf: uint32(UInt32(entry.data.count)))
            payload.append(contentsOf: uint16(UInt16(name.count)))
            payload.append(contentsOf: uint16(0))               // extra
            payload.append(contentsOf: name)
            payload.append(entry.data)

            central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            central.append(contentsOf: uint16(20))              // version made by
            central.append(contentsOf: uint16(20))              // version needed
            central.append(contentsOf: uint16(0))
            central.append(contentsOf: uint16(0))
            central.append(contentsOf: uint16(0))
            central.append(contentsOf: uint16(0x21))
            central.append(contentsOf: uint32(crc))
            central.append(contentsOf: uint32(UInt32(entry.data.count)))
            central.append(contentsOf: uint32(UInt32(entry.data.count)))
            central.append(contentsOf: uint16(UInt16(name.count)))
            central.append(contentsOf: uint16(0))               // extra
            central.append(contentsOf: uint16(0))               // comment
            central.append(contentsOf: uint16(0))               // disk
            central.append(contentsOf: uint16(0))               // internal attrs
            central.append(contentsOf: uint32(0))               // external attrs
            central.append(contentsOf: uint32(offset))
            central.append(contentsOf: name)
        }

        var out = payload
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        out.append(contentsOf: uint16(0))
        out.append(contentsOf: uint16(0))
        out.append(contentsOf: uint16(UInt16(entries.count)))
        out.append(contentsOf: uint16(UInt16(entries.count)))
        out.append(contentsOf: uint32(UInt32(central.count)))
        out.append(contentsOf: uint32(centralOffset))
        out.append(contentsOf: uint16(0))
        return out
    }

    // MARK: - reading

    public static func entries(of data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { throw Failure.notAnArchive }

        let count = Int(read16(bytes, eocd + 10))
        var offset = Int(read32(bytes, eocd + 16))
        var entries: [Entry] = []

        for _ in 0..<count {
            guard offset + 46 <= bytes.count,
                  read32(bytes, offset) == 0x02014b50 else { throw Failure.corrupt("central directory") }
            let method = read16(bytes, offset + 10)
            let compressed = Int(read32(bytes, offset + 20))
            let uncompressed = Int(read32(bytes, offset + 24))
            let nameLength = Int(read16(bytes, offset + 28))
            let extraLength = Int(read16(bytes, offset + 30))
            let commentLength = Int(read16(bytes, offset + 32))
            let localOffset = Int(read32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.corrupt("entry name") }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)

            guard localOffset + 30 <= bytes.count,
                  read32(bytes, localOffset) == 0x04034b50 else { throw Failure.corrupt("local header") }
            let localNameLength = Int(read16(bytes, localOffset + 26))
            let localExtraLength = Int(read16(bytes, localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start + compressed <= bytes.count else { throw Failure.corrupt("entry data") }
            let raw = Data(bytes[start..<(start + compressed)])

            switch method {
            case 0:
                entries.append(Entry(name: name, data: raw))
            case 8:
                entries.append(Entry(name: name, data: try inflate(raw, capacity: uncompressed)))
            default:
                throw Failure.unsupportedCompression(method)
            }

            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ data: Data, capacity: Int) throws -> Data {
        guard capacity > 0 else { return Data() }
        var out = Data(count: capacity)
        let written: Int = out.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw Failure.corrupt("deflate stream") }
        return out.prefix(written)
    }

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var i = bytes.count - 22
        let limit = max(0, bytes.count - 22 - 65_535)
        while i >= limit {
            if read32(bytes, i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - bytes

    private static func uint16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8)] }
    private static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }
    private static func read16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at + 1 < bytes.count else { return 0 }
        return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }
    private static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 3 < bytes.count else { return 0 }
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
             | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }

    static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
