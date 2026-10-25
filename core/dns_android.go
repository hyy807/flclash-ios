//go:build android

package core

import "github.com/metacubex/mihomo/dns"

// applySystemDns rewrites the device resolver through VpnService's private DNS
// and drops the cached answers so the next lookup goes through the tunnel.
func applySystemDns(addr []string) {
	dns.UpdateSystemDNS(addr)
	dns.FlushCacheWithDefaultResolver()
}
