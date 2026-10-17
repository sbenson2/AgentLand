package host

import (
	"database/sql"
	"errors"
	"fmt"
)

// Archive schema. Times are UTC Unix milliseconds. Chat IDs are unique across
// the archive; message IDs are unique within their chat.
//
//	meta            One row (id = 1): schema_version, archive_epoch (random,
//	                chosen when the database is created) and created_at.
//	chats           id, project_id and provider (both fixed by the first
//	                write), title, model, mode, effort, parent_id, relation
//	                ("continue" for a chat continued from parent_id; v2),
//	                created_at, updated_at; title_source and title_basis
//	                (chat names; v4).
//	messages        pk (stable integer key used by message_fts), chat_id + id
//	                (unique), ord, turn_id, role, status, model, created_at,
//	                completed_at (NULL while streaming), usage_* (NULL when
//	                unknown), error_code, error_message, hidden (rewound),
//	                search_text (text parts, at most 256 KiB) and digest (hash
//	                of the stored snapshot, so an identical rewrite is skipped).
//	parts           (message_pk, ord): kind, id, text, tool_* (tool_name is
//	                NULL for parts without a tool; tool_sources,
//	                tool_memory_id and tool_memory_text: plain chats, v5),
//	                truncated, attachment_* (attachment_name is NULL without
//	                an attachment), blob_sha256, started_at, ended_at.
//	interactions    (chat_id, id): kind, outcome and a short summary. Answers
//	                are never stored.
//	blobs           sha256: size, mime, refcount (kept by the parts triggers),
//	                created_at, released_at (set when the last reference goes).
//	                Files live at blobs/<first two hex digits>/<sha256>.
//	terminal_logs   id: terminal_id (the live PTY), project_id,
//	                owner_device_id, title, program, started_at, ended_at,
//	                status (running|exited|disconnected|interrupted),
//	                exit_code, bytes, gap_bytes (output skipped while capture
//	                was paused) and file (relative to the archive directory);
//	                end_reason, ended_by_device_id and conversation_id (v7);
//	                folder (v8: where a terminal outside any workspace ran,
//	                project_id '_none'; empty for the others).
//	changes         seq (AUTOINCREMENT): entity (chat|message|terminalLog),
//	                entity_id, chat_id ('' for terminal logs), project_id, op
//	                (upsert|delete), at. UNIQUE(entity, chat_id, entity_id): a
//	                write replaces the entity's row, so each entity appears
//	                once, at its latest seq; a delete leaves a tombstone. The
//	                chat_id column is part of the key because message IDs are
//	                only unique within a chat.
//	schedule_runs   One row per run of a schedule (M4): chat_id, status,
//	                catch_up, error; manual and scheduled_at (v3). Unused
//	                since schedules were removed (2026-10-06); kept so the
//	                migrations stay as they were.
//	notices         Chat events for this Mac's app (M5, archive_notices.go);
//	                project_name (v3); schedule_id and run_id stay empty
//	                since 2026-10-06. notice_ack (v3)
//	                holds how far the app has handled them.
//	backfill_state  (source, scope): cursor, done, imported, updated_at;
//	                chats and chats_done (v2) count one pass's progress.
//	message_fts     FTS5 over messages.search_text: external content,
//	                unicode61 remove_diacritics 2, kept in sync by triggers.
//	vault_state     vault_id (one per vault folder; v6, archive_vault.go):
//	                root, cursor (the newest changes.seq the vault has
//	                written), backfill_until (the newest seq when the vault
//	                was turned on: changes up to it are the first write),
//	                backfill_total, backfill_done, updated_at.
//	vault_files     (vault_id, entity, entity_id, part): path (relative to
//	                the vault's root; UNIQUE per vault), digest (of the
//	                generated text last written; empty while a hub's path is
//	                only reserved), first_title (the title a note or
//	                workspace had when the vault first named it), listing
//	                (JSON: what hubs and Daily notes show of a chat's or
//	                terminal's note, kept after the chat is deleted; empty
//	                for other files) and written_at. entity is chat,
//	                terminalLog, workspace, provider, daily, readme or
//	                attachment.
//
// Each migration runs in its own transaction and records its version in meta,
// so opening an archive is idempotent and an interrupted migration leaves the
// previous version intact. A database from a newer host is refused.
var archiveMigrations = []func(tx *sql.Tx, epoch string, now int64) error{
	func(tx *sql.Tx, epoch string, now int64) error {
		if _, err := tx.Exec(archiveSchemaV1); err != nil {
			return err
		}
		_, err := tx.Exec(`INSERT INTO meta (id, schema_version, archive_epoch, created_at) VALUES (1, 1, ?, ?)`, epoch, now)
		return err
	},
	// Version 2 (M1 chunk B2): continued chats and backfill progress.
	func(tx *sql.Tx, _ string, _ int64) error {
		_, err := tx.Exec(archiveSchemaV2)
		return err
	},
	// Version 3 (M4 schedules, M5 notices): manual runs and due times, the
	// project name of a notice and the notices this Mac's app has handled.
	func(tx *sql.Tx, _ string, _ int64) error {
		_, err := tx.Exec(archiveSchemaV3)
		return err
	},
	// Version 4 (chat names): where a chat's title came from and the newest
	// message it describes.
	func(tx *sql.Tx, _ string, _ int64) error {
		_, err := tx.Exec(archiveSchemaV4)
		return err
	},
	// Version 5 (plain chats): the web pages a tool part names and the
	// memory entry a save stored.
	func(tx *sql.Tx, _ string, _ int64) error {
		_, err := tx.Exec(archiveSchemaV5)
		return err
	},
	// Version 6 (vault): where each vault folder is in the change feed and
	// the notes written to it.
	func(tx *sql.Tx, _ string, _ int64) error {
		_, err := tx.Exec(archiveSchemaV6)
		return err
	},
	// Version 7 (terminal ends): why each terminal ended, the device that
	// ended it and the Claude Code conversation it ran.
	func(tx *sql.Tx, _ string, _ int64) error {
		_, err := tx.Exec(archiveSchemaV7)
		return err
	},
	// Version 8 (terminals outside any workspace): the folder such a
	// terminal ran in.
	func(tx *sql.Tx, _ string, _ int64) error {
		_, err := tx.Exec(archiveSchemaV8)
		return err
	},
}

