package keeper

import (
	"bytes"
	"testing"
)

func FuzzReadFrame(f *testing.F) {
	var ok bytes.Buffer
	_ = writeFrame(&ok, kindData, encodeData(1, []byte("x")))
	f.Add(ok.Bytes())
	f.Add([]byte{0, 0, 0, 0})
	f.Add([]byte{0xff, 0xff, 0xff, 0xff, 'D'})
	f.Add([]byte{0, 0, 0, 5, 'D', 1})
	f.Fuzz(func(t *testing.T, in []byte) {
		_, p, err := readFrame(bytes.NewReader(in))
		if err == nil && len(p) >= MaxFrame {
			t.Fatalf("payload of %d bytes", len(p))
		}
	})
}

func FuzzDecodeRequest(f *testing.F) {
	f.Add([]byte(`{"seq":1,"op":"list"}`))
	f.Add([]byte(`{"op":"spawn","spawn":{"id":"a","rows":1,"cols":1}}`))
	f.Add([]byte(`{"op":"adopt","adopt":{"id":"a","pid":2,"rows":1,"cols":1,"meta":"e30="}}`))
	f.Add([]byte(`{"seq":2,"op":"release","id":"a"}`))
	f.Add([]byte(`{"seq":3,"op":"reportExit","id":"a","exit":{"code":7,"at":"2026-10-15T12:00:00Z"}}`))
	f.Add([]byte(`null`))
	f.Fuzz(func(t *testing.T, in []byte) {
		if len(in) > MaxFrame {
			in = in[:MaxFrame]
		}
		req, err := decodeRequest(in)
		if err != nil {
			return
		}
		if len(req.Meta) > MaxMeta {
			t.Fatalf("meta of %d bytes", len(req.Meta))
		}
		if req.Adopt != nil && len(req.Adopt.Meta) > MaxMeta {
			t.Fatalf("adopt meta of %d bytes", len(req.Adopt.Meta))
		}
	})
}
