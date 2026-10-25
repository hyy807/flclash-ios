# iOS research digest (evidence base for the port)

Collected while building this port, with sources. Each claim below is what the
code in this repository is based on; where the code differs, it says so.

## 1. There is no public utun descriptor on iOS

`NEPacketTunnelProvider` hands the extension an `NEPacketTunnelFlow`; the flow
has `readPackets`/`writePackets` and no descriptor property
([Apple: NEPacketTunnelFlow](https://developer.apple.com/documentation/networkextension/nepackettunnelflow)).

Two ways real clients get a descriptor anyway:

| Approach | Used by | Private API? |
|---|---|---|
| `packetFlow.value(forKeyPath: "socket.fileDescriptor")` (KVC into a private ivar), falling back to a descriptor scan | sing-box SFI, Karing/clashmi | KVC **is** private |
| Enumerate fds 0…1023, `getpeername` → `sockaddr_ctl` with `AF_SYSTEM`, `ioctl(CTLIOCGINFO)` matching `com.apple.net.utun_control` | sing-box (`LibboxGetTunnelFileDescriptor`), clashmi fallback | no |
| `socketpair(AF_UNIX, SOCK_DGRAM)` + 4-byte big-endian address-family header pumped by Swift | ProjectClash (Clash / Clash-Adapter / Clash-Client) | no |

This port takes the **scan** (no private API, no extra Swift data path). It runs
inside the `setTunnelNetworkSettings` completion handler — earlier the interface
does not exist and the scan finds nothing.

## 2. The 50MB ceiling is real and measured

Apple DTS: packet tunnel **50 MiB**, app proxy 15, DNS proxy 15 (iOS 16+, and
"do not hard-code these, they change")
([forum 73148](https://developer.apple.com/forums/thread/73148?answerId=732711022)).
Historically 14–15 MiB until iOS 16. Crossing it produces
`EXC_RESOURCE … ActiveHard 50 MB` and `reason: per-process-limit`.

What shipped clients do:

* sing-box: `DefaultAppleNetworkExtensionMemoryLimit = 50MB`, `GCPercent 50`,
  `debug.SetMemoryLimit` + `SetGCPercent` when running inside an extension
  (`service/oomkiller/policy.go`, `experimental/libbox/setup.go`).
* Clash: jetsam budget 50MB, **soft limit 37.5MB** fed to
  `debug.SetMemoryLimit` (`bind/clash/memory_ne_pacing.go`).
* sing-tun shrinks gVisor buffers for iOS: receive 256KB (default 4MB),
  transmit 512KB (default 2MB), 1024 flows (default 16384).

This port: `libclash_lowmem.a` (48MB ceiling → 28.8MB Go limit, GC 30) plus a
`phys_footprint` sampler that forces collection at 70%/85% of the ceiling. The
lowmem archive is more conservative than Clash's 37.5MB because the profile and
rule sets are not yet moved out of the extension.

## 3. Config knobs that must be forced on iOS

From Clash's `bind/clash/override.go` + `config_deviations.go`, and mihomo's own
defaults:

* `tun.enable` always true; `auto-route` false; `auto-detect-interface` false —
  routes belong to `NEPacketTunnelNetworkSettings`.
* `tun.stack`: `gvisor` or `mips` only. `system`/`mixed` cannot work under
  `includeAllNetworks` (sing-tun refuses: `ErrIncludeAllNetworks`).
* `gso`, `recvmsgx`, `sendmsgx` off; `disable-icmp-forwarding` on (no raw
  sockets).
* `geodata-loader: memconservative`, `geo-auto-update: false`, geodata and
  `.mrs` rule sets in the App Group, downloaded by the **app**, never by the
  extension (Clash refuses to start if they are missing).
* `find-process-mode: off` — iOS has no `/proc` and no uid→socket mapping.

This repository currently forces the tun-level ones (stack, addresses, MTU,
`AutoRoute:false`, `AutoDetectInterface:false` in `core/tun/tun.go`); the
profile-level ones (`geodata-loader`, `geo-auto-update`, `find-process-mode`)
are **not yet forced** — see "Next" below.

## 4. Lifecycle

`startTunnel` is stateless and runs again after network changes, memory
pressure and on-demand wakeups
([NEProviderStopReason](https://developer.apple.com/documentation/networkextension/neproviderstopreason)).
Snapshots live in the App Group; sing-box writes an `ExtensionStartOptions`
snapshot, clashmi writes only the config path, Clash adds a session generation
so a late `setTunnelNetworkSettings` from an old session cannot overwrite a new
one.

This port: shared state snapshot + options written by the app before start,
read on every `startTunnel`, `missingVPNOptions` fail-fast, on-demand cleared on
`userInitiated`.

## 5. Distribution is constrained by entitlement, not by code

* Network Extension entitlements require a **paid** Apple Developer team
  ([forum 825136](https://developer.apple.com/forums/thread/825136)); a Personal
  Team cannot sign a packet-tunnel target, and a free Apple ID's App ID has no
  Network Extensions capability (AltStore issue #1091).
* TrollStore preserves arbitrary entitlements via CoreTrust, but only on
  iOS 14.0b2–16.6.1, 16.7 RC and 17.0 (never 16.7.x / 17.0.1+).
* ESign/Sideloadly can only sign what the certificate's profile allows.

So an unsigned IPA is not "works anywhere": it is "works anywhere the signer has
a profile with `packet-tunnel-provider` and an App Group".
`docs/ios/SIGNING.md` covers the App Group resolution that makes a re-signed,
renamed bundle still find its container.

## 6. Next (known gaps in this port)

1. Force the profile-level iOS deviations before `setupConfig`: geodata loader,
   `geo-auto-update: false`, `find-process-mode: off`, geodata/rule-set paths in
   the App Group.
2. Bind outbound sockets to the physical interface (`IP_BOUND_IF`) or rely on
   `auto-detect-interface` being unavailable — under `includeAllNetworks` a
   socket that is not bound can re-enter the tunnel.
3. Lower the minimum iOS version (the archive currently only succeeds at 18.0
   because of the Widget target).
4. Consider an OOM evidence file (heap, goroutines, pressure level) so a jetsam
   kill is diagnosable from the app after the fact.