const archiveSchemaV1 = `
CREATE TABLE meta (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	schema_version INTEGER NOT NULL,
	archive_epoch TEXT NOT NULL,
	created_at INTEGER NOT NULL
);

CREATE TABLE chats (
	id TEXT PRIMARY KEY,
	project_id TEXT NOT NULL,
	provider TEXT NOT NULL,
	title TEXT NOT NULL DEFAULT '',
	model TEXT NOT NULL DEFAULT '',
	mode TEXT NOT NULL DEFAULT '',
	effort TEXT NOT NULL DEFAULT '',
	parent_id TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE INDEX chats_by_project ON chats (project_id, updated_at);

CREATE TABLE messages (
	pk INTEGER PRIMARY KEY,
	chat_id TEXT NOT NULL REFERENCES chats (id) ON DELETE CASCADE,
	id TEXT NOT NULL,
	ord INTEGER NOT NULL,
	turn_id TEXT NOT NULL DEFAULT '',
	role TEXT NOT NULL,
	status TEXT NOT NULL,
	model TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	completed_at INTEGER,
	usage_input INTEGER,
	usage_output INTEGER,
	usage_reasoning INTEGER,
	usage_cache_read INTEGER,
	usage_cache_write INTEGER,
	usage_cost_micros INTEGER,
	error_code TEXT NOT NULL DEFAULT '',
	error_message TEXT NOT NULL DEFAULT '',
	hidden INTEGER NOT NULL DEFAULT 0,
	search_text TEXT NOT NULL DEFAULT '',
	digest TEXT NOT NULL DEFAULT '',
	UNIQUE (chat_id, id)
);
CREATE INDEX messages_by_order ON messages (chat_id, ord, pk);

CREATE TABLE parts (
	message_pk INTEGER NOT NULL REFERENCES messages (pk) ON DELETE CASCADE,
	ord INTEGER NOT NULL,
	id TEXT NOT NULL,
	kind TEXT NOT NULL,
	text TEXT NOT NULL DEFAULT '',
	tool_name TEXT,
	tool_call_id TEXT NOT NULL DEFAULT '',
	tool_status TEXT NOT NULL DEFAULT '',
	tool_title TEXT NOT NULL DEFAULT '',
	tool_input TEXT NOT NULL DEFAULT '',
	tool_output TEXT NOT NULL DEFAULT '',
	tool_error TEXT NOT NULL DEFAULT '',
	truncated INTEGER NOT NULL DEFAULT 0,
	attachment_name TEXT,
	attachment_mime TEXT NOT NULL DEFAULT '',
	attachment_size INTEGER NOT NULL DEFAULT 0,
	blob_sha256 TEXT,
	started_at INTEGER,
	ended_at INTEGER,
	PRIMARY KEY (message_pk, ord)
);
CREATE INDEX parts_by_blob ON parts (blob_sha256) WHERE blob_sha256 IS NOT NULL;

CREATE TABLE interactions (
	chat_id TEXT NOT NULL REFERENCES chats (id) ON DELETE CASCADE,
	id TEXT NOT NULL,
	kind TEXT NOT NULL,
	outcome TEXT NOT NULL DEFAULT '',
	summary TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	resolved_at INTEGER,
	PRIMARY KEY (chat_id, id)
);

CREATE TABLE blobs (
	sha256 TEXT PRIMARY KEY,
	size INTEGER NOT NULL,
	mime TEXT NOT NULL DEFAULT '',
	refcount INTEGER NOT NULL DEFAULT 0,
	created_at INTEGER NOT NULL,
	released_at INTEGER
);
CREATE INDEX blobs_unreferenced ON blobs (created_at) WHERE refcount <= 0;

CREATE TRIGGER parts_blob_reference AFTER INSERT ON parts WHEN new.blob_sha256 IS NOT NULL BEGIN
	UPDATE blobs SET refcount = refcount + 1, released_at = NULL WHERE sha256 = new.blob_sha256;
END;
CREATE TRIGGER parts_blob_release AFTER DELETE ON parts WHEN old.blob_sha256 IS NOT NULL BEGIN
	UPDATE blobs SET refcount = refcount - 1,
		released_at = CASE WHEN refcount <= 1 THEN CAST(unixepoch('subsec') * 1000 AS INTEGER) ELSE NULL END
	WHERE sha256 = old.blob_sha256;
END;

CREATE TABLE terminal_logs (
	id TEXT PRIMARY KEY,
	terminal_id TEXT NOT NULL DEFAULT '',
	project_id TEXT NOT NULL,
	owner_device_id TEXT NOT NULL DEFAULT '',
	title TEXT NOT NULL DEFAULT '',
	program TEXT NOT NULL DEFAULT '',
	started_at INTEGER NOT NULL,
	ended_at INTEGER,
	status TEXT NOT NULL,
	exit_code INTEGER,
	bytes INTEGER NOT NULL DEFAULT 0,
	gap_bytes INTEGER NOT NULL DEFAULT 0,
	file TEXT NOT NULL
);
CREATE INDEX terminal_logs_by_project ON terminal_logs (project_id, started_at);

CREATE TABLE changes (
	seq INTEGER PRIMARY KEY AUTOINCREMENT,
	entity TEXT NOT NULL,
	entity_id TEXT NOT NULL,
	chat_id TEXT NOT NULL DEFAULT '',
	project_id TEXT NOT NULL,
	op TEXT NOT NULL,
	at INTEGER NOT NULL,
	UNIQUE (entity, chat_id, entity_id)
);

CREATE TABLE schedule_runs (
	id TEXT PRIMARY KEY,
	schedule_id TEXT NOT NULL,
	project_id TEXT NOT NULL,
	chat_id TEXT NOT NULL DEFAULT '',
	started_at INTEGER NOT NULL,
	finished_at INTEGER,
	status TEXT NOT NULL,
	catch_up INTEGER NOT NULL DEFAULT 0,
	error TEXT NOT NULL DEFAULT ''
);
CREATE INDEX schedule_runs_by_schedule ON schedule_runs (schedule_id, started_at);

CREATE TABLE notices (
	seq INTEGER PRIMARY KEY AUTOINCREMENT,
	id TEXT NOT NULL UNIQUE,
	kind TEXT NOT NULL,
	project_id TEXT NOT NULL,
	chat_id TEXT NOT NULL DEFAULT '',
	schedule_id TEXT NOT NULL DEFAULT '',
	run_id TEXT NOT NULL DEFAULT '',
	title TEXT NOT NULL DEFAULT '',
	may_contain_content INTEGER NOT NULL DEFAULT 0,
	created_at INTEGER NOT NULL
);
CREATE INDEX notices_by_time ON notices (created_at);

CREATE TABLE backfill_state (
	source TEXT NOT NULL,
	scope TEXT NOT NULL,
	cursor TEXT NOT NULL DEFAULT '',
	done INTEGER NOT NULL DEFAULT 0,
	imported INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL,
	PRIMARY KEY (source, scope)
);

CREATE VIRTUAL TABLE message_fts USING fts5 (
	search_text,
	content = 'messages',
	content_rowid = 'pk',
	tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
	INSERT INTO message_fts (rowid, search_text) VALUES (new.pk, new.search_text);
END;
CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages BEGIN
	INSERT INTO message_fts (message_fts, rowid, search_text) VALUES ('delete', old.pk, old.search_text);
END;
CREATE TRIGGER messages_fts_update AFTER UPDATE OF search_text ON messages WHEN old.search_text IS NOT new.search_text BEGIN
	INSERT INTO message_fts (message_fts, rowid, search_text) VALUES ('delete', old.pk, old.search_text);
	INSERT INTO message_fts (rowid, search_text) VALUES (new.pk, new.search_text);
END;
`

