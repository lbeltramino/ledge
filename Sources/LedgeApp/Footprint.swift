import AppKit
import Darwin

/// What Ledge actually costs, measured rather than claimed.
///
/// The number worth quoting is `phys_footprint` — the one Activity Monitor
/// shows and the one macOS charges against memory pressure. Resident size looks
/// far larger and is mostly shared framework pages that every Mac app maps.
@MainActor
enum Footprint {

    /// Bytes, as macOS accounts for them.
    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func megabytes() -> Double { Double(current()) / 1_048_576 }

    static func report(_ label: String) {
        print(String(format: "    %-22@ %.1f MB", label as NSString, megabytes()))
    }

    /// How long the highlighter takes over a note, since it runs on every key.
    static func highlightCost(lines: Int) -> Double {
        var body = ""
        for i in 0..<lines {
            body += i % 4 == 0 ? "## Section \(i)\n" : "- item \(i) with some **bold** and `code`\n"
        }
        let highlighter = MarkdownHighlighter(baseFont: .systemFont(ofSize: 14),
                                              ink: .black, accent: .blue)
        let storage = NSTextStorage(string: body)
        // What a keystroke actually does: one line changes, and the highlighter
        // is asked to bring just that back up to date.
        let text = storage.string as NSString
        let caret = NSRange(location: text.length / 2, length: 1)
        let dirty = MarkdownHighlighter.dirtyRange(for: caret, in: text)
        let start = Date()
        for _ in 0..<20 { highlighter.highlight(storage, in: dirty) }
        return Date().timeIntervalSince(start) / 20 * 1000
    }
}
