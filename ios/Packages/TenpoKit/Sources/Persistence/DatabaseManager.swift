import Foundation
import GRDB

/// Owns the local SQLite database — the source of truth for learner state (§4.1, D7).
/// On-disk databases use a WAL-mode pool so every turn can be persisted as it
/// happens without blocking reads (R12 crash safety).
public final class DatabaseManager: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// WAL-mode database at the given URL, creating parent directories as needed.
    public static func onDisk(at url: URL) throws -> DatabaseManager {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path) // DatabasePool is WAL by default
        return try DatabaseManager(writer: pool)
    }

    /// Standard app database location (Application Support/Tenpo/tenpo.sqlite).
    public static func appDefault() throws -> DatabaseManager {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Tenpo", isDirectory: true)
        return try onDisk(at: dir.appendingPathComponent("tenpo.sqlite"))
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(writer: try DatabaseQueue())
    }

    public func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await writer.read(block)
    }

    public func write<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await writer.write(block)
    }
}

// MARK: - Migrations (§4.7, single schema: SQLite locally = Postgres in Supabase)

extension DatabaseManager {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_schema") { db in
            // content (read-mostly, shipped + generated)
            try db.execute(sql: """
                CREATE TABLE content_item (
                  id TEXT PRIMARY KEY,
                  language TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  payload TEXT NOT NULL,
                  band TEXT,
                  frequency_rank INTEGER,
                  source TEXT,
                  license TEXT
                );
                """)
            try db.execute(sql: """
                CREATE TABLE item_link (
                  from_id TEXT NOT NULL,
                  to_id TEXT NOT NULL,
                  relation TEXT NOT NULL,
                  PRIMARY KEY (from_id, to_id, relation)
                );
                """)

            // learner state
            try db.execute(sql: """
                CREATE TABLE skill_state (
                  item_id TEXT NOT NULL,
                  dimension TEXT NOT NULL,
                  stability REAL,
                  difficulty REAL,
                  due DATETIME,
                  last_review DATETIME,
                  reps INTEGER NOT NULL DEFAULT 0,
                  lapses INTEGER NOT NULL DEFAULT 0,
                  suspended BOOLEAN NOT NULL DEFAULT FALSE,
                  PRIMARY KEY (item_id, dimension)
                );
                """)
            try db.execute(sql: """
                CREATE TABLE review_event (
                  id TEXT PRIMARY KEY,
                  item_id TEXT NOT NULL,
                  dimension TEXT NOT NULL,
                  grade INTEGER NOT NULL,
                  mode_id TEXT,
                  session_id TEXT,
                  latency_ms INTEGER,
                  at DATETIME NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE error_event (
                  id TEXT PRIMARY KEY,
                  session_id TEXT,
                  item_id TEXT,
                  category TEXT NOT NULL,
                  surface TEXT,
                  expected TEXT,
                  severity TEXT,
                  at DATETIME NOT NULL
                );
                """)

            // sessions
            try db.execute(sql: """
                CREATE TABLE session (
                  id TEXT PRIMARY KEY,
                  mode_id TEXT NOT NULL,
                  scenario_id TEXT,
                  started_at DATETIME NOT NULL,
                  ended_at DATETIME,
                  status TEXT,
                  score TEXT,
                  cost_usd REAL,
                  pipeline TEXT
                );
                """)
            try db.execute(sql: """
                CREATE TABLE transcript_turn (
                  session_id TEXT NOT NULL,
                  seq INTEGER NOT NULL,
                  role TEXT NOT NULL,
                  text TEXT,
                  audio_ref TEXT,
                  director_json TEXT,
                  at DATETIME NOT NULL,
                  PRIMARY KEY (session_id, seq)
                );
                """)

            // hot paths: due-queue builder, per-item review history, session error lists
            try db.execute(sql: "CREATE INDEX idx_skill_state_due ON skill_state(due) WHERE suspended = FALSE;")
            try db.execute(sql: "CREATE INDEX idx_review_event_item ON review_event(item_id, dimension);")
            try db.execute(sql: "CREATE INDEX idx_error_event_session ON error_event(session_id);")
            try db.execute(sql: "CREATE INDEX idx_content_item_kind_band ON content_item(kind, band);")
            try db.execute(sql: "CREATE INDEX idx_session_status ON session(status);")
        }

        return migrator
    }
}
