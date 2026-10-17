package main

import (
	"reflect"
	"strings"
	"testing"

	host "agentland/host"
)

func TestPreviewSettingsDefaultToTheAPIHost(t *testing.T) {
	cases := []struct {
		listen, preview, address string
		port, apiPort            int
	}{
		{"127.0.0.1:9841", "", "127.0.0.1:9842", 9842, 9841},
		{"0.0.0.0:9841", "", "0.0.0.0:9842", 9842, 9841},
		{"[::1]:9841", "", "[::1]:9842", 9842, 9841},
		{"192.168.1.8:9841", ":9900", "192.168.1.8:9900", 9900, 9841},
		{"0.0.0.0:9841", "127.0.0.1:9900", "127.0.0.1:9900", 9900, 9841},
	}
	for _, c := range cases {
		listen, options, err := previewSettings(c.listen, c.preview, []int{5432})
		if err != nil {
			t.Fatalf("%s %s: %v", c.listen, c.preview, err)
		}
		want := host.PreviewOptions{Port: c.port, APIPort: c.apiPort, AllowPorts: []int{5432}}
		if listen.Address != c.address || !reflect.DeepEqual(*options, want) {
			t.Errorf("%s %s: %s %+v", c.listen, c.preview, listen.Address, *options)
		}
	}
	for _, preview := range []string{"9900", "host:", ":0", ":70000", ":http"} {
		if _, _, err := previewSettings("127.0.0.1:9841", preview, nil); err == nil {
			t.Errorf("accepted --preview-listen %q", preview)
		}
	}
}

// Preview flags are checked before any state is read, so these fail
// without a configured host.
func TestServeRefusesUnsafePreviewFlags(t *testing.T) {
	cases := []struct {
		want string
		args []string
	}{
		{"need --enable-preview", []string{"serve", "--preview-listen", ":9900"}},
		{"need --enable-preview", []string{"serve", "--preview-allow-port", "5432"}},
		{"HTTPS", []string{"serve", "--enable-preview", "--dev-http"}},
		{"other than the API", []string{"serve", "--enable-preview", "--cert", "c", "--key", "k", "--preview-listen", ":9841"}},
		{"certificate and key", []string{"serve", "--enable-preview"}},
		{"between 1 and 65535", []string{"serve", "--enable-preview", "--preview-allow-port", "0"}},
	}
	for _, c := range cases {
		err := run(c.args)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%v: %v, want an error about %q", c.args, err, c.want)
		}
	}
}
