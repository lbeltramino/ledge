import Foundation

/// Reconciling two people editing the same note at once — where one of them is
/// usually not a person.
///
/// The app holds a note's whole text in a view and writes the whole text back.
/// That is fine while you are the only writer. The moment something else can
/// append a line to the file, writing the whole text back means writing over
/// whatever it added, and the note is open on screen precisely when an agent is
/// most likely to be working on it.
///
/// So a save is no longer "put my copy on disk". It is a three-way merge
/// between what the file said when we last agreed (`base`), what the view has
/// now (`mine`), and what the file says now (`theirs`).
public enum Merge {

    public struct Result: Sendable, Equatable {
        public let text: String
        /// True when both sides changed the same lines and both were kept.
        /// Nothing is thrown away either way — this only says the note now has
        /// two versions of something in it.
        public let conflicted: Bool
        /// Where each of `mine`'s lines ended up, or -1 if it did not survive.
        /// This is what lets the caret stay on the word it was on.
        public let lineMap: [Int]
    }

    /// A line-based three-way merge.
    ///
    /// Line-based rather than character-based because that is the shape of the
    /// edits in question: an agent appends a block or flips one character
    /// inside a `[ ]`, and you type somewhere else entirely. Character-level
    /// merging would be cleverer and would occasionally produce a word that
    /// neither of you wrote.
    public static func lines(base: String, mine: String, theirs: String) -> Result {
        let baseLines = base.components(separatedBy: "\n")
        let mineLines = mine.components(separatedBy: "\n")
        let theirsLines = theirs.components(separatedBy: "\n")

        // The cheap answers first: they cover almost every real save.
        if theirsLines == baseLines {
            return Result(text: mine, conflicted: false, lineMap: Array(mineLines.indices))
        }
        if mineLines == baseLines {
            return Result(text: theirs, conflicted: false,
                          lineMap: mapping(of: mineLines, into: theirsLines))
        }
        if mineLines == theirsLines {
            return Result(text: mine, conflicted: false, lineMap: Array(mineLines.indices))
        }

        let toMine = Dictionary(matches(baseLines, mineLines), uniquingKeysWith: { a, _ in a })
        let toTheirs = Dictionary(matches(baseLines, theirsLines), uniquingKeysWith: { a, _ in a })
        // Lines that survived unchanged on both sides. Everything between two of
        // them is a region to resolve.
        let anchors = baseLines.indices.filter { toMine[$0] != nil && toTheirs[$0] != nil }

        var merged: [String] = []
        var lineMap = [Int](repeating: -1, count: mineLines.count)
        var conflicted = false
        var baseAt = 0, mineAt = 0, theirsAt = 0

        func emitMine(_ range: Range<Int>) {
            for index in range {
                lineMap[index] = merged.count
                merged.append(mineLines[index])
            }
        }

        func resolve(_ mineRange: Range<Int>, _ theirsRange: Range<Int>, _ baseRange: Range<Int>) {
            let mineSlice = Array(mineLines[mineRange])
            let theirsSlice = Array(theirsLines[theirsRange])
            let baseSlice = Array(baseLines[baseRange])

            if mineSlice == baseSlice {
                merged.append(contentsOf: theirsSlice)          // only they changed it
            } else if theirsSlice == baseSlice || mineSlice == theirsSlice {
                emitMine(mineRange)                             // only I did, or we agree
            } else {
                // Both changed the same region. Keeping both is the only answer
                // that loses nothing, and a note can carry the duplication until
                // you tidy it — conflict markers in a sticky note cannot.
                conflicted = true
                emitMine(mineRange)
                merged.append(contentsOf: theirsSlice)
            }
        }

        for anchor in anchors {
            let mineAnchor = toMine[anchor]!, theirsAnchor = toTheirs[anchor]!
            // An anchor that would move backwards is not usable as one.
            guard mineAnchor >= mineAt, theirsAnchor >= theirsAt, anchor >= baseAt else { continue }
            resolve(mineAt..<mineAnchor, theirsAt..<theirsAnchor, baseAt..<anchor)
            lineMap[mineAnchor] = merged.count
            merged.append(mineLines[mineAnchor])
            baseAt = anchor + 1; mineAt = mineAnchor + 1; theirsAt = theirsAnchor + 1
        }
        resolve(mineAt..<mineLines.count, theirsAt..<theirsLines.count, baseAt..<baseLines.count)

        return Result(text: merged.joined(separator: "\n"), conflicted: conflicted, lineMap: lineMap)
    }

    /// Where a caret sitting at `offset` in `mine` should go in the merged text.
    ///
    /// Kept on the same line and column rather than the same character index:
    /// lines arriving above you would otherwise slide the caret through your own
    /// sentence.
    public static func caret(_ offset: Int, from mine: String, into result: Result) -> Int {
        let mineLines = mine.components(separatedBy: "\n")
        var consumed = 0
        var line = 0
        while line < mineLines.count {
            let length = (mineLines[line] as NSString).length
            if offset <= consumed + length { break }
            consumed += length + 1
            line += 1
        }
        guard line < result.lineMap.count, result.lineMap[line] >= 0 else {
            return min(offset, (result.text as NSString).length)
        }
        let column = offset - consumed
        let mergedLines = result.text.components(separatedBy: "\n")
        let target = result.lineMap[line]
        var start = 0
        for index in 0..<min(target, mergedLines.count) {
            start += (mergedLines[index] as NSString).length + 1
        }
        let lineLength = target < mergedLines.count ? (mergedLines[target] as NSString).length : 0
        return min(start + min(column, lineLength), (result.text as NSString).length)
    }

    // MARK: - matching

    /// Every line of `a` that also appears, in order, in `b`.
    ///
    /// The common prefix and suffix are taken first. That is not only an
    /// optimisation: the usual case here is a block appended to the end, and it
    /// reduces that to nothing at all.
    private static func matches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }

        var pairs = (0..<head).map { ($0, $0) }
        let aMid = Array(a[head..<(a.count - tail)])
        let bMid = Array(b[head..<(b.count - tail)])

        // A full table, bounded. Notes are hundreds of lines; the bound is there
        // so a pasted log cannot turn a keystroke into a pause.
        if !aMid.isEmpty, !bMid.isEmpty, aMid.count * bMid.count <= 4_000_000 {
            var table = [[Int]](repeating: [Int](repeating: 0, count: bMid.count + 1),
                                count: aMid.count + 1)
            for i in stride(from: aMid.count - 1, through: 0, by: -1) {
                for j in stride(from: bMid.count - 1, through: 0, by: -1) {
                    table[i][j] = aMid[i] == bMid[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < aMid.count, j < bMid.count {
                if aMid[i] == bMid[j] {
                    pairs.append((head + i, head + j)); i += 1; j += 1
                } else if table[i + 1][j] >= table[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }

        for k in 0..<tail { pairs.append((a.count - tail + k, b.count - tail + k)) }
        return pairs
    }

    private static func mapping(of mine: [String], into merged: [String]) -> [Int] {
        var map = [Int](repeating: -1, count: mine.count)
        for (from, to) in matches(mine, merged) { map[from] = to }
        return map
    }
}
