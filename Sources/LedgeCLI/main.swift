import Foundation
import LedgeCore
import LedgeStore

// The `ledge` command: how something other than you writes to your notes.
//
// It exists so an agent working on a long task can keep a note up to date —
// ticking a checklist, appending what it found — and you can watch that happen
// on the deck without being interrupted by it.
//
// It never opens the SQLite index. Writing the .md file is the whole protocol:
// the app is watching the folder and picks the change up within 150 ms. That
// also means this works when the app is not running, and that nothing here can
// corrupt the app's cache.

// MARK: - where the notes are

/// Mirrors the app's own resolution, in order, so both agree without either
/// asking the other.
func notesFolder(_ explicit: String?) -> URL {
    if let explicit {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
    }
    if let environment = ProcessInfo.processInfo.environment["LEDGE_FOLDER"] {
        return URL(fileURLWithPath: (environment as NSString).expandingTildeInPath)
    }
    // The app keeps a chosen folder as a security-scoped bookmark in its own
    // defaults domain. Reading it here is what makes `ledge` follow the folder
    // you picked in the app rather than insisting on the default one.
    if let defaults = UserDefaults(suiteName: "com.lisandro.Ledge"),
       let data = defaults.data(forKey: "ledge.notesFolderBookmark") {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return url
        }
    }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ledge")
}

// MARK: - arguments

struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    init(_ raw: [String]) {
        var rest = raw[...]
        while let argument = rest.first {
            rest = rest.dropFirst()
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                continue
            }
            let name = String(argument.dropFirst(2))
            // `--` ends the options: everything after it is text, even a
            // sentence that starts with a dash.
            if name.isEmpty {
                positional.append(contentsOf: rest)
                return
            }
            if let equals = name.firstIndex(of: "=") {
                flags[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
            } else if let next = rest.first, !next.hasPrefix("--") {
                flags[name] = next
                rest = rest.dropFirst()
            } else {
                switches.insert(name)
            }
        }
    }

    func value(_ name: String) -> String? { flags[name] }
    func has(_ name: String) -> Bool { switches.contains(name) || flags[name] != nil }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ledge: " + message + "\n").utf8))
    exit(1)
}

