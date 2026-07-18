import CSQLite
import Foundation

// UserDictStore — the one sqlite3 handle owner for the learned user dictionary.
// DESIGN.md §2.8, MF#10 (native sqlite3 via the CSQLite shim; GRDB was rejected).
// An actor, so it is the single WAL writer and every access serializes — that is
// what keeps concurrent learns from corrupting the database.
//
// Four tables (DESIGN §2.8):
//   words(key_seq, word, boost, count, last_used)   — the boostable overlay rows
//   correction_pairs(context_pinyin, wrong, right, count)
//   pending_oov(key_seq, word, count)
//   learning_events(kind, app_bundle_id, span_before, span_after, created_at)
//
// Occurrence semantics: every learn bumps `count`; the ranking boost is
// `log(1+count)` but is only *surfaced* once `count ≥ 2` — `loadBoostOverlay`
// selects `WHERE count >= 2`, and a durable write returns a `BoostUpdate` (for
// the MainActor `OverlayHost`) only when it crosses that threshold. Spans stored
// in `learning_events` are truncated to ≤ 20 characters (the privacy cap).
public actor UserDictStore {

    public enum StoreError: Error, Equatable {
        case open(Int32)
        case sqlite(String)
    }

    /// A learning-event category for the forensic `learning_events` ledger.
    public enum LearningEventKind: String, Sendable {
        case correction
        case oov
        case rejected
        case sessionEnd
    }

    /// The privacy span cap — `learning_events` never stores more than this many
    /// characters of any captured span (DESIGN §6: "learning 只存 ≤20 字 span").
    public static let spanMaxChars = 20

    // A C sqlite3 handle. `nonisolated(unsafe)` so the nonisolated `deinit` can
    // close it: real access is serialized by the actor, it is never reassigned
    // after `init`, and `deinit` runs only when no references remain.
    private nonisolated(unsafe) var db: OpaquePointer?

    /// The frozen default DB location. `bundleID` is FROZEN to
    /// `com.soleilyu.inputmethod.TypoFree` — the identity-string rename sweep comes later.
    public static func applicationSupportDefault(bundleID: String = "com.soleilyu.inputmethod.TypoFree") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleID, isDirectory: true)
                   .appendingPathComponent("userdict.sqlite")
    }

    /// Open (creating if needed) the DB at `fileURL`, enable WAL, and create the
    /// schema. Injectable for tests (pass a temp-file URL).
    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(fileURL.path, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw StoreError.open(rc)
        }
        self.db = handle
        try Self.exec(handle, "PRAGMA journal_mode=WAL;")
        try Self.exec(handle, Self.schemaSQL)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Reads

    /// The immutable boost overlay: every `words` row with `count ≥ 2`, keyed
    /// `code → word → boost`. The default `OverlayHost` seed at startup.
    public func loadBoostOverlay() throws -> UserBoostOverlay {
        let stmt = try Self.prepare(db, "SELECT key_seq, word, boost FROM words WHERE count >= 2")
        defer { sqlite3_finalize(stmt) }
        var boosts: [String: [String: Float]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(stmt, 0),
                  let wordC = sqlite3_column_text(stmt, 1) else { continue }
            let key = String(cString: keyC)
            let word = String(cString: wordC)
            let boost = Float(sqlite3_column_double(stmt, 2))
            boosts[key, default: [:]][word] = boost
        }
        return UserBoostOverlay(boosts: boosts)
    }

    // MARK: - Writes

    /// Record a homophone correction: bump `words(keySeq → right)` and the
    /// `correction_pairs` ledger. Returns a `BoostUpdate` once `right` reaches the
    /// ≥2 promotion threshold, else nil.
    @discardableResult
    public func recordCorrection(_ c: DiffLearner.CorrectionCandidate) throws -> BoostUpdate? {
        let newCount = try bumpWord(keySeq: c.keySeq, word: c.right)
        try Self.execute(db, """
            INSERT INTO correction_pairs (context_pinyin, wrong, right, count) VALUES (?, ?, ?, 1)
            ON CONFLICT(context_pinyin, wrong, right) DO UPDATE SET count = count + 1
            """, [.text(c.contextPinyin.joined(separator: " ")), .text(c.wrong), .text(c.right)])
        return boostUpdate(keySeq: c.keySeq, word: c.right, count: newCount)
    }

    /// Record a pending OOV: bump `words(keySeq → word)` and the `pending_oov`
    /// ledger. Returns a `BoostUpdate` once the word reaches ≥2, else nil.
    @discardableResult
    public func recordOOV(_ c: DiffLearner.OOVCandidate) throws -> BoostUpdate? {
        let newCount = try bumpWord(keySeq: c.keySeq, word: c.word)
        try Self.execute(db, """
            INSERT INTO pending_oov (key_seq, word, count) VALUES (?, ?, 1)
            ON CONFLICT(key_seq, word) DO UPDATE SET count = count + 1
            """, [.text(c.keySeq), .text(c.word)])
        return boostUpdate(keySeq: c.keySeq, word: c.word, count: newCount)
    }

    /// Record a reuse of a word the base lexicon ALREADY contains under `keySeq`:
    /// bump only its `words` boost count. It is NOT out-of-vocabulary, so no
    /// `pending_oov` ledger row is written (that is the "OOV not already in
    /// lexicon" filter's known-word branch). Returns a `BoostUpdate` once it
    /// reaches the ≥2 promotion threshold, else nil.
    @discardableResult
    public func recordKnownWordReuse(keySeq: String, word: String) throws -> BoostUpdate? {
        let newCount = try bumpWord(keySeq: keySeq, word: word)
        return boostUpdate(keySeq: keySeq, word: word, count: newCount)
    }

    /// Append a forensic learning event. Spans are truncated to the ≤20-char cap.
    public func recordEvent(kind: LearningEventKind, appBundleId: String?,
                            spanBefore: String?, spanAfter: String?) throws {
        try Self.execute(db, """
            INSERT INTO learning_events (kind, app_bundle_id, span_before, span_after, created_at)
            VALUES (?, ?, ?, ?, ?)
            """, [.text(kind.rawValue), .textOpt(appBundleId),
                  .textOpt(spanBefore.map(Self.cappedSpan)),
                  .textOpt(spanAfter.map(Self.cappedSpan)), .int(Self.now())])
    }

    /// Wipe every table, checkpoint the WAL, and VACUUM — no forensic residue
    /// (DESIGN §6). The base lexicon blob is read-only and untouched.
    public func clearAll() throws {
        try Self.exec(db, """
            DELETE FROM words;
            DELETE FROM correction_pairs;
            DELETE FROM pending_oov;
            DELETE FROM learning_events;
            """)
        try Self.exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
        try Self.exec(db, "VACUUM;")
    }

    // MARK: - Test seams (internal — visible only to `@testable import`)

    /// The accumulated `correction_pairs` count for one candidate, or nil if the
    /// pair was never recorded. Lets the test suite assert the ledger accumulates.
    func correctionPairCount(for c: DiffLearner.CorrectionCandidate) throws -> Int? {
        try Self.queryInt(db, """
            SELECT count FROM correction_pairs WHERE context_pinyin = ? AND wrong = ? AND right = ?
            """, [.text(c.contextPinyin.joined(separator: " ")), .text(c.wrong), .text(c.right)])
    }

    /// The accumulated `pending_oov` count for one candidate, or nil.
    func pendingOOVCount(for c: DiffLearner.OOVCandidate) throws -> Int? {
        try Self.queryInt(db, "SELECT count FROM pending_oov WHERE key_seq = ? AND word = ?",
                          [.text(c.keySeq), .text(c.word)])
    }

    // MARK: - Word count bump (read-modify-write, serialized by the actor)

    /// Increment (or insert at 1) the `words` occurrence count for
    /// `(keySeq, word)`, refreshing the materialized boost + last_used. Returns
    /// the new count. Safe against concurrent callers because the actor
    /// serializes the whole read-then-write.
    private func bumpWord(keySeq: String, word: String) throws -> Int {
        let current = try Self.queryInt(db,
            "SELECT count FROM words WHERE key_seq = ? AND word = ?",
            [.text(keySeq), .text(word)]) ?? 0
        let newCount = current + 1
        let boost = log(Double(1 + newCount))
        try Self.execute(db, """
            INSERT INTO words (key_seq, word, count, boost, last_used) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key_seq, word) DO UPDATE SET
                count = excluded.count, boost = excluded.boost, last_used = excluded.last_used
            """, [.text(keySeq), .text(word), .int(newCount), .double(boost), .int(Self.now())])
        return newCount
    }

    private func boostUpdate(keySeq: String, word: String, count: Int) -> BoostUpdate? {
        guard count >= 2 else { return nil }
        return BoostUpdate(keySeq: keySeq, word: word, boost: log(Double(1 + count)))
    }

    // MARK: - Schema

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS words (
            key_seq TEXT NOT NULL, word TEXT NOT NULL,
            boost REAL NOT NULL DEFAULT 0, count INTEGER NOT NULL DEFAULT 0,
            last_used INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (key_seq, word)
        );
        CREATE TABLE IF NOT EXISTS correction_pairs (
            context_pinyin TEXT NOT NULL, wrong TEXT NOT NULL, right TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (context_pinyin, wrong, right)
        );
        CREATE TABLE IF NOT EXISTS pending_oov (
            key_seq TEXT NOT NULL, word TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (key_seq, word)
        );
        CREATE TABLE IF NOT EXISTS learning_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL, app_bundle_id TEXT,
            span_before TEXT, span_after TEXT, created_at INTEGER NOT NULL DEFAULT 0
        );
        """

    private static func cappedSpan(_ s: String) -> String { String(s.prefix(spanMaxChars)) }
    private static func now() -> Int { Int(Date().timeIntervalSince1970) }

    // MARK: - Low-level sqlite3 helpers (static: usable from `init` before the
    // actor's isolation is fully established, and from every isolated method).

    private enum Bind { case text(String); case textOpt(String?); case int(Int); case double(Double) }

    /// sqlite copies the bound text immediately (transient lifetime is fine).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(err)
            throw StoreError.sqlite(msg)
        }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private static func bindAll(_ db: OpaquePointer?, _ stmt: OpaquePointer, _ binds: [Bind]) throws {
        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch bind {
            case .text(let s):    rc = sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .textOpt(let s): rc = s.map { sqlite3_bind_text(stmt, idx, $0, -1, transient) }
                                       ?? sqlite3_bind_null(stmt, idx)
            case .int(let v):     rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case .double(let d):  rc = sqlite3_bind_double(stmt, idx, d)
            }
            guard rc == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private static func execute(_ db: OpaquePointer?, _ sql: String, _ binds: [Bind]) throws {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(db, stmt, binds)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func queryInt(_ db: OpaquePointer?, _ sql: String, _ binds: [Bind]) throws -> Int? {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try bindAll(db, stmt, binds)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:  return Int(sqlite3_column_int64(stmt, 0))
        case SQLITE_DONE: return nil
        default:          throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}
