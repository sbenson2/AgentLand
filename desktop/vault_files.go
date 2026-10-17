package host

import (
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Vault note files. A note is AgentLand's generated text, the marker line,
// then whatever the user writes below the marker, which every rewrite keeps:
//
//	---
//	agentland-id: "chat/ses_8f2k3f9a2c"
//	…
//	---
//	# Wire the vault status into Settings
//	…
//
//	%% agentland:end %%
//	The user's own text.
//
// Notes are written through the vault folder's os.Root, so no path or link
// inside the vault leads out of it: a private temporary file beside the note
// is written, synced and renamed over the note, then the folder is synced.

const (
	vaultEndMarker = "%% agentland:end %%"
	// vaultEscapedMarker stands for a copy of the marker inside generated
	// text: the zero-width space after its first "%%" keeps it an Obsidian
	// comment, but it no longer ends AgentLand's part.
	vaultEscapedMarker = "%%​ agentland:end %%"
	// A note's name holds at most vaultNameLimit characters and
	// vaultNameBytes bytes of its title, so with its date, short ID and part
	// it stays within the 255 bytes file systems allow.
	vaultNameLimit     = 60
	vaultNameBytes     = 180
	vaultShortIDLength = 6
	// vaultNoteReadLimit is the largest note read back; a larger file has
	// become the user's.
	vaultNoteReadLimit = 64 << 20
	vaultTempPrefix    = ".agentland-tmp-"
)

var (
	errVaultNotOurs = errors.New("another file is at the note's path")
	errVaultChanged = errors.New("the note changed while it was written")
	errVaultPath    = errors.New("invalid vault path")
)

// vaultBeforeRename runs in tests once a note's temporary file is complete,
// before it replaces the note.
var vaultBeforeRename func(rel string)

// Names.

// vaultUnsafe holds what a note name leaves out: characters file systems
// refuse and those Obsidian links give a meaning.
const vaultUnsafe = `/\:*?"<>|#^[]`

// vaultSafeName makes a title usable as a file name: unsafe characters and
// controls become spaces, runs of spaces one, leading dots and trailing dots
// and spaces go, and it is cut to vaultNameLimit characters. It is empty
// when nothing is left. (Titles are not normalized to NFC: the standard
// library has no normalizer and the vault adds no module. A note's name is
// recorded once, so the same chat always keeps the same name.)
func vaultSafeName(text string) string {
	text = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || strings.ContainsRune(vaultUnsafe, r) {
			return ' '
		}
		return r
	}, strings.ToValidUTF8(text, ""))
	text = strings.TrimLeft(strings.Join(strings.Fields(text), " "), ". ")
	if utf8.RuneCountInString(text) > vaultNameLimit {
		text = string([]rune(text)[:vaultNameLimit])
	}
	text, _ = archiveClip(text, vaultNameBytes)
	return strings.TrimRight(text, ". ")
}

// vaultShortID is the start of the base32hex (lower case) SHA-256 of an ID:
// six characters name a note, more when two notes would share a name.
func vaultShortID(id string, length int) string {
	sum := sha256.Sum256([]byte(id))
	encoded := strings.ToLower(base32.HexEncoding.WithPadding(base32.NoPadding).EncodeToString(sum[:]))
	return encoded[:min(max(length, 1), len(encoded))]
}

// vaultNoteBase is a note's name without ".md": the day it started (in the
// time's own zone), its title made safe ("Untitled" when nothing is left)
// and the short ID of id.
func vaultNoteBase(started time.Time, title, id string, idLength int) string {
	name := vaultSafeName(title)
	if name == "" {
		name = "Untitled"
	}
	return started.Format("2006-01-02") + " " + name + " (" + vaultShortID(id, idLength) + ")"
}

// vaultPartBase names a note's later parts: "<base> part 2" and on.
func vaultPartBase(base string, part int) string {
	if part <= 1 {
		return base
	}
	return base + " part " + strconv.Itoa(part)
}

// Content.

// vaultMarkerLine says whether a line is the marker; trailing spaces and a
// CR (an editor's line endings) do not count.
func vaultMarkerLine(line string) bool {
	return strings.TrimRight(line, " \t\r") == vaultEndMarker
}

