import Foundation
import GRDB

/// The SQLite module that indexes message text on this device. FTS5 when a
/// runtime probe finds it, otherwise FTS4, which every Apple SQLite has.
public enum FullTextIndex: String, Sendable, CaseIterable {
    case fts5, fts4

    /// An external-content index over `messages.text` (keyed by `messages.pk`),
    /// so message text is stored once.
    var createSQL: String {
        switch self {
        case .fts5:
            "CREATE VIRTUAL TABLE messages_fts USING fts5(text, content='messages', content_rowid='pk', tokenize='unicode61 remove_diacritics 2')"
        case .fts4:
            #"CREATE VIRTUAL TABLE messages_fts USING fts4(content="messages", text, tokenize=unicode61 "remove_diacritics=2")"#
        }
    }

    /// Triggers that keep the index in step with `messages`. FTS4 must drop an
    /// entry before its content row changes; FTS5 is told the old text.
    var triggersSQL: String {
        switch self {
        case .fts5:
            """
            CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts (rowid, text) VALUES (new.pk, new.text);
            END;
            CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts (messages_fts, rowid, text) VALUES ('delete', old.pk, old.text);
            END;
            CREATE TRIGGER messages_fts_update AFTER UPDATE OF text ON messages WHEN old.text IS NOT new.text BEGIN
                INSERT INTO messages_fts (messages_fts, rowid, text) VALUES ('delete', old.pk, old.text);
                INSERT INTO messages_fts (rowid, text) VALUES (new.pk, new.text);
            END;
            """
        case .fts4:
            """
            CREATE TRIGGER messages_fts_before_update BEFORE UPDATE OF text ON messages WHEN old.text IS NOT new.text BEGIN
                DELETE FROM messages_fts WHERE docid = old.pk;
            END;
            CREATE TRIGGER messages_fts_before_delete BEFORE DELETE ON messages BEGIN
                DELETE FROM messages_fts WHERE docid = old.pk;
            END;
            CREATE TRIGGER messages_fts_after_update AFTER UPDATE OF text ON messages WHEN old.text IS NOT new.text BEGIN
                INSERT INTO messages_fts (docid, text) VALUES (new.pk, new.text);
            END;
            CREATE TRIGGER messages_fts_after_insert AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts (docid, text) VALUES (new.pk, new.text);
            END;
            """
        }
    }

    var triggerNames: [String] {
        switch self {
        case .fts5: ["messages_fts_insert", "messages_fts_delete", "messages_fts_update"]
        case .fts4: ["messages_fts_before_update", "messages_fts_before_delete", "messages_fts_after_update", "messages_fts_after_insert"]
        }
    }

    /// Indexes every stored message again.
    var rebuildSQL: String { "INSERT INTO messages_fts (messages_fts) VALUES ('rebuild')" }

    /// Empties the index. For FTS4 a rebuild over the (already emptied)
    /// messages does it.
    var emptySQL: String {
        switch self {
        case .fts5: "INSERT INTO messages_fts (messages_fts) VALUES ('delete-all')"
        case .fts4: rebuildSQL
        }
    }

    /// The snippet around matches, each between U+0002 and U+0003, about 16 tokens.
    var snippetSQL: String {
        switch self {
        case .fts5: "snippet(messages_fts, 0, char(2), char(3), '…', 16)"
        case .fts4: "snippet(messages_fts, char(2), char(3), '…', -1, 16)"
        }
    }

    /// Best matches first. FTS5 has BM25 built in; for FTS4 AgentLand computes
    /// it from `matchinfo` (`ArchiveRanking`).
    var rankingSQL: String {
        switch self {
        case .fts5: "bm25(messages_fts)"
        case .fts4: "-\(ArchiveRanking.functionName)(matchinfo(messages_fts, 'pcnalx'))"
        }
    }
}

