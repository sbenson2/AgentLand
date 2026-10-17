package host

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"os"
	"time"
)

// Attachment bytes on demand: GET /v1/archive/blob?chatId&messageId&name
// [&sha256] (docs/HOST-API.md, "Archive"). Devices keep attachment names
// only and fetch an attachment's bytes when someone opens it. A blob is
// served only as an attachment of a message in a chat the device may read:
// the chat must be archived in a configured project, the message must be
// that chat's, and one of its attachment parts must carry that name (and
// that SHA-256, when given) and reference the blob. A blob is never served
// by its hash alone.

var errArchiveBlobMissing = errors.New("the attachment's bytes were not archived")

// ArchivedAttachment is one attachment's archived bytes, open for reading.
// The caller closes File.
type ArchivedAttachment struct {
	File   *os.File
	Name   string
	MIME   string
	Size   int64
	SHA256 string
}

// OpenAttachment opens the bytes of the attachment called name in the chat's
// message: the first such attachment with archived bytes, or the one whose
// SHA-256 is sha when sha is set. Hidden (rewound) messages count, as chat
// pages show them. It reports ErrNotFound when the message has no such
// attachment and errArchiveBlobMissing when it has one without bytes (the
// capture was paused, or the backfill knew the file by name only).
func (a *Archive) OpenAttachment(ctx context.Context, chatID, messageID, name, sha string) (ArchivedAttachment, error) {
	rows, err := a.readDB.QueryContext(ctx, `SELECT p.attachment_name, p.attachment_mime, p.blob_sha256, b.size, b.mime
		FROM parts p JOIN messages m ON m.pk = p.message_pk LEFT JOIN blobs b ON b.sha256 = p.blob_sha256
		WHERE m.chat_id = ? AND m.id = ? AND p.attachment_name = ? ORDER BY p.ord`, chatID, messageID, name)
	if err != nil {
		return ArchivedAttachment{}, err
	}
	found := false
	var chosen ArchivedAttachment
	for rows.Next() {
		var partName, partMIME string
		var blob, blobMIME sql.NullString
		var size sql.NullInt64
		if err := rows.Scan(&partName, &partMIME, &blob, &size, &blobMIME); err != nil {
			rows.Close()
			return ArchivedAttachment{}, err
		}
		if sha != "" && blob.String != sha {
			continue
		}
		found = true
		if chosen.SHA256 == "" && blob.Valid && size.Valid {
			chosen = ArchivedAttachment{Name: partName, MIME: partMIME, Size: size.Int64, SHA256: blob.String}
			if chosen.MIME == "" {
				chosen.MIME = blobMIME.String
			}
		}
	}
	if err := rows.Close(); err != nil {
		return ArchivedAttachment{}, err
	}
	if err := rows.Err(); err != nil {
		return ArchivedAttachment{}, err
	}
	switch {
	case !found:
		return ArchivedAttachment{}, ErrNotFound
	case chosen.SHA256 == "":
		return ArchivedAttachment{}, errArchiveBlobMissing
	}
	file, err := a.openBlob(chosen.SHA256, chosen.Size)
	if err != nil {
		return ArchivedAttachment{}, err
	}
	chosen.File = file
	return chosen, nil
}

// openBlob opens blobs/<ab>/<sha256>: a regular file, never a symlink, of the
// recorded size and at most the archive's 64 MiB per attachment. A file
// collected or never written reads as missing.
func (a *Archive) openBlob(sum string, size int64) (*os.File, error) {
	if !archiveValidSHA(sum) {
		return nil, errArchiveBlobMissing
	}
	path := a.blobPath(sum)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, errArchiveBlobMissing
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("archive blob %s is not a regular file", sum)
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, errArchiveBlobMissing
	}
	if err != nil {
		return nil, err
	}
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) || opened.Size() != size || size > archiveBlobLimit {
		file.Close()
		if err == nil {
			err = fmt.Errorf("archive blob %s changed or has the wrong size", sum)
		}
		return nil, err
	}
	return file, nil
}

// archiveBlobContentType is the stored type when it parses as a media type,
// else application/octet-stream.
func archiveBlobContentType(stored string) string {
	mediaType, params, err := mime.ParseMediaType(stored)
	if err != nil || mediaType == "" {
		return "application/octet-stream"
	}
	if formatted := mime.FormatMediaType(mediaType, params); formatted != "" {
		return formatted
	}
	return "application/octet-stream"
}

// archiveDeadlineResponse extends the connection's write deadline as a long
// response makes progress, at most once a second (see archiveDeadlineWriter).
type archiveDeadlineResponse struct {
	http.ResponseWriter
	controller *http.ResponseController
	extended   time.Time
}

func (d *archiveDeadlineResponse) Write(data []byte) (int, error) {
	if now := time.Now(); now.Sub(d.extended) >= time.Second {
		d.extended = now
		_ = d.controller.SetWriteDeadline(now.Add(archiveExportWriteWindow))
	}
	return d.ResponseWriter.Write(data)
}

// archiveBlob serves one archived attachment's bytes, with Range support.
func (h *Host) archiveBlob(w http.ResponseWriter, r *http.Request) {
	if !h.archiveAvailable(w) {
		return
	}
	query := r.URL.Query()
	messageID, name, sha := query.Get("messageId"), query.Get("name"), query.Get("sha256")
	if messageID == "" || len(messageID) > archiveIDLimit || name == "" || len(name) > archiveLabelLimit || (sha != "" && !archiveValidSHA(sha)) {
		writeError(w, 400, "invalid_request", "Name the message and the attachment")
		return
	}
	chat, ok := h.visibleArchivedChat(w, r, query.Get("chatId"))
	if !ok {
		return
	}
	attachment, err := h.archive.OpenAttachment(r.Context(), chat.ID, messageID, name, sha)
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, 404, "not_found", "Attachment not found")
		return
	case errors.Is(err, errArchiveBlobMissing):
		writeError(w, 404, "attachment_not_archived", "This attachment's bytes were not archived")
		return
	case err != nil:
		archiveFailure(w)
		return
	}
	defer attachment.File.Close()
	filename := mime.FormatMediaType("attachment", map[string]string{"filename": attachment.Name})
	if filename == "" {
		filename = "attachment"
	}
	header := w.Header()
	header.Set("Content-Type", archiveBlobContentType(attachment.MIME))
	header.Set("Content-Disposition", filename)
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("ETag", `"`+attachment.SHA256+`"`)
	http.ServeContent(&archiveDeadlineResponse{ResponseWriter: w, controller: http.NewResponseController(w)}, r, "", time.Time{}, attachment.File)
}
