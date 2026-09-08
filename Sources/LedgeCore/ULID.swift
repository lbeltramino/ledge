import Foundation

/// Crockford base-32 ULID: 48-bit millisecond timestamp + 80 bits of randomness,
/// rendered as 26 characters that sort lexicographically by creation time.
public enum ULID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate(date: Date = Date()) -> String {
        var out = ""
        out.reserveCapacity(26)

        var ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var timeChars = [Character](repeating: "0", count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            timeChars[i] = alphabet[Int(ms & 0x1F)]
            ms >>= 5
        }
        out.append(contentsOf: timeChars)

        var rng = SystemRandomNumberGenerator()
        for _ in 0..<16 {
            out.append(alphabet[Int.random(in: 0..<32, using: &rng)])
        }
        return out
    }

    public static func isValid(_ s: String) -> Bool {
        s.count == 26 && s.allSatisfy { alphabet.contains($0) }
    }
}
