//go:build ios && cgo && lowmem

package main

// The extension build. iOS 15+ caps a packet-tunnel extension at 50MB of
// phys_footprint (EXC_RESOURCE ActiveHard 50 MB); this leaves 2MB of slack for
// the Swift side, the NetworkExtension framework and any allocations Go cannot
// see, and holds the Go heap well under it.
func init() {
	lowmemBuild = true
	defaultCeiling = 48 << 20
	defaultGCPercent = 30
}
