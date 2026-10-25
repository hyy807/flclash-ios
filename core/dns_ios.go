//go:build ios

package core

import "github.com/metacubex/mihomo/log"

// The extension cannot change the device's resolver: there is no VpnService
// equivalent and NEDNSSettings is set by the provider, not by the core. DNS is
// captured by the tun's DNS hijack instead, so this is a no-op that only
// records the requested change.
func applySystemDns(addr []string) {
	log.Infoln("[DNS] ios: system DNS update skipped (%v); tun hijack handles DNS", addr)
}
