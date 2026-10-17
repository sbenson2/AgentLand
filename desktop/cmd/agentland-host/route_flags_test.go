package main

import "testing"

func TestRouteFlagsNeedAnAdvertisedHostAndTheHTTPSListener(t *testing.T) {
	if routes, err := routeSettings("0.0.0.0:9841", "", "", false); err != nil || routes != nil {
		t.Fatalf("without --advertised-host no routes are listed: %+v %v", routes, err)
	}
	for _, bad := range []struct {
		listen, host, cli string
		dev               bool
	}{
		{"0.0.0.0:9841", "", "/usr/local/bin/tailscale", false},
		{"127.0.0.1:9841", "mac.local", "", true},
		{"0.0.0.0:9841", "https://mac.local", "", false},
		{"0.0.0.0:9841", "mac.local", "tailscale", false},
		{"0.0.0.0", "mac.local", "", false},
	} {
		if _, err := routeSettings(bad.listen, bad.host, bad.cli, bad.dev); err == nil {
			t.Fatalf("%+v was accepted", bad)
		}
	}
	routes, err := routeSettings("0.0.0.0:9841", "Robins-Mac-mini.local", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", false)
	if err != nil || routes == nil || routes.Port != 9841 || routes.ListenHost != "0.0.0.0" || routes.AdvertisedHost != "Robins-Mac-mini.local" {
		t.Fatalf("%+v %v", routes, err)
	}
}

func TestWebSearchProviderFlagTakesAServiceName(t *testing.T) {
	for _, good := range []string{"", "exa", "parallel", "brave-2"} {
		if !validSearchProvider(good) {
			t.Errorf("%q was refused", good)
		}
	}
	for _, bad := range []string{"Exa", "exa ai", "exa\n", "https://exa.ai", "e/x", "a123456789012345678901234567890123"} {
		if validSearchProvider(bad) {
			t.Errorf("%q was accepted", bad)
		}
	}
}