// archiveSchemaV2 adds a chat's relation to its parent ("continue") and the
// size and progress of a backfill pass.
const archiveSchemaV2 = `
ALTER TABLE chats ADD COLUMN relation TEXT NOT NULL DEFAULT '';
ALTER TABLE backfill_state ADD COLUMN chats INTEGER NOT NULL DEFAULT 0;
ALTER TABLE backfill_state ADD COLUMN chats_done INTEGER NOT NULL DEFAULT 0;
`

// archiveSchemaV3 marks runs started by hand and records when a run was due;
// notices keep their project's name; notice_ack holds the newest notice this
// Mac's app has handled.
const archiveSchemaV3 = `
ALTER TABLE schedule_runs ADD COLUMN manual INTEGER NOT NULL DEFAULT 0;
ALTER TABLE schedule_runs ADD COLUMN scheduled_at INTEGER;
ALTER TABLE notices ADD COLUMN project_name TEXT NOT NULL DEFAULT '';
CREATE TABLE notice_ack (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	seq INTEGER NOT NULL
);
`

// archiveSchemaV4 keeps each chat's title source and basis (chat names,
// chat_title.go); rows from before it have neither, and reads give them the
// source their title implies.
const archiveSchemaV4 = `
ALTER TABLE chats ADD COLUMN title_source TEXT NOT NULL DEFAULT '';
ALTER TABLE chats ADD COLUMN title_basis TEXT NOT NULL DEFAULT '';
`

