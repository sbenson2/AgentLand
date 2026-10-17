package host

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"
)

// ChatTitleStore keeps the names the host gave chats (docs/HOST-API.md
// "Chat names"). For OpenCode chats it keeps the host's auto titles, which
// OpenCode never holds, and the device names it wrote to OpenCode, so an
// OpenCode title can be told apart from the host's; these are saved in
// <state>.titles.json. Claude Code and Codex chats keep their names in the
// chats registry; the store holds the latest one named while the host runs
// only in memory, so the chat hub, which may not read the registry under
// its lock, applies it over a read that began before the name changed.
//
// Its lock is taken last: nothing is called while it is held.
type ChatTitleStore struct {
	mu      sync.Mutex
	path    string
	saved   map[string]*chatTitleRecord
	memory  map[string]*chatTitleRecord
	pending map[string]chatName
	now     func() time.Time
	// limit bounds the saved names (chatTitleSavedLimit; tests lower it).
	limit int
}

type chatTitleRecord struct {
	ProjectID string `json:"projectId"`
	Title     string `json:"title"`
	Source    string `json:"titleSource"`
	Basis     string `json:"titleBasis,omitempty"`
	// Previous is the title OpenCode had when the host wrote a device name:
	// an OpenCode update that still carries it came before the rename.
	Previous string    `json:"previousTitle,omitempty"`
	At       time.Time `json:"at"`
}

type chatTitleFile struct {
	Version int                         `json:"version"`
	Chats   map[string]*chatTitleRecord `json:"chats"`
}

const (
	chatTitleFileVersion = 1
	// chatTitleSavedLimit bounds the saved OpenCode names; the least
	// recently named are forgotten first. chatTitleMemoryLimit bounds the
	// in-memory names of Claude Code and Codex chats.
	chatTitleSavedLimit  = 2048
	chatTitleMemoryLimit = 4096
)

// NewChatTitleStore reads <state>.titles.json; a missing file is an empty
// store. A file written by a newer host is refused rather than overwritten.
func NewChatTitleStore(path string) (*ChatTitleStore, error) {
	store := newMemoryChatTitleStore()
	store.path = path
	data, err := readPrivateState(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, err
	}
	var file chatTitleFile
	if err := json.Unmarshal(data, &file); err != nil {
		return nil, err
	}
	if file.Version > chatTitleFileVersion {
		return nil, fmt.Errorf("chat titles were written by a newer AgentLand host (version %d)", file.Version)
	}
	for id, record := range file.Chats {
		if record != nil && id != "" && (record.Source == titleAuto || record.Source == titleDevice) {
			store.saved[id] = record
		}
	}
	return store, nil
}

// newMemoryChatTitleStore keeps names in memory only (hosts without a state
// path, tests).
func newMemoryChatTitleStore() *ChatTitleStore {
	return &ChatTitleStore{saved: map[string]*chatTitleRecord{}, memory: map[string]*chatTitleRecord{}, pending: map[string]chatName{}, now: time.Now, limit: chatTitleSavedLimit}
}

// resolveOpenCode is the name the host shows for an OpenCode chat whose
// OpenCode title is raw:
//   - a device name being written to OpenCode, when raw is its echo;
//   - the host's auto title while OpenCode still has a placeholder;
//   - a device name the host wrote, while OpenCode has it, a placeholder,
//     or the title it had just before the rename (a late update);
//   - otherwise raw itself: "default" for a placeholder, else "provider".
func (s *ChatTitleStore) resolveOpenCode(chatID, raw string) chatName {
	if s != nil {
		s.mu.Lock()
		defer s.mu.Unlock()
		if pending, ok := s.pending[chatID]; ok && raw == pending.Title {
			return pending
		}
		if record := s.saved[chatID]; record != nil {
			name := chatName{Title: record.Title, Source: record.Source, Basis: record.Basis}
			switch record.Source {
			case titleAuto:
				if isPlaceholderTitle(raw) || (record.Previous != "" && raw == record.Previous) {
					return name
				}
			case titleDevice:
				if raw == record.Title || isPlaceholderTitle(raw) || (record.Previous != "" && raw == record.Previous) {
					return name
				}
			}
		}
	}
	return chatName{Title: raw, Source: titleSourceFor(raw)}
}

// memoryName is the latest name of a Claude Code or Codex chat named while
// the host runs.
func (s *ChatTitleStore) memoryName(chatID string) (chatName, bool) {
	if s == nil {
		return chatName{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record := s.memory[chatID]
	if record == nil {
		return chatName{}, false
	}
	return chatName{Title: record.Title, Source: record.Source, Basis: record.Basis}, true
}

// setOpenCode keeps an OpenCode chat's auto title or device name and saves
// the store. previous is OpenCode's title before a device rename. The name
// holds in memory even when saving fails.
func (s *ChatTitleStore) setOpenCode(chatID, projectID string, name chatName, previous string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.saved[chatID] = &chatTitleRecord{ProjectID: projectID, Title: name.Title, Source: name.Source, Basis: name.Basis, Previous: previous, At: s.now().UTC()}
	forgetOldest(s.saved, s.limit)
	return s.saveLocked()
}

// setMemory keeps a Claude Code or Codex chat's new name for the hub.
func (s *ChatTitleStore) setMemory(chatID, projectID string, name chatName) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.memory[chatID] = &chatTitleRecord{ProjectID: projectID, Title: name.Title, Source: name.Source, Basis: name.Basis, At: s.now().UTC()}
	forgetOldest(s.memory, chatTitleMemoryLimit)
}

// beginRename marks a device name the host is writing to OpenCode, so the
// echo OpenCode sends before the write is answered already counts as it;
// endRename clears the mark.
func (s *ChatTitleStore) beginRename(chatID string, name chatName) {
	s.mu.Lock()
	s.pending[chatID] = name
	s.mu.Unlock()
}

func (s *ChatTitleStore) endRename(chatID string) {
	s.mu.Lock()
	delete(s.pending, chatID)
	s.mu.Unlock()
}

func forgetOldest(records map[string]*chatTitleRecord, limit int) {
	if len(records) <= limit {
		return
	}
	ids := make([]string, 0, len(records))
	for id := range records {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool {
		if !records[ids[i]].At.Equal(records[ids[j]].At) {
			return records[ids[i]].At.Before(records[ids[j]].At)
		}
		return ids[i] < ids[j]
	})
	for _, id := range ids[:len(ids)-limit] {
		delete(records, id)
	}
}

func (s *ChatTitleStore) saveLocked() error {
	if s.path == "" {
		return nil
	}
	data, err := json.Marshal(chatTitleFile{Version: chatTitleFileVersion, Chats: s.saved})
	if err != nil {
		return err
	}
	return writePrivateState(s.path, append(data, '\n'))
}
