package host

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"
)

// The vault's store (schema v6): its place in the change feed and the notes
// it wrote. The vault writer reads the feed raw, across every project, since
// its notes outlive a workspace's removal; it records its progress through
// the archive writer, and those writes are not changes, so they never wake
// the feed or the vault itself.

// vaultChange is one row of the change feed: an entity's latest change.
type vaultChange struct {
	Seq       int64
	Entity    string // chat, message or terminalLog
	EntityID  string
	ChatID    string // '' for terminal logs
	ProjectID string
	Op        string // upsert or delete
}

// vaultChangePage is one read of the feed: its rows, oldest first, and High,
// the newest seq the feed has assigned when it was read.
type vaultChangePage struct {
	Rows []vaultChange
	High int64
}

// vaultStateRecord is one vault folder's progress. Cursor is the newest
// changes.seq whose notes are written; BackfillUntil the newest seq when the
// vault was turned on, so changes up to it are its first write, of
// BackfillTotal notes.
type vaultStateRecord struct {
	VaultID       string
	Root          string
	Cursor        int64
	BackfillUntil int64
	BackfillTotal int64
	BackfillDone  int64
	UpdatedAt     time.Time
}

// vaultFileKey names one file the vault writes: a part of a chat or terminal
// note (parts count from 1), a hub, a Daily note, the README or an
// attachment.
type vaultFileKey struct {
	Entity   string
	EntityID string
	Part     int
}

// vaultFileRecord is where a file was written, relative to the vault's root,
// and the digest of the generated text it was given. FirstTitle is the title
// a note (or workspace) had when the vault first named it, which later titles
// keep as an alias. Listing is what hubs and Daily notes show of a chat's or
// terminal's note (its first part); other files have none.
type vaultFileRecord struct {
	vaultFileKey
	Path       string
	Digest     string
	FirstTitle string
	Listing    vaultListing
	WrittenAt  time.Time
}

// vaultListing is a note as hubs and Daily notes list it, as of its last
// write: its title (masked, as the note shows it), its chat provider (none
// for a terminal), its workspace, when it started and when it was last
// active (archive times; a running terminal's is empty). The vault keeps it,
// so a note stays listed after its chat is deleted.
type vaultListing struct {
	Title     string `json:"title"`
	Provider  string `json:"provider,omitempty"`
	ProjectID string `json:"projectId"`
	Started   string `json:"started"`
	Active    string `json:"active,omitempty"`
}

// vaultChangeRows reads up to limit changes after the seq after, across
// every project, oldest first.
func (a *Archive) vaultChangeRows(ctx context.Context, after int64, limit int) (vaultChangePage, error) {
	page := vaultChangePage{Rows: []vaultChange{}}
	tx, err := a.readDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return page, err
	}
	defer tx.Rollback()
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'changes'), 0)`).Scan(&page.High); err != nil {
		return page, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT seq, entity, entity_id, chat_id, project_id, op FROM changes WHERE seq > ? ORDER BY seq LIMIT ?`, after, limit)
	if err != nil {
		return page, err
	}
	for rows.Next() {
		var row vaultChange
		if err := rows.Scan(&row.Seq, &row.Entity, &row.EntityID, &row.ChatID, &row.ProjectID, &row.Op); err != nil {
			rows.Close()
			return page, err
		}
		page.Rows = append(page.Rows, row)
	}
	if err := rows.Close(); err != nil {
		return page, err
	}
	return page, rows.Err()
}

// vaultState reads a vault's progress; sql.ErrNoRows when it has none.
func (a *Archive) vaultState(ctx context.Context, vaultID string) (vaultStateRecord, error) {
	state := vaultStateRecord{VaultID: vaultID}
	var updated int64
	err := a.readDB.QueryRowContext(ctx, `SELECT root, cursor, backfill_until, backfill_total, backfill_done, updated_at FROM vault_state WHERE vault_id = ?`, vaultID).
		Scan(&state.Root, &state.Cursor, &state.BackfillUntil, &state.BackfillTotal, &state.BackfillDone, &updated)
	state.UpdatedAt = time.UnixMilli(updated).UTC()
	return state, err
}

const vaultFileSelect = `SELECT entity, entity_id, part, path, digest, first_title, listing, written_at FROM vault_files `

// vaultScanner is a *sql.Row or *sql.Rows.
type vaultScanner interface {
	Scan(dest ...any) error
}

func scanVaultFile(row vaultScanner) (vaultFileRecord, error) {
	var file vaultFileRecord
	var listing string
	var written int64
	err := row.Scan(&file.Entity, &file.EntityID, &file.Part, &file.Path, &file.Digest, &file.FirstTitle, &listing, &written)
	if err == nil && listing != "" {
		// A listing that does not read is none: the note's next write
		// records it again.
		_ = json.Unmarshal([]byte(listing), &file.Listing)
	}
	file.WrittenAt = time.UnixMilli(written).UTC()
	return file, err
}

// vaultFile reads where a vault wrote one file; sql.ErrNoRows when it has
// not.
func (a *Archive) vaultFile(ctx context.Context, vaultID string, key vaultFileKey) (vaultFileRecord, error) {
	return scanVaultFile(a.readDB.QueryRowContext(ctx, vaultFileSelect+`WHERE vault_id = ? AND entity = ? AND entity_id = ? AND part = ?`,
		vaultID, key.Entity, key.EntityID, key.Part))
}

// vaultFileAt reads which file a vault wrote at path; sql.ErrNoRows when
// none.
func (a *Archive) vaultFileAt(ctx context.Context, vaultID, path string) (vaultFileRecord, error) {
	return scanVaultFile(a.readDB.QueryRowContext(ctx, vaultFileSelect+`WHERE vault_id = ? AND path = ?`, vaultID, path))
}