// archiveSchemaV5 keeps what plain chats add to tool parts (docs/HOST-API.md
// "Sources and memory on tool parts"): tool_sources, the sources as a JSON
// list of {title, url}, and tool_memory_id and tool_memory_text, the entry a
// memory save stored; each is empty when the part has none, as parts from
// before it are.
const archiveSchemaV5 = `
ALTER TABLE parts ADD COLUMN tool_sources TEXT NOT NULL DEFAULT '';
ALTER TABLE parts ADD COLUMN tool_memory_id TEXT NOT NULL DEFAULT '';
ALTER TABLE parts ADD COLUMN tool_memory_text TEXT NOT NULL DEFAULT '';
`

// archiveSchemaV6 keeps the vault's progress (archive_vault.go): one row per
// vault folder and one per note part, attachment or hub written to it.
const archiveSchemaV6 = `
CREATE TABLE vault_state (
	vault_id TEXT PRIMARY KEY,
	root TEXT NOT NULL,
	cursor INTEGER NOT NULL DEFAULT 0,
	backfill_until INTEGER NOT NULL DEFAULT 0,
	backfill_total INTEGER NOT NULL DEFAULT 0,
	backfill_done INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL
);

CREATE TABLE vault_files (
	vault_id TEXT NOT NULL,
	entity TEXT NOT NULL,
	entity_id TEXT NOT NULL,
	part INTEGER NOT NULL,
	path TEXT NOT NULL,
	digest TEXT NOT NULL DEFAULT '',
	first_title TEXT NOT NULL DEFAULT '',
	listing TEXT NOT NULL DEFAULT '',
	written_at INTEGER NOT NULL,
	PRIMARY KEY (vault_id, entity, entity_id, part),
	UNIQUE (vault_id, path)
);
`

