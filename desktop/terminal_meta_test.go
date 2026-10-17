package host

import (
	"bytes"
	"errors"
	"slices"
	"testing"
	"time"

	"agentland/host/keeper"
)

// The host's record of a terminal in the keeper (terminal_backend.go): V1
// names a workspace; V2 names the terminal's folder and, optionally, a
// workspace, for terminals outside any workspace and routed agents.

func TestMetaWithAWorkspaceStaysV1(t *testing.T) {
	meta := terminalMeta{Owner: "device-1", Project: "p1", Program: "shell", Title: "Shell", Created: time.Now().UTC()}
	record := encodedMeta(meta)
	if !bytes.Contains(record, []byte(`"v":1`)) || bytes.Contains(record, []byte(`"folder"`)) || bytes.Contains(record, []byte(`"routed"`)) {
		t.Fatalf("record %s", record)
	}
	decoded, err := decodeTerminalMeta(record)
	if err != nil || decoded.V != 1 || decoded.Project != "p1" || decoded.Owner != "device-1" {
		t.Fatalf("decoded %+v %v", decoded, err)
	}
}

func TestProjectlessAndRoutedMetaAreV2(t *testing.T) {
	for _, meta := range []terminalMeta{
		{Owner: localMacDeviceID, Folder: "/Users/someone/code"},
		{Owner: localMacDeviceID, Project: "p1", Folder: "/Users/someone/code", Routed: true},
	} {
		record := encodedMeta(meta)
		if !bytes.Contains(record, []byte(`"v":2`)) || !bytes.Contains(record, []byte(`"folder":"/Users/someone/code"`)) {
			t.Fatalf("%+v: record %s", meta, record)
		}
		if meta.Routed != bytes.Contains(record, []byte(`"routed":true`)) {
			t.Fatalf("%+v: record %s", meta, record)
		}
	}
}

func TestV2DecodesWithoutAWorkspace(t *testing.T) {
	meta, err := decodeTerminalMeta([]byte(`{"v":2,"owner":"local-mac","project":"","folder":"/Users/someone/code","program":"claude","routed":true}`))
	if err != nil || meta.V != 2 || meta.Project != "" || meta.Folder != "/Users/someone/code" || !meta.Routed || meta.Owner != localMacDeviceID {
		t.Fatalf("decoded %+v %v", meta, err)
	}
	// It encodes as it came: still V2.
	if again := encodedMeta(meta); !bytes.Contains(again, []byte(`"v":2`)) {
		t.Fatalf("encoded again %s", again)
	}
}

func TestV2NeedsAFolder(t *testing.T) {
	for _, record := range []string{
		`{"v":2,"owner":"local-mac","program":"claude","routed":true}`,
		`{"v":2,"owner":"local-mac","project":"p1"}`,
		`{"v":2,"folder":"/Users/someone/code"}`,
	} {
		if meta, err := decodeTerminalMeta([]byte(record)); err == nil {
			t.Errorf("%s decoded as %+v", record, meta)
		}
	}
	// V1 still needs a workspace.
	if meta, err := decodeTerminalMeta([]byte(`{"v":1,"owner":"device-1","folder":"/Users/someone/code"}`)); err == nil {
		t.Errorf("a V1 record without a workspace decoded as %+v", meta)
	}
	// Nor is one written.
	for _, meta := range []terminalMeta{{Owner: localMacDeviceID, Program: "claude"}, {Owner: localMacDeviceID, Project: "p1", Routed: true}} {
		if record, err := meta.encode(); err == nil {
			t.Errorf("%+v encoded as %s", meta, record)
		}
	}
}

// A terminal the keeper adopted is a Terminal.app window's program: when its
// record does not decode, restore releases it there instead of ending it. A
// terminal the keeper started is still ended.
func TestAnAdoptedTerminalWithABadMetaIsReleased(t *testing.T) {
	store, fixture, token, _ := restoreFixture(t)
	fixture.addRunning(keeper.Info{ID: "term_adopted", PID: 4242, Started: time.Now(), Adopted: true, Meta: []byte(`{"v":2,"owner":"local-mac","routed":true}`)}, "")
	fixture.addRunning(keeper.Info{ID: "term_started", PID: 4243, Started: time.Now(), Meta: []byte("not a record")}, "")
	host := restoreHost(t, store, fixture, fixture, nil)

	if releases, ends := fixture.releasedIDs(), fixture.endedIDs(); !slices.Equal(releases, []string{"term_adopted"}) || !slices.Equal(ends, []string{"term_started"}) {
		t.Fatalf("released %v ended %v", releases, ends)
	}
	if forgets := fixture.forgottenIDs(); !slices.Equal(forgets, []string{"term_adopted", "term_started"}) {
		t.Fatalf("forgot %v", forgets)
	}
	if listed := listedTerminals(t, host, token); len(listed) != 0 {
		t.Fatalf("listed %+v", listed)
	}
}

// A record a newer build wrote is left running and listed to no one, even
// when this build could not read the rest of it (here, no workspace and no
// folder). TestARecordFromANewerBuildIsLeftAlone covers the same for a
// record with a log.
func TestANewerMetaIsLeftAlone(t *testing.T) {
	store, fixture, token, _ := restoreFixture(t)
	fixture.addRunning(keeper.Info{ID: "term_v3", PID: 4242, Started: time.Now(), Meta: []byte(`{"v":3,"owner":"local-mac","where":{"folder":"/x"}}`)}, "newer output")
	host := restoreHost(t, store, fixture, fixture, nil)

	if ends, forgets := fixture.endedIDs(), fixture.forgottenIDs(); len(ends) != 0 || len(forgets) != 0 {
		t.Fatalf("ended %v forgot %v", ends, forgets)
	}
	if listed := listedTerminals(t, host, token); len(listed) != 0 {
		t.Fatalf("listed %+v", listed)
	}
	if entry := macEntry(host, "term_v3"); entry != nil {
		t.Fatalf("the host took a newer build's terminal: %+v", entry.info)
	}
	infos, err := fixture.List(t.Context())
	if err != nil || len(infos) != 1 || !infos[0].Running {
		t.Fatalf("keeper holds %+v %v", infos, err)
	}
	var newer *newerTerminalMetaError
	if _, err := decodeTerminalMeta(infos[0].Meta); !errors.As(err, &newer) || newer.version != 3 {
		t.Fatalf("decode: %v", err)
	}
}
