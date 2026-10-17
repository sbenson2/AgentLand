package host

import (
	"bytes"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
)

// archiveBlobFixture archives a message in the configured chat c1 with
// attachments: a picture, two files with one name, one known by name only
// and one whose stored type does not parse. The unconfigured chat c9 has a
// message with the picture too.
func archiveBlobFixture(t *testing.T) (*Host, *Archive, string, map[string]string) {
	t.Helper()
	host, archive, _, token := archiveRouteHost(t, ArchiveOptions{})
	seedArchive(t, archive)
	sums := map[string]string{}
	for name, content := range map[string]string{"shot": "\x89PNG\r\n\x1a\nfake picture", "notes1": "first notes", "notes2": "second notes", "odd": "<b>odd</b>"} {
		sum, err := archive.StoreBlob(strings.NewReader(content), "")
		if err != nil {
			t.Fatal(err)
		}
		sums[name] = sum
	}
	attach := func(message ArchiveMessage, parts ...ArchivePart) ArchiveMessage {
		message.Parts = append(message.Parts, parts...)
		return message
	}
	mustArchiveMessage(t, archive, attach(textMessage("c1", "m5", "user", 5, "see attached"),
		ArchivePart{ID: "a1", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "screen shot.png", MIME: "image/png", SHA256: sums["shot"]}},
		ArchivePart{ID: "a2", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "notes.txt", MIME: "text/plain", SHA256: sums["notes1"]}},
		ArchivePart{ID: "a3", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "notes.txt", MIME: "text/plain", SHA256: sums["notes2"]}},
		ArchivePart{ID: "a4", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "name only.pdf", MIME: "application/pdf"}},
		ArchivePart{ID: "a5", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "odd", MIME: "not a type", SHA256: sums["odd"]}},
	))
	rewound := attach(textMessage("c1", "m6", "user", 6, "rewound"),
		ArchivePart{ID: "a6", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "later.txt", MIME: "text/plain", SHA256: sums["notes2"]}})
	rewound.Hidden = true
	mustArchiveMessage(t, archive, rewound)
	mustArchiveMessage(t, archive, attach(textMessage("c9", "m19", "user", 1, "elsewhere"),
		ArchivePart{ID: "a9", Kind: "attachment", Attachment: &ArchiveAttachment{Name: "screen shot.png", MIME: "image/png", SHA256: sums["shot"]}}))
	flushArchive(t, archive)
	return host, archive, token, sums
}