// archiveSchemaV7 keeps how each terminal ended (terminal_end.go): end_reason
// (programExited, endedByDevice, workspaceRemoved, hostStopped,
// connectionLost or hostInterrupted), ended_by_device_id (the device that
// ended it) and conversation_id (a Claude Code terminal's conversation).
// Rows from before it have none; a device reads their status instead.
const archiveSchemaV7 = `
ALTER TABLE terminal_logs ADD COLUMN end_reason TEXT NOT NULL DEFAULT '';
ALTER TABLE terminal_logs ADD COLUMN ended_by_device_id TEXT NOT NULL DEFAULT '';
ALTER TABLE terminal_logs ADD COLUMN conversation_id TEXT NOT NULL DEFAULT '';
CREATE INDEX terminal_logs_by_terminal ON terminal_logs (terminal_id, started_at);
`

// archiveSchemaV8 keeps the folder of a terminal outside any workspace
// (project_id '_none', archive_capture.go), so its log moves to the workspace
// that folder becomes (Archive.MoveProjectlessTerminalLogs). Other rows keep it
// empty.
const archiveSchemaV8 = `
ALTER TABLE terminal_logs ADD COLUMN folder TEXT NOT NULL DEFAULT '';
`

var errArchiveNewerSchema = errors.New("the archive was written by a newer AgentLand host; update the host before opening it")

// archiveSchemaVersion reads the recorded version; 0 means an empty database.
func archiveSchemaVersion(db *sql.DB) (int, error) {
	var tables int
	if err := db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'`).Scan(&tables); err != nil {
		return 0, err
	}
	if tables == 0 {
		return 0, nil
	}
	var version int
	if err := db.QueryRow(`SELECT schema_version FROM meta WHERE id = 1`).Scan(&version); err != nil {
		return 0, err
	}
	return version, nil
}

// migrateArchive brings the database to the newest schema. It runs on the
// writer connection before the writer starts, so nothing else writes then.
func migrateArchive(db *sql.DB, epoch string, now int64) error {
	version, err := archiveSchemaVersion(db)
	if err != nil {
		return err
	}
	if version > len(archiveMigrations) {
		return errArchiveNewerSchema
	}
	for next := version + 1; next <= len(archiveMigrations); next++ {
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		if err = archiveMigrations[next-1](tx, epoch, now); err == nil {
			_, err = tx.Exec(`UPDATE meta SET schema_version = ? WHERE id = 1`, next)
		}
		if err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("archive schema migration %d: %w", next, err)
		}
		if err = tx.Commit(); err != nil {
			return fmt.Errorf("archive schema migration %d: %w", next, err)
		}
	}
	return nil
}
