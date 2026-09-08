import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite error \(code): \(message)" }
}

/// A deliberately small wrapper around libsqlite3. The index is three tables;
/// it deserves three hundred lines, not a framework.
final class Connection {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = h
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 3000")
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    var lastError: SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError
        }
        return Statement(stmt, connection: self)
    }

    @discardableResult
    func run(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
        let s = try prepare(sql)
        try s.bind(binds)
        try s.run()
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ binds: [SQLValue] = [], _ decode: (Row) -> T) throws -> [T] {
        let s = try prepare(sql)
        try s.bind(binds)
        var out: [T] = []
        while try s.step() { out.append(decode(Row(s))) }
        return out
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

extension SQLValue {
    static func text(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    static func double(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
}

final class Statement {
    let raw: OpaquePointer
    private unowned let connection: Connection

    init(_ raw: OpaquePointer, connection: Connection) {
        self.raw = raw
        self.connection = connection
    }
    deinit { sqlite3_finalize(raw) }

    func bind(_ values: [SQLValue]) throws {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .text(let s):   rc = sqlite3_bind_text(raw, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n):    rc = sqlite3_bind_int64(raw, idx, n)
            case .double(let d): rc = sqlite3_bind_double(raw, idx, d)
            case .null:          rc = sqlite3_bind_null(raw, idx)
            }
            guard rc == SQLITE_OK else { throw connection.lastError }
        }
    }

    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(raw)
        switch rc {
        case SQLITE_ROW:  return true
        case SQLITE_DONE: return false
        default: throw connection.lastError
        }
    }

    func run() throws { while try step() {} }
}

struct Row {
    private let statement: Statement
    init(_ s: Statement) { statement = s }

    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(statement.raw, i) else { return "" }
        return String(cString: c)
    }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement.raw, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(statement.raw, i) }
    func optionalDouble(_ i: Int32) -> Double? {
        sqlite3_column_type(statement.raw, i) == SQLITE_NULL ? nil : sqlite3_column_double(statement.raw, i)
    }
}