/// Text given as an argument, or on stdin when it is long or has newlines in it.
func text(from arguments: Arguments, after index: Int) -> String {
    let joined = arguments.positional.dropFirst(index).joined(separator: " ")
    if !joined.isEmpty { return joined }
    guard let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty else { return "" }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - output

func json(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

func describe(_ note: Note) -> [String: Any] {
    [
        "id": note.id,
        "title": note.displayTitle,
        "feed": note.feed,
        "strip": note.strip,
        "color": note.color.rawValue,
        "state": note.state.rawValue,
        "tags": note.tags,
        "updated": Frontmatter.string(from: note.updated),
        "tasks": Checkbox.items(in: note.body).map { item -> [String: Any] in
            ["text": (note.body as NSString).substring(with: item.content), "done": item.isDone]
        },
    ]
}

let usage = """
ledge — write to your Ledge notes from a script or an agent

  ledge new <title> [--feed NAME] [--strip NAME] [--color C] [--body TEXT]
  ledge append <note> <text…>            add a block at the end
  ledge task add <note> <text…>          add an unticked task
  ledge task check <note> <text…>        tick the task whose text matches
  ledge task uncheck <note> <text…>
  ledge set <note> [--title T] [--color C] [--feed F] [--archive] [--activate]
  ledge get <note> [--json]
  ledge list [--feed NAME] [--json]
  ledge folder

<note> is an id, or enough of a title to be unambiguous.
Text may also be given on stdin. --folder PATH, or $LEDGE_FOLDER, picks the
folder; otherwise the one the app is using.
"""

// MARK: - commands

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let store = FeedStore(folder: notesFolder(arguments.value("folder")))
guard let command = arguments.positional.first else {
    print(usage)
    exit(0)
}

func locate(_ reference: String?) throws -> FeedStore.Entry {
    guard let reference, !reference.isEmpty else { fail("which note?") }
    guard let found = try store.find(reference) else {
        fail("no note matches \(reference.debugDescription)")
    }
    return found
}

do {
    switch command {
    case "new":
        let title = arguments.positional.count > 1 ? arguments.positional[1] : ""
        guard !title.isEmpty else { fail("a new note needs a title") }
        let body = arguments.value("body") ?? ""
        let entry = try store.create(title: title,
                                     body: body,
                                     feed: arguments.value("feed") ?? "",
                                     strip: arguments.value("strip") ?? "",
                                     color: arguments.value("color").flatMap(NoteColor.init(rawValue:)))
        print(entry.note.id)

    case "append":
        let entry = try locate(arguments.positional.dropFirst().first)
        let addition = text(from: arguments, after: 2)
        guard !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("nothing to append")
        }
        var note = entry.note
        note.body = FeedEdit.appending(addition, to: note.body)
        _ = try store.write(note, to: entry.url)
        print("appended to \(note.displayTitle)")

    case "task":
        let verb = arguments.positional.count > 1 ? arguments.positional[1] : ""
        let entry = try locate(arguments.positional.dropFirst(2).first)
        let words = text(from: arguments, after: 3)
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("which task?")
        }
        var note = entry.note

        switch verb {
        case "add":
            note.body = FeedEdit.addingTask(words, to: note.body)
            _ = try store.write(note, to: entry.url)
            print("added: \(words)")
        case "check", "uncheck":
            let done = verb == "check"
            guard let ticked = FeedEdit.setting(done, matching: words, in: note.body) else {
                fail("no task in \(note.displayTitle.debugDescription) matches \(words.debugDescription)")
            }
            guard ticked.changed else {
                // Not an error: an agent repeating itself is not a failure, it
                // just is not work. Saying so costs a write nobody needed.
                print("already \(done ? "done" : "open"): \(ticked.item)")
                exit(0)
            }
            note.body = ticked.body
            _ = try store.write(note, to: entry.url)
            print("\(done ? "done" : "reopened"): \(ticked.item)")
        default:
            fail("task what? add, check or uncheck")
        }

    case "set":
        let entry = try locate(arguments.positional.dropFirst().first)
        var note = entry.note
        if let title = arguments.value("title") { note.title = title }
        if let feed = arguments.value("feed") { note.feed = feed }
        if let colour = arguments.value("color") {
            guard let parsed = NoteColor(rawValue: colour) else {
                fail("colour must be one of \(NoteColor.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            note.color = parsed
        }
        if arguments.has("archive") { note.state = .archived }
        if arguments.has("activate") { note.state = .active }
        _ = try store.write(note, to: entry.url)
        print(note.id)

    case "get":
        let entry = try locate(arguments.positional.dropFirst().first)
        if arguments.has("json") {
            var payload = describe(entry.note)
            payload["body"] = entry.note.body
            print(json(payload))
        } else {
            print(entry.note.body)
        }

    case "list":
        let wanted = arguments.value("feed")
        let all = try store.notes()
            .filter { $0.note.state == .active }
            .filter { wanted == nil || $0.note.feed == wanted! }
            .sorted { $0.note.updated > $1.note.updated }
        if arguments.has("json") {
            print(json(all.map { describe($0.note) }))
        } else {
            for entry in all {
                let tasks = Checkbox.items(in: entry.note.body)
                let progress = tasks.isEmpty
                    ? ""
                    : "  [\(tasks.filter(\.isDone).count)/\(tasks.count)]"
                let feed = entry.note.feed.isEmpty ? "" : "  ← \(entry.note.feed)"
                print("\(entry.note.id)  \(entry.note.displayTitle)\(progress)\(feed)")
            }
        }

    case "folder":
        print(store.folder.path)

    case "help", "--help", "-h":
        print(usage)

    default:
        fail("no such command: \(command)\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