func TestArchiveBlobRouteServesAttachmentsOfVisibleMessages(t *testing.T) {
	host, archive, token, sums := archiveBlobFixture(t)
	get := func(query string, header ...string) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest("GET", "/v1/archive/blob?"+query, nil)
		r.Header.Set("Authorization", "Bearer "+token)
		for index := 0; index+1 < len(header); index += 2 {
			r.Header.Set(header[index], header[index+1])
		}
		w := httptest.NewRecorder()
		host.Handler().ServeHTTP(w, r)
		return w
	}
	blob := func(chat, message, name string) string {
		return "chatId=" + url.QueryEscape(chat) + "&messageId=" + url.QueryEscape(message) + "&name=" + url.QueryEscape(name)
	}

	// The bytes, typed as stored, as a download the client names.
	w := get(blob("c1", "m5", "screen shot.png"))
	picture := "\x89PNG\r\n\x1a\nfake picture"
	for header, want := range map[string]string{
		"Content-Type":           "image/png",
		"Content-Length":         strconv.Itoa(len(picture)),
		"Content-Disposition":    `attachment; filename="screen shot.png"`,
		"X-Content-Type-Options": "nosniff",
		"Cache-Control":          "no-store",
		"ETag":                   `"` + sums["shot"] + `"`,
		"Accept-Ranges":          "bytes",
	} {
		if got := w.Header().Get(header); got != want {
			t.Errorf("%s: %q, want %q", header, got, want)
		}
	}
	if w.Code != 200 || w.Body.String() != picture {
		t.Fatalf("picture: %d %q", w.Code, w.Body)
	}

	// Of two attachments with one name the first is served, or the one with
	// the SHA-256 asked for; a SHA-256 of another attachment finds nothing.
	if w := get(blob("c1", "m5", "notes.txt")); w.Code != 200 || w.Body.String() != "first notes" || w.Header().Get("Content-Type") != "text/plain" {
		t.Fatalf("first notes: %d %q %v", w.Code, w.Body, w.Header())
	}
	if w := get(blob("c1", "m5", "notes.txt") + "&sha256=" + sums["notes2"]); w.Code != 200 || w.Body.String() != "second notes" {
		t.Fatalf("second notes: %d %q", w.Code, w.Body)
	}
	wantRouteError(t, "another attachment's hash", get(blob("c1", "m5", "notes.txt")+"&sha256="+sums["shot"]), 404, "not_found", "Attachment not found")

	// Ranges.
	if w := get(blob("c1", "m5", "notes.txt")+"&sha256="+sums["notes2"], "Range", "bytes=7-11"); w.Code != 206 || w.Body.String() != "notes" || w.Header().Get("Content-Range") != "bytes 7-11/12" {
		t.Fatalf("range: %d %q %v", w.Code, w.Body, w.Header())
	}
	if w := get(blob("c1", "m5", "notes.txt"), "Range", "bytes=50-60"); w.Code != 416 {
		t.Fatalf("range past the end: %d %q", w.Code, w.Body)
	}

	// A stored type that does not parse goes out as bytes.
	if w := get(blob("c1", "m5", "odd")); w.Code != 200 || w.Header().Get("Content-Type") != "application/octet-stream" || w.Body.String() != "<b>odd</b>" {
		t.Fatalf("odd type: %d %v", w.Code, w.Header())
	}

	// A rewound message's attachment is served, as chat pages show the message.
	if w := get(blob("c1", "m6", "later.txt")); w.Code != 200 || w.Body.String() != "second notes" {
		t.Fatalf("rewound message: %d %q", w.Code, w.Body)
	}

	for _, check := range []struct {
		label, query  string
		status        int
		code, message string
	}{
		{"known by name only", blob("c1", "m5", "name only.pdf"), 404, "attachment_not_archived", "This attachment's bytes were not archived"},
		{"unknown name", blob("c1", "m5", "missing.txt"), 404, "not_found", "Attachment not found"},
		{"another chat's message", blob("c1", "m19", "screen shot.png"), 404, "not_found", "Attachment not found"},
		{"a chat of a project no longer configured", blob("c9", "m19", "screen shot.png"), 404, "not_found", "Archived chat not found"},
		{"unknown chat", blob("nope", "m5", "screen shot.png"), 404, "not_found", "Archived chat not found"},
		{"no message", "chatId=c1&name=notes.txt", 400, "invalid_request", "Name the message and the attachment"},
		{"no name", "chatId=c1&messageId=m5", 400, "invalid_request", "Name the message and the attachment"},
		{"a bad hash", blob("c1", "m5", "notes.txt") + "&sha256=ABC", 400, "invalid_request", "Name the message and the attachment"},
		{"a long name", blob("c1", "m5", strings.Repeat("n", 257)), 400, "invalid_request", "Name the message and the attachment"},
	} {
		wantRouteError(t, check.label, get(check.query), check.status, check.code, check.message)
	}

	// A deleted chat's attachments are gone with it.
	if err := archive.DeleteChat("c1"); err != nil {
		t.Fatal(err)
	}
	wantRouteError(t, "deleted chat", get(blob("c1", "m5", "screen shot.png")), 404, "not_found", "Archived chat not found")
}

// The archive's own lookup, below the route.
func TestArchiveOpenAttachmentChecksTheMessage(t *testing.T) {
	_, archive, _, sums := archiveBlobFixture(t)
	ctx := t.Context()
	attachment, err := archive.OpenAttachment(ctx, "c1", "m5", "screen shot.png", "")
	if err != nil {
		t.Fatal(err)
	}
	defer attachment.File.Close()
	var data bytes.Buffer
	data.ReadFrom(attachment.File)
	if attachment.SHA256 != sums["shot"] || attachment.MIME != "image/png" || attachment.Size != int64(data.Len()) || attachment.Name != "screen shot.png" {
		t.Fatalf("attachment %+v (%d bytes)", attachment, data.Len())
	}
	// The same blob through a message that does not have it is not found.
	if _, err := archive.OpenAttachment(ctx, "c1", "m6", "screen shot.png", sums["shot"]); err != ErrNotFound {
		t.Fatalf("blob of another message: %v", err)
	}
}
