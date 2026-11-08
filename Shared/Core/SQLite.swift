import Foundation
import SQLite3

/// Sehr schlanke Hülle um die SQLite-C-Schnittstelle (keine Fremdbibliothek nötig).
/// Wird nur vom Main-Actor benutzt; die Abfragen sind klein und schnell.
nonisolated final class SQLiteDB {
    private var db: OpaquePointer?
    let path: String

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    init(path: String) throws {
        self.path = path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw Failure(message: "Datenbank lässt sich nicht öffnen")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=OFF;")
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw Failure(message: msg)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)) + " – " + sql)
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, idx)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Bool: sqlite3_bind_int64(st, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as Date: sqlite3_bind_double(st, idx, v.timeIntervalSince1970)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_text(st, idx, "\(a!)", -1, Self.transient)
            }
        }
        return st
    }

    @discardableResult
    func run(_ sql: String, _ args: Any?...) throws -> Int {
        try runArgs(sql, args)
    }

    @discardableResult
    func runArgs(_ sql: String, _ args: [Any?]) throws -> Int {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)) + " – " + sql)
        }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ args: Any?...) -> [Row] {
        queryArgs(sql, args)
    }

    func queryArgs(_ sql: String, _ args: [Any?]) -> [Row] {
        guard let st = try? prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(st) }
        var rows: [Row] = []
        let n = sqlite3_column_count(st)
        while sqlite3_step(st) == SQLITE_ROW {
            var r = Row()
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(st, i))
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: r.v[name] = sqlite3_column_int64(st, i)
                case SQLITE_FLOAT: r.v[name] = sqlite3_column_double(st, i)
                case SQLITE_TEXT: r.v[name] = String(cString: sqlite3_column_text(st, i))
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(st, i))
                    r.v[name] = len > 0 ? Data(bytes: sqlite3_column_blob(st, i), count: len) : Data()
                default: break
                }
            }
            rows.append(r)
        }
        return rows
    }

    func one(_ sql: String, _ args: Any?...) -> Row? {
        queryArgs(sql, args).first
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

/// Eine Ergebniszeile mit bequemen Zugriffen.
nonisolated struct Row {
    var v: [String: Any] = [:]
    func str(_ k: String) -> String? { v[k] as? String }
    func s(_ k: String) -> String { (v[k] as? String) ?? "" }
    func int(_ k: String) -> Int {
        if let i = v[k] as? Int64 { return Int(i) }
        if let d = v[k] as? Double { return Int(d) }
        return 0
    }
    func dbl(_ k: String) -> Double {
        if let d = v[k] as? Double { return d }
        if let i = v[k] as? Int64 { return Double(i) }
        return 0
    }
    func bool(_ k: String) -> Bool { int(k) != 0 }
    func date(_ k: String) -> Date { Date(timeIntervalSince1970: dbl(k)) }
    func optDate(_ k: String) -> Date? { v[k] == nil ? nil : date(k) }
}