// vaultFiles reads the first parts of the files a vault wrote for the given
// entities (such as its chat and terminal notes, or its hubs), in path order.
func (a *Archive) vaultFiles(ctx context.Context, vaultID string, entities ...string) ([]vaultFileRecord, error) {
	files := []vaultFileRecord{}
	if len(entities) == 0 {
		return files, nil
	}
	rows, err := a.readDB.QueryContext(ctx, vaultFileSelect+`WHERE vault_id = ? AND part = 1 AND entity IN (`+archivePlaceholders(len(entities))+`) ORDER BY path`,
		append([]any{vaultID}, archiveArgs(entities)...)...)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		file, err := scanVaultFile(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		files = append(files, file)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	return files, rows.Err()
}

// saveVault records a vault's progress in one commit: its state, the files
// it wrote (a file's record replaces the one it had, so a note has one path)
// and the records it no longer keeps, removed first so a path they held can
// be taken in the same batch. Only records change: no file is touched. Two
// files at one path refuse the whole batch.
func (a *Archive) saveVault(state vaultStateRecord, files []vaultFileRecord, removed []vaultFileKey) error {
	if err := archiveCheckID("vault id", state.VaultID); err != nil {
		return err
	}
	for _, key := range removed {
		if err := key.check(); err != nil {
			return err
		}
	}
	for _, file := range files {
		if err := file.check(); err != nil {
			return err
		}
		if file.Path == "" {
			return archiveInvalid("vault path")
		}
	}
	return a.do(func(t *archiveTx) error {
		if _, err := t.exec(`INSERT INTO vault_state (vault_id, root, cursor, backfill_until, backfill_total, backfill_done, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT (vault_id) DO UPDATE SET root = excluded.root, cursor = excluded.cursor, backfill_until = excluded.backfill_until,
			backfill_total = excluded.backfill_total, backfill_done = excluded.backfill_done, updated_at = excluded.updated_at`,
			state.VaultID, state.Root, state.Cursor, state.BackfillUntil, state.BackfillTotal, state.BackfillDone, t.now); err != nil {
			return err
		}
		for _, key := range removed {
			if _, err := t.exec(`DELETE FROM vault_files WHERE vault_id = ? AND entity = ? AND entity_id = ? AND part = ?`,
				state.VaultID, key.Entity, key.EntityID, key.Part); err != nil {
				return err
			}
		}
		for _, file := range files {
			listing := ""
			if file.Listing != (vaultListing{}) {
				encoded, err := json.Marshal(file.Listing)
				if err != nil {
					return err
				}
				listing = string(encoded)
			}
			if _, err := t.exec(`INSERT INTO vault_files (vault_id, entity, entity_id, part, path, digest, first_title, listing, written_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
				ON CONFLICT (vault_id, entity, entity_id, part) DO UPDATE SET path = excluded.path, digest = excluded.digest,
				first_title = excluded.first_title, listing = excluded.listing, written_at = excluded.written_at`,
				state.VaultID, file.Entity, file.EntityID, file.Part, file.Path, file.Digest, file.FirstTitle, listing, t.now); err != nil {
				return err
			}
		}
		return nil
	})
}

// vaultAt finds the vault that last wrote in folder (its recorded root):
// its ID, or "" when none did.
func (a *Archive) vaultAt(ctx context.Context, folder string) (string, error) {
	var id string
	err := a.readDB.QueryRowContext(ctx, `SELECT vault_id FROM vault_state WHERE root = ? ORDER BY updated_at DESC LIMIT 1`, folder).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// resetVault makes a vault read the change feed again from its start, as when
// it was turned on: its cursor and backfill go back, so its next writer
// renders every chat and terminal again and writes the notes whose text
// differs from what it recorded. With rewrite, it also forgets what it wrote:
// the recorded digests of its notes and hubs are cleared and its attachments'
// records dropped, so every note is compared with its file again and a note
// or image the user deleted comes back. Paths, first titles and listings
// stay, so notes keep their names; the README's record stays (it is written
// once), and a workspace's reserved hub stays reserved. No file is touched.
// Call it while no writer runs for the vault.
func (a *Archive) resetVault(vaultID string, rewrite bool) error {
	if err := archiveCheckID("vault id", vaultID); err != nil {
		return err
	}
	return a.do(func(t *archiveTx) error {
		if _, err := t.exec(`UPDATE vault_state SET cursor = 0, backfill_until = -1, backfill_total = 0, backfill_done = 0, updated_at = ? WHERE vault_id = ?`, t.now, vaultID); err != nil {
			return err
		}
		if !rewrite {
			return nil
		}
		if _, err := t.exec(`UPDATE vault_files SET digest = '' WHERE vault_id = ? AND entity IN ('chat', 'terminalLog', 'workspace', 'provider', 'daily')`, vaultID); err != nil {
			return err
		}
		_, err := t.exec(`DELETE FROM vault_files WHERE vault_id = ? AND entity = 'attachment'`, vaultID)
		return err
	})
}

// vaultNoteCount counts the chat and terminal notes a vault has written.
func (a *Archive) vaultNoteCount(ctx context.Context, vaultID string) (int64, error) {
	var count int64
	err := a.readDB.QueryRowContext(ctx, `SELECT count(*) FROM vault_files WHERE vault_id = ? AND entity IN ('chat', 'terminalLog') AND part = 1`, vaultID).Scan(&count)
	return count, err
}

func (key vaultFileKey) check() error {
	if err := archiveCheckID("vault entity", key.Entity); err != nil {
		return err
	}
	if err := archiveCheckID("vault entity id", key.EntityID); err != nil {
		return err
	}
	if key.Part < 1 {
		return archiveInvalid("vault part")
	}
	return nil
}
