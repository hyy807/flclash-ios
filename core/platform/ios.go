//go:build ios

package platform

import "net"

// iOS runs mihomo inside a NetworkExtension sandbox: there is no /proc and no
// way to map a socket back to a uid, so process rules stay unknown. Descriptor
// pressure is bounded by the extension's own budget instead of the Android probe.
func QuerySocketUidFromProcFs(source, target net.Addr) int { return -1 }

func ShouldBlockConnection() bool { return false }
