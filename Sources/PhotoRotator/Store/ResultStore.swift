import Foundation
import RotatorCore
import SQLite3

/// One photo's scan outcome, keyed by its PhotoKit local identifier.
struct ScanRecord: Sendable, Hashable {
    var localIdentifier: String
    /// The asset's `modificationDate` when it was scanned; a different value later means the result is stale.
    var modificationDate: Double
    var status: ScanStatus
    var rotation: Rotation
    var confidence: Double
    var evidence: String
}

struct ScanCounts: Sendable, Equatable {
    var upright = 0
    var needsRotation = 0
    var inconclusive = 0
    var unavailable = 0
    var failed = 0
    var applied = 0

    var total: Int { upright + needsRotation + inconclusive + unavailable + failed }
}

enum StoreError: Error, LocalizedError {
    case sqlite(String)
    var errorDescription: String? {
        if case .sqlite(let message) = self { return "Results database: \(message)" }
        return nil
    }
}

/// Persists scan results in SQLite so a 250,000-photo scan can be stopped and resumed, and so the review list
/// does not have to be held in memory between launches. Lives in Application Support, never in the Photos library.
actor ResultStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PhotoRotator", isDirectory: true).appendingPathComponent("scan.sqlite")
    }

    init(url: URL = ResultStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }
        db = handle
        try Self.exec(handle, """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS results (
                local_id    TEXT PRIMARY KEY NOT NULL,
                mod_date    REAL NOT NULL,
                status      INTEGER NOT NULL,
                rotation    INTEGER NOT NULL,
                confidence  REAL NOT NULL,
                evidence    TEXT NOT NULL,
                scanned_at  REAL NOT NULL,
                applied_at  REAL
            );
            CREATE INDEX IF NOT EXISTS results_status ON results(status, applied_at);
            """)

        // Results from an older analyzer are discarded so those photos are scanned again. Records of rotations that
        // were applied are kept: they're what "Undo All" works from.
        var statement: OpaquePointer?
        var storedVersion: Int32 = 0
        if sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            storedVersion = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        if storedVersion < Self.analysisVersion {
            try Self.exec(handle, """
                DELETE FROM results WHERE applied_at IS NULL;
                PRAGMA user_version = \(Self.analysisVersion);
                """)
        }
    }

    /// Bump whenever a change to analysis makes earlier results untrustworthy.
    /// 2: photos are analysed as displayed (version 1 could analyse photos stored with an orientation tag sideways).
    /// 3: the orientation network is weighed by how common each turn really is.
    /// 4: proposed turns always hear from every cue; text rules out sideways turns even when it isn't a word.
    static let analysisVersion: Int32 = 4

    deinit { sqlite3_close(db) }

    // MARK: Writing

    func upsert(_ records: [ScanRecord]) throws {
        guard !records.isEmpty else { return }
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT OR REPLACE INTO results (local_id, mod_date, status, rotation, confidence, evidence, scanned_at, applied_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """)
            defer { sqlite3_finalize(statement) }
            let now = Date().timeIntervalSince1970
            for r in records {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, r.localIdentifier, -1, Self.transient)
                sqlite3_bind_double(statement, 2, r.modificationDate)
                sqlite3_bind_int(statement, 3, Int32(r.status.rawValue))
                sqlite3_bind_int(statement, 4, Int32(r.rotation.rawValue))
                sqlite3_bind_double(statement, 5, r.confidence)
                sqlite3_bind_text(statement, 6, r.evidence, -1, Self.transient)
                sqlite3_bind_double(statement, 7, now)
                try step(statement)
            }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    /// Records that the rotation was applied. `newModificationDate` is the asset's date after the edit, so a later
    /// rescan treats the photo as already up to date instead of analysing it again.
    func markApplied(_ localIdentifier: String, newModificationDate: Double?) throws {
        let statement = try prepare("UPDATE results SET applied_at = ?, mod_date = COALESCE(?, mod_date) WHERE local_id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        if let newModificationDate {
            sqlite3_bind_double(statement, 2, newModificationDate)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_text(statement, 3, localIdentifier, -1, Self.transient)
        try step(statement)
    }

    /// Marks a proposal as rejected by the user so it stops appearing in review (it is stored as upright).
    func dismiss(_ localIdentifiers: [String]) throws {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare("UPDATE results SET status = ? WHERE local_id = ?")
            defer { sqlite3_finalize(statement) }
            for id in localIdentifiers {
                sqlite3_reset(statement)
                sqlite3_bind_int(statement, 1, Int32(ScanStatus.upright.rawValue))
                sqlite3_bind_text(statement, 2, id, -1, Self.transient)
                try step(statement)
            }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    func reset() throws {
        try Self.exec(db, "DELETE FROM results WHERE applied_at IS NULL")
    }

    /// Forgets these photos entirely, so the next scan checks them again.
    func forget(_ localIdentifiers: [String]) throws {
        let statement = try prepare("DELETE FROM results WHERE local_id = ?")
        defer { sqlite3_finalize(statement) }
        for id in localIdentifiers {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, id, -1, Self.transient)
            try step(statement)
        }
    }

    /// Photos this app has rotated.
    func appliedIdentifiers() throws -> [String] {
        let statement = try prepare("SELECT local_id FROM results WHERE applied_at IS NOT NULL")
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(String(cString: sqlite3_column_text(statement, 0))) }
        return ids
    }

    // MARK: Reading

    /// `local_id → mod_date` for every scanned photo, used to skip unchanged photos when resuming.
    func scannedModificationDates() throws -> [String: Double] {
        let statement = try prepare("SELECT local_id, mod_date FROM results")
        defer { sqlite3_finalize(statement) }
        var result: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[String(cString: sqlite3_column_text(statement, 0))] = sqlite3_column_double(statement, 1)
        }
        return result
    }

    /// Photos that need rotating and have not been rotated yet, most confident first.
    func pendingProposals() throws -> [ScanRecord] {
        let statement = try prepare("""
            SELECT local_id, mod_date, status, rotation, confidence, evidence FROM results
            WHERE status = ? AND applied_at IS NULL ORDER BY confidence DESC
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(ScanStatus.needsRotation.rawValue))
        var records: [ScanRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(ScanRecord(
                localIdentifier: String(cString: sqlite3_column_text(statement, 0)),
                modificationDate: sqlite3_column_double(statement, 1),
                status: ScanStatus(rawValue: Int(sqlite3_column_int(statement, 2))) ?? .failed,
                rotation: Rotation(rawValue: Int(sqlite3_column_int(statement, 3))) ?? Rotation.none,
                confidence: sqlite3_column_double(statement, 4),
                evidence: String(cString: sqlite3_column_text(statement, 5))
            ))
        }
        return records
    }

    func counts() throws -> ScanCounts {
        let statement = try prepare("SELECT status, applied_at IS NOT NULL, COUNT(*) FROM results GROUP BY 1, 2")
        defer { sqlite3_finalize(statement) }
        var counts = ScanCounts()
        while sqlite3_step(statement) == SQLITE_ROW {
            let n = Int(sqlite3_column_int(statement, 2))
            if sqlite3_column_int(statement, 1) != 0 { counts.applied += n; continue }
            switch ScanStatus(rawValue: Int(sqlite3_column_int(statement, 0))) {
            case .upright: counts.upright += n
            case .needsRotation: counts.needsRotation += n
            case .inconclusive: counts.inconclusive += n
            case .unavailable: counts.unavailable += n
            case .failed, nil: counts.failed += n
            }
        }
        return counts
    }

    // MARK: SQLite plumbing

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw StoreError.sqlite(message)
        }
    }
}