// splitUserTail splits a note at its first marker line: head is the text
// before that line and tail the text after it. Without a marker the whole
// note is head.
func splitUserTail(content string) (head, tail string, found bool) {
	for start := 0; start < len(content); {
		line, next := content[start:], len(content)
		if end := strings.IndexByte(line, '\n'); end >= 0 {
			line, next = line[:end], start+end+1
		}
		if vaultMarkerLine(line) {
			return content[:start], content[next:], true
		}
		start = next
	}
	return content, "", false
}

// vaultEscapeMarkers replaces each line of generated text that would read as
// the marker.
func vaultEscapeMarkers(text string) string {
	if !strings.Contains(text, vaultEndMarker) {
		return text
	}
	lines := strings.Split(text, "\n")
	for index, line := range lines {
		if vaultMarkerLine(line) {
			lines[index] = vaultEscapedMarker
		}
	}
	return strings.Join(lines, "\n")
}

// vaultNoteHead is what a note holds above its marker for generated text:
// the text with its marker copies escaped, then one empty line.
func vaultNoteHead(generated string) string {
	return vaultEscapeMarkers(strings.TrimRight(generated, "\n")) + "\n\n"
}

func vaultDigest(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// vaultNoteID reads agentland-id from a note's frontmatter (the lines
// between a first line "---" and the next "---"), quoted or not, as
// Obsidian may rewrite it. It is empty when there is none.
func vaultNoteID(content string) string {
	rest, ok := strings.CutPrefix(content, "---\n")
	if !ok {
		if rest, ok = strings.CutPrefix(content, "---\r\n"); !ok {
			return ""
		}
	}
	id := ""
	for rest != "" {
		line, after, _ := strings.Cut(rest, "\n")
		rest = after
		line = strings.TrimRight(line, " \t\r")
		if line == "---" {
			return id
		}
		value, found := strings.CutPrefix(line, "agentland-id:")
		if !found || id != "" {
			continue
		}
		value = strings.TrimSpace(value)
		switch {
		case strings.HasPrefix(value, `"`):
			_ = json.Unmarshal([]byte(value), &id)
		case len(value) >= 2 && value[0] == '\'' && value[len(value)-1] == '\'':
			id = strings.ReplaceAll(value[1:len(value)-1], "''", "'")
		default:
			id = value
		}
	}
	return ""
}

// Writing.

// vaultNote is one note to write.
type vaultNote struct {
	Path      string // relative to the vault's root, with forward slashes
	ID        string // its agentland-id, such as chat/ses_8f2k3f9a2c
	Generated string // AgentLand's text, above the marker
	// Recorded says the vault's records (vault_files) hold this path for
	// this note, and Digest is the digest recorded with it.
	Recorded bool
	Digest   string
}

type vaultOutcome int

const (
	vaultWritten    vaultOutcome = iota // the note holds the generated text now
	vaultUnchanged                      // it already did; nothing was written
	vaultUserEdited                     // its marker is gone and so is the text last written: left alone
	vaultEvicted                        // iCloud keeps its data elsewhere: left alone until it is back
)

// writeNote writes a note's generated text above its marker and keeps what
// is below the marker. It returns the outcome and, unless the note was left
// alone, the digest of the text above the marker (vaultDigest of
// vaultNoteHead), which the caller records.
//
// A file already at the path is replaced only when it is this note: it is
// recorded, or its frontmatter carries the note's agentland-id (a write whose
// record was lost, or a note found again after a move); anything else is
// errVaultNotOurs. Of the note, a file with the marker keeps its tail; one
// without it is replaced only when it is still the text last written, and
// is otherwise the user's (vaultUserEdited). A note that changes while it is
// written stays as it is: errVaultChanged, and the caller tries again later.
func writeNote(root *os.Root, note vaultNote) (vaultOutcome, string, error) {
	rel := filepath.FromSlash(note.Path)
	if note.Path == "" || !filepath.IsLocal(rel) {
		return 0, "", errVaultPath
	}
	folder := filepath.Dir(rel)
	if folder != "." {
		if err := root.MkdirAll(folder, 0o700); err != nil {
			return 0, "", err
		}
	}
	head := vaultNoteHead(note.Generated)
	digest := vaultDigest(head)
	tail := ""
	before, err := root.Lstat(rel)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return 0, "", err
	}
	if exists {
		if !before.Mode().IsRegular() {
			return 0, "", errVaultNotOurs
		}
		if vaultDataless(before) {
			return vaultEvicted, "", nil
		}
		if before.Size() > vaultNoteReadLimit {
			return vaultUserEdited, "", nil
		}
		content, err := root.ReadFile(rel)
		if err != nil {
			return 0, "", err
		}
		if !note.Recorded && vaultNoteID(string(content)) != note.ID {
			return 0, "", errVaultNotOurs
		}
		existingHead, existingTail, found := splitUserTail(string(content))
		switch {
		case found && existingHead == head:
			return vaultUnchanged, digest, nil
		case found:
			tail = existingTail
		case note.Recorded && note.Digest != "" && vaultDigest(string(content)) == note.Digest:
			// Only the marker went, and nothing below it.
		default:
			return vaultUserEdited, "", nil
		}
	}

	temp := filepath.Join(folder, vaultTempPrefix+archiveRandomID(8))
	file, err := root.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return 0, "", err
	}
	renamed := false
	defer func() {
		if !renamed {
			_ = root.Remove(temp)
		}
	}()
	_, err = io.WriteString(file, head+vaultEndMarker+"\n"+tail)
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return 0, "", err
	}
	if vaultBeforeRename != nil {
		vaultBeforeRename(note.Path)
	}
	// The note must still be as it was read: a save in Obsidian meanwhile
	// wins over this write.
	after, err := root.Lstat(rel)
	if exists {
		if err != nil || !os.SameFile(before, after) || !after.ModTime().Equal(before.ModTime()) || after.Size() != before.Size() {
			return 0, "", errVaultChanged
		}
	} else if err == nil {
		return 0, "", errVaultChanged
	} else if !errors.Is(err, os.ErrNotExist) {
		return 0, "", err
	}
	if err := root.Rename(temp, rel); err != nil {
		return 0, "", err
	}
	renamed = true
	directory, err := root.Open(folder)
	if err != nil {
		return 0, "", err
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return 0, "", err
	}
	return vaultWritten, digest, nil
}

