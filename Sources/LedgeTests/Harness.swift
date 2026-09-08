import Foundation

/// A deliberately tiny test harness. Swap for swift-testing the day Xcode is
/// installed: `suite`/`test`/`expect` map one-to-one onto `@Suite`/`@Test`/`#expect`.
@MainActor
final class Check {
    fileprivate var failures: [String] = []

    func expect(_ condition: Bool, _ message: @autoclosure () -> String = "",
                file: String = #fileID, line: UInt = #line) {
        guard !condition else { return }
        let note = message()
        failures.append("\(file):\(line)" + (note.isEmpty ? "" : " — \(note)"))
    }

    func equal<V: Equatable>(_ actual: V, _ expected: V, _ message: @autoclosure () -> String = "",
                             file: String = #fileID, line: UInt = #line) {
        guard actual != expected else { return }
        let note = message()
        failures.append("\(file):\(line) — expected \(expected), got \(actual)" + (note.isEmpty ? "" : " (\(note))"))
    }

    func throwsError(_ body: () throws -> Void, _ message: @autoclosure () -> String = "",
                     file: String = #fileID, line: UInt = #line) {
        do {
            try body()
            failures.append("\(file):\(line) — expected a throw, got none. \(message())")
        } catch {}
    }
}

@MainActor
enum Runner {
    static var passed = 0
    static var failed = 0
    private static var suiteName = ""

    static func suite(_ name: String) {
        suiteName = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    static func test(_ name: String, _ body: (Check) async throws -> Void) async {
        let check = Check()
        do {
            try await body(check)
        } catch {
            check.failures.append("threw \(error)")
        }
        if check.failures.isEmpty {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(name)")
        } else {
            failed += 1
            print("  \u{001B}[31m✗\u{001B}[0m \(name)")
            for f in check.failures { print("      \u{001B}[31m\(f)\u{001B}[0m") }
        }
    }

    static func summary() -> Int32 {
        let total = passed + failed
        print("")
        if failed == 0 {
            print("\u{001B}[32m\(total) tests, all passing\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31m\(failed) of \(total) tests failing\u{001B}[0m")
        return 1
    }
}

/// A scratch notes folder that cleans up after itself.
struct Sandbox: ~Copyable {
    let url: URL
    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: url.appendingPathComponent(name))
    }
    func read(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: url.appendingPathComponent(name)), as: UTF8.self)
    }
    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }
    func filenames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }
    func modified(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path))?[.modificationDate] as? Date
    }
}
