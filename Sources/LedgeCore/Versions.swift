import Foundation

/// Compares release versions, part by numeric part.
///
/// Lives here rather than in the app so it can be tested: string comparison
/// says 0.10.0 is older than 0.9.0, which is exactly the bug that makes an
/// update check stop working the tenth time you ship.
public enum UpdateCheckVersions {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0
            let right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }
}
