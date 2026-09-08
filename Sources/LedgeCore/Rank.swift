import Foundation

/// Fractional indexing over base-62 strings.
///
/// A rank is `<integer part><fractional part>`; a value can always be minted
/// between two neighbours, so reordering the deck rewrites exactly one file
/// instead of every file below the one that moved.
public enum Rank {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let smallestInteger = "A00000000000000000000000000"

    public enum Failure: Error, Equatable {
        case notOrdered(String, String)
        case malformed(String)
        case exhausted
    }

    /// The rank for the first note in an empty deck.
    public static let initial = "a0"

    public static func between(_ a: String?, _ b: String?) throws -> String {
        if let a, let b, a >= b { throw Failure.notOrdered(a, b) }

        guard let a else {
            guard let b else { return initial }
            let (ib, fb) = try split(b)
            if ib == smallestInteger { return ib + (try midpoint("", fb)) }
            if ib < b { return ib }
            guard let dec = decrement(ib) else { throw Failure.exhausted }
            return dec
        }

        guard let b else {
            let (ia, fa) = try split(a)
            if let inc = increment(ia) { return inc }
            return ia + (try midpoint(fa, nil))
        }

        let (ia, fa) = try split(a)
        let (ib, fb) = try split(b)
        if ia == ib { return ia + (try midpoint(fa, fb)) }
        guard let inc = increment(ia) else { throw Failure.exhausted }
        if inc < b { return inc }
        return ia + (try midpoint(fa, nil))
    }

    /// Ranks for `count` notes appended after `a`, in order.
    public static func sequence(after a: String?, count: Int) throws -> [String] {
        var out: [String] = []
        var cursor = a
        for _ in 0..<count {
            let next = try between(cursor, nil)
            out.append(next)
            cursor = next
        }
        return out
    }

    // MARK: - integer part

    static func integerLength(_ head: Character) throws -> Int {
        guard let a = head.asciiValue else { throw Failure.malformed(String(head)) }
        if head >= "a" && head <= "z" { return Int(a - 97) + 2 }
        if head >= "A" && head <= "Z" { return Int(90 - a) + 2 }
        throw Failure.malformed(String(head))
    }

    static func split(_ key: String) throws -> (integer: String, fraction: String) {
        guard let head = key.first else { throw Failure.malformed(key) }
        let n = try integerLength(head)
        guard key.count >= n else { throw Failure.malformed(key) }
        let idx = key.index(key.startIndex, offsetBy: n)
        return (String(key[key.startIndex..<idx]), String(key[idx...]))
    }

    static func increment(_ int: String) -> String? {
        guard let head = int.first else { return nil }
        var body = Array(int.dropFirst())
        var carry = true
        var i = body.count - 1
        while carry && i >= 0 {
            let next = digits.firstIndex(of: body[i])! + 1
            if next == digits.count { body[i] = digits[0] } else { body[i] = digits[next]; carry = false }
            i -= 1
        }
        guard carry else { return String(head) + String(body) }
        if head == "z" { return nil }
        if head == "Z" { return "a0" }
        let next = Character(UnicodeScalar(head.asciiValue! + 1))
        if next > "a" { body.append(digits[0]) } else { body.removeLast() }
        return String(next) + String(body)
    }

    static func decrement(_ int: String) -> String? {
        guard let head = int.first else { return nil }
        var body = Array(int.dropFirst())
        var borrow = true
        var i = body.count - 1
        while borrow && i >= 0 {
            let cur = digits.firstIndex(of: body[i])!
            if cur == 0 { body[i] = digits[digits.count - 1] } else { body[i] = digits[cur - 1]; borrow = false }
            i -= 1
        }
        guard borrow else { return String(head) + String(body) }
        if head == "A" { return nil }
        if head == "a" { return "Z" + String(repeating: String(digits[digits.count - 1]), count: 1) }
        let next = Character(UnicodeScalar(head.asciiValue! - 1))
        if next < "Z" { body.append(digits[digits.count - 1]) } else { body.removeLast() }
        return String(next) + String(body)
    }

    // MARK: - fractional part

    static func midpoint(_ a: String, _ b: String?) throws -> String {
        if let b, a >= b { throw Failure.notOrdered(a, b) }
        if a.last == digits[0] { throw Failure.malformed(a) }
        if let b, b.last == digits[0] { throw Failure.malformed(b) }

        if let b {
            var n = 0
            let av = Array(a), bv = Array(b)
            while n < bv.count {
                let ac = n < av.count ? av[n] : digits[0]
                if ac != bv[n] { break }
                n += 1
            }
            if n > 0 {
                let prefix = String(bv[0..<n])
                let aRest = n < av.count ? String(av[n...]) : ""
                return prefix + (try midpoint(aRest, String(bv[n...])))
            }
        }

        let da = a.isEmpty ? 0 : digits.firstIndex(of: Array(a)[0])!
        let db = (b.flatMap { $0.isEmpty ? nil : digits.firstIndex(of: Array($0)[0])! }) ?? digits.count

        if db - da > 1 {
            return String(digits[Int((Double(da + db) / 2).rounded())])
        }
        if let b, b.count > 1 {
            return String(Array(b)[0..<1])
        }
        return String(digits[da]) + (try midpoint(String(a.dropFirst()), nil))
    }
}