enum ArchiveSchema {
    /// Plain SQL, one migration per step. Times are milliseconds since 1970
    /// (UTC). Message IDs are unique only within their chat: every continued
    /// chat has a seed message named `agentland-seed`. Observed tables keep
    /// their rowid: SQLite reports no changes to WITHOUT ROWID tables.
    static let tables = """
    CREATE TABLE meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    ) WITHOUT ROWID;

    CREATE TABLE sync_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        hostKey TEXT NOT NULL,
        epoch TEXT,
        cursor TEXT,
        syncedAt INTEGER
    );

    CREATE TABLE chats (
        id TEXT PRIMARY KEY NOT NULL,
        projectId TEXT NOT NULL,
        provider TEXT NOT NULL,
        title TEXT NOT NULL,
        model TEXT,
        mode TEXT,
        effort TEXT,
        parentId TEXT,
        relation TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
    );
    CREATE INDEX chats_by_activity ON chats (updatedAt DESC);

    CREATE TABLE pins (
        chatId TEXT PRIMARY KEY NOT NULL,
        pinnedAt INTEGER NOT NULL
    );

    CREATE TABLE messages (
        pk INTEGER PRIMARY KEY,
        chatId TEXT NOT NULL,
        id TEXT NOT NULL,
        turnId TEXT NOT NULL,
        role TEXT NOT NULL,
        status TEXT NOT NULL,
        ord INTEGER NOT NULL,
        createdAt INTEGER,
        completedAt INTEGER,
        provider TEXT NOT NULL,
        model TEXT,
        usage TEXT,
        error TEXT,
        hidden INTEGER NOT NULL DEFAULT 0,
        parts TEXT NOT NULL,
        text TEXT NOT NULL,
        UNIQUE (chatId, id)
    );
    CREATE INDEX messages_by_chat ON messages (chatId, ord, pk);

    CREATE TABLE terminal_logs (
        id TEXT PRIMARY KEY NOT NULL,
        projectId TEXT NOT NULL,
        title TEXT NOT NULL,
        program TEXT NOT NULL,
        startedAt INTEGER NOT NULL,
        endedAt INTEGER,
        status TEXT NOT NULL,
        exitCode INTEGER,
        bytes INTEGER NOT NULL,
        gapBytes INTEGER NOT NULL
    );
    CREATE INDEX terminal_logs_by_start ON terminal_logs (startedAt DESC);
    """

    static let tablesMigration = "1-tables"
    static let fullTextMigration = "2-full-text"

    static func migrator(forcing forced: FullTextIndex?, probeModule: String) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(tablesMigration) { db in
            try db.execute(sql: tables)
        }
        migrator.registerMigration(fullTextMigration) { db in
            let index = forced ?? (probe(db, module: probeModule) ? .fts5 : .fts4)
            try db.execute(sql: index.createSQL)
            try db.execute(sql: index.triggersSQL)
            // Messages stored before this step are indexed too.
            try db.execute(sql: index.rebuildSQL)
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('fullTextIndex', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                           arguments: [index.rawValue])
        }
        return migrator
    }

    /// Whether this SQLite has `module`: a throwaway virtual table in the temp
    /// schema either works or fails with "no such module".
    static func probe(_ db: Database, module: String) -> Bool {
        do {
            try db.execute(sql: "CREATE VIRTUAL TABLE temp.agentland_fulltext_probe USING \(module)(x)")
            try db.execute(sql: "DROP TABLE temp.agentland_fulltext_probe")
            return true
        } catch {
            return false
        }
    }
}

/// BM25 for FTS4, from `matchinfo(…, 'pcnalx')`: phrases, columns, rows,
/// average and row token counts per column, then per phrase and column the
/// hits in this row, hits in all rows and rows with hits.
enum ArchiveRanking {
    static let functionName = "agentland_bm25"
    private static let k1 = 1.2
    private static let b = 0.75

    static let function = DatabaseFunction(functionName, argumentCount: 1, pure: true) { values in
        guard let blob = Data.fromDatabaseValue(values[0]) else { return 0.0 }
        return bm25(matchinfo: blob)
    }

    /// Higher is better.
    static func bm25(matchinfo blob: Data) -> Double {
        let count = blob.count / 4
        guard count >= 3 else { return 0 }
        let values: [UInt32] = blob.withUnsafeBytes { buffer in
            (0..<count).map { buffer.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        let phrases = Int(values[0]), columns = Int(values[1]), rows = Double(values[2])
        let averages = 3, lengths = 3 + columns, hits = 3 + 2 * columns
        guard phrases > 0, columns > 0, count >= hits + 3 * phrases * columns else { return 0 }
        var score = 0.0
        for phrase in 0..<phrases {
            for column in 0..<columns {
                let base = hits + 3 * (phrase * columns + column)
                let frequency = Double(values[base])
                guard frequency > 0 else { continue }
                let rowsWithHits = Double(values[base + 2])
                let idf = max(log((rows - rowsWithHits + 0.5) / (rowsWithHits + 0.5)), 1e-6)
                let average = max(Double(values[averages + column]), 1)
                let length = Double(values[lengths + column])
                score += idf * frequency * (k1 + 1) / (frequency + k1 * (1 - b + b * length / average))
            }
        }
        return score
    }
}
