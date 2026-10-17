package host

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Notices in the archive (M5).
//
//	notices         What the host has to tell this Mac's app: a kind, IDs and
//	                a title, never message text. Kept 7 days, 1000 at most.
//	notice_ack      The newest notice the app has handled.
//
// Notices are queued (the host keeps the retained ones in memory and serves
// them from there); acknowledgements wait for their commit. These rows are
// not chats: they stay out of the change feed and the export. The table's
// schedule_id and run_id columns are left empty since schedules were removed
// (2026-10-06).

// ArchiveNotice is one notice. Seq is chosen by the host, after every
// sequence number the table has ever used.
type ArchiveNotice struct {
	Seq                                             int64
	ID, Kind, ProjectID, ProjectName, ChatID, Title string
	MayContainContent                               bool
	CreatedAt                                       time.Time
}

// RecordNotice queues a notice and removes those created before since and
// all but the newest keep.
func (a *Archive) RecordNotice(notice ArchiveNotice, since time.Time, keep int) error {
	if notice.Seq <= 0 {
		return archiveInvalid("notice seq")
	}
	for _, field := range []struct{ name, value string }{{"notice id", notice.ID}, {"notice kind", notice.Kind}, {"project id", notice.ProjectID}} {
		if err := archiveCheckID(field.name, field.value); err != nil {
			return err
		}
	}
	notice.Title = archiveLabel(notice.Title, archiveTitleLimit)
	notice.ProjectName = archiveLabel(notice.ProjectName, archiveTitleLimit)
	created := archiveTime(notice.CreatedAt).UnixMilli()
	return a.submit(&archiveOp{apply: func(t *archiveTx) error {
		if _, err := t.exec(`INSERT INTO notices (seq, id, kind, project_id, project_name, chat_id, title, may_contain_content, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING`,
			notice.Seq, notice.ID, notice.Kind, notice.ProjectID, notice.ProjectName, notice.ChatID,
			notice.Title, notice.MayContainContent, created); err != nil {
			return err
		}
		_, err := t.exec(`DELETE FROM notices WHERE created_at < ? OR seq <= (SELECT seq FROM notices ORDER BY seq DESC LIMIT 1 OFFSET ?)`, since.UnixMilli(), keep)
		return err
	}})
}

// ArchiveNoticeState is what the host reads when it starts: the retained
// notices (oldest first), the newest sequence number ever used and the
// newest one this Mac's app has handled.
type ArchiveNoticeState struct {
	Notices []ArchiveNotice
	Last    int64
	Acked   int64
}

// NoticeState reads the newest keep notices; the caller drops those past
// their time by its own clock.
func (a *Archive) NoticeState(ctx context.Context, keep int) (ArchiveNoticeState, error) {
	state := ArchiveNoticeState{Notices: []ArchiveNotice{}}
	rows, err := a.readDB.QueryContext(ctx, `SELECT seq, id, kind, project_id, project_name, chat_id, title, may_contain_content, created_at
		FROM notices ORDER BY seq DESC LIMIT ?`, keep)
	if err != nil {
		return state, err
	}
	for rows.Next() {
		var notice ArchiveNotice
		var created int64
		if err := rows.Scan(&notice.Seq, &notice.ID, &notice.Kind, &notice.ProjectID, &notice.ProjectName, &notice.ChatID, &notice.Title, &notice.MayContainContent, &created); err != nil {
			rows.Close()
			return state, err
		}
		notice.CreatedAt = time.UnixMilli(created).UTC()
		state.Notices = append(state.Notices, notice)
	}
	if err := rows.Close(); err != nil {
		return state, err
	}
	if err := rows.Err(); err != nil {
		return state, err
	}
	for left, right := 0, len(state.Notices)-1; left < right; left, right = left+1, right-1 {
		state.Notices[left], state.Notices[right] = state.Notices[right], state.Notices[left]
	}
	// sqlite_sequence remembers the largest seq even after its row is gone.
	err = a.readDB.QueryRowContext(ctx, `SELECT max(COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'notices'), 0), COALESCE((SELECT max(seq) FROM notices), 0))`).Scan(&state.Last)
	if err != nil {
		return state, err
	}
	err = a.readDB.QueryRowContext(ctx, `SELECT seq FROM notice_ack WHERE id = 1`).Scan(&state.Acked)
	if errors.Is(err, sql.ErrNoRows) {
		err = nil
	}
	return state, err
}

// AckNotices records that this Mac's app handled every notice through seq.
// The acknowledgement never moves back. It waits for the commit.
func (a *Archive) AckNotices(seq int64) error {
	return a.do(func(t *archiveTx) error {
		_, err := t.exec(`INSERT INTO notice_ack (id, seq) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET seq = max(seq, excluded.seq)`, seq)
		return err
	})
}