// writeVaultFile copies a file the vault keeps beside its notes, such as an
// image, to its path through root, as writeNote writes a note: a private
// temporary file, synced, then renamed. A file already at the path is left as
// it is (an attachment's name starts with its digest, so it is the same
// file). It reports whether it wrote the file.
func writeVaultFile(root *os.Root, path string, content io.Reader) (bool, error) {
	return putVaultFile(root, path, content, false)
}

// replaceVaultFile writes a file of the vault's own, such as its marker, in
// place of whatever regular file is at its path, as writeVaultFile writes.
func replaceVaultFile(root *os.Root, path string, content []byte) error {
	_, err := putVaultFile(root, path, strings.NewReader(string(content)), true)
	return err
}

func putVaultFile(root *os.Root, path string, content io.Reader, replace bool) (bool, error) {
	rel := filepath.FromSlash(path)
	if path == "" || !filepath.IsLocal(rel) {
		return false, errVaultPath
	}
	folder := filepath.Dir(rel)
	if folder != "." {
		if err := root.MkdirAll(folder, 0o700); err != nil {
			return false, err
		}
	}
	exists := func() (bool, error) {
		info, err := root.Lstat(rel)
		switch {
		case errors.Is(err, os.ErrNotExist):
			return false, nil
		case err != nil:
			return false, err
		case replace && !info.Mode().IsRegular():
			return false, errVaultNotOurs
		}
		return !replace, nil
	}
	if found, err := exists(); found || err != nil {
		return false, err
	}
	temp := filepath.Join(folder, vaultTempPrefix+archiveRandomID(8))
	file, err := root.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false, err
	}
	renamed := false
	defer func() {
		if !renamed {
			_ = root.Remove(temp)
		}
	}()
	_, err = io.Copy(file, content)
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return false, err
	}
	if found, err := exists(); found || err != nil {
		return false, err
	}
	if err := root.Rename(temp, rel); err != nil {
		return false, err
	}
	renamed = true
	directory, err := root.Open(folder)
	if err != nil {
		return false, err
	}
	defer directory.Close()
	return true, directory.Sync()
}
