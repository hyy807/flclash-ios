# FlClash for iOS — port notes

FlClash 0.9.x ships a Go core (mihomo) reached over gomobile on Android and over
IPC on desktop. iOS allows neither: a proxy client must run its traffic engine
inside a **Network Extension** (`NEPacketTunnelProvider`), in a separate process
the system launches, supervises and kills.

This directory documents how the port is put together and why each piece is
where it is.

## 1. Process split

```
FlClash.app (Flutter)                     NECore.appex (Swift)
──────────────────────                    ────────────────────
UI, profiles, rule editing                PacketTunnelProvider
libclash.a  (app-side core)               libclash_lowmem.a (tunnel core)
      │                                        ▲
      │  NETunnelProviderSession.sendProviderMessage
      └─────────────── JSON method call ───────┘
                     JSON method reply
```

* **The extension owns the tunnel.** It is the only process that can hold the
  utun descriptor and it must be able to run with the app suspended.
* **The app owns the UI and the pre-flight work** — validating a profile,
  building it, testing delays — through the same core, linked as a normal
  static archive.
* Both speak one protocol: the JSON method call the Dart side already uses
  (`lib/core/method.dart`). No second RPC dialect was invented for iOS.

Channels (`ios/Runner/ServiceChannel.swift`):

| Channel | Direction | Purpose |
|---|---|---|
| `com.follow.clash/core` | Dart → native | `invokeMethod`, UTF-8 JSON string in, UTF-8 JSON bytes out |
| `com.follow.clash/service` | Dart → native | `init`, `start(revision)`, `stop(revision)`, `syncState(json)`, `shutdown`, `getRunTime` |
| `com.follow.clash/service` | native → Dart | `event` (core events, `Uint8List`), `stopped` (the revision that ended) |

## 2. The descriptor handoff

`NEPacketTunnelProvider` never hands out a socket. The system creates the utun
interface when `setTunnelNetworkSettings` succeeds, and the control socket
(`com.apple.net.utun_control`) is then reachable by descriptor scan:
`getpeername` + `AF_SYSTEM` + `ioctl(CTLIOCGINFO)`.

`ios/NECore/PacketTunnelNetworkConfiguration.swift` does this **inside the
completion handler of `setTunnelNetworkSettings`**, then
`NECoreBridge.startTun(fileDescriptor:options:)` passes it to
`core/cmd/ios/main.go`, which `dup`s it before handing it to sing-tun.

Two rules that decide whether the tunnel actually carries traffic:

1. Scan only after the settings call returns without error — earlier, the
   interface does not exist yet and the scan finds nothing (or something else).
2. Read the descriptor **or** `packetFlow`, never both. Two readers split the
   packet stream: ICMP passes, TCP stalls.

## 3. Memory: the 50MB wall

A packet-tunnel extension is jetsam-capped per process. Since iOS 15 that
ceiling is **50MB of phys_footprint**; crossing it kills the extension with
`EXC_RESOURCE … exceeded mem limit: ActiveHard 50 MB (fatal)` and
`reason: per-process-limit`, which the app cannot catch or even observe except
as "the VPN died".

What this port does about it:

* `libclash_lowmem.a` is built with the `lowmem` tag (`core/cmd/ios/lowmemory.go`):
  48MB ceiling, 30% GC target.
* `core/cmd/ios/main.go` exports `setMemoryLimit`, samples Mach
  `phys_footprint` every 2s (the figure jetsam compares, which includes
  allocations Go cannot see) and forces a collection at 70% / 85% of the
  ceiling.
* `debug.SetMemoryLimit(0.6 × ceiling)` is set as well, but it is only a GC
  hint: a core that ignores it still gets killed.
* The extension keeps no geodata and no rule sets of its own; profile and rule
  providers live in the App Group container and are compiled by the app.

## 4. Lifecycle and keepalive

`startTunnel` is stateless. iOS restarts the extension after network changes,
memory pressure and on-demand wakeups, so everything it needs is persisted in
the App Group container before the tunnel starts:

* `syncState` writes the full shared state (vpn options, setup params, tips)
  from the app; the extension reads it on **every** `startTunnel` and fails
  fast (`missingVPNOptions`) rather than starting a tunnel with no config.
* `startTunnel` completes only after the core accepted the descriptor.
  Reporting success and dying afterwards leaves iOS showing a connected VPN
  with no traffic.
* `stopTunnel` clears on-demand when the reason is `userInitiated`, otherwise
  the tunnel resurrects itself and the user cannot turn the VPN off.
* Widgets/controls are reloaded on start and stop, because Control Center reads
  its state from the App Group snapshot.

## 5. Signing — where "builds fine, VPN won't start" comes from

`com.apple.developer.networking.networkextension` (`packet-tunnel-provider`) and
`com.apple.security.application-groups` are **provisioning-profile
entitlements**, not Info.plist keys. A free Apple ID cannot sign them.

| Install path | Result |
|---|---|
| Paid developer certificate (ESign / Sideloadly / AltStore) | works, if the profile lists the App Group |
| TrollStore | works on supported iOS versions (entitlements are not enforced) |
| Free Apple ID / unsigned install | app launches, `startTunnel` fails immediately |

Both targets carry the entitlement file
(`ios/Runner/Runner.entitlements`, `ios/NECore/NECore.entitlements`) and both
derive the group at runtime as `group.<bundle id>`, so renaming the bundle in a
signing tool requires the matching group in the profile. Verify after signing:

```bash
codesign -d --entitlements :- Payload/FlClash.app
codesign -d --entitlements :- Payload/FlClash.app/PlugIns/NECore.appex
```

## 6. Build

Everything runs on a macOS runner (`.github/workflows/build-ios.yaml`); the core
is a c-archive built by the Xcode Run Script phase through
`tool/ios/build_core.sh`.

Locally, on a Mac:

```bash
rustup target add aarch64-apple-ios
flutter pub get
bash tool/ios/build_core.sh          # or let Xcode run it
flutter build ios --release --no-codesign
```

Artifacts: `libclash/ios/arm64/libclash.a`, `libclash_lowmem.a` and their
generated headers, both consumed by `Runner.xcodeproj`.

## 7. What is verified, and what is not

Verified by the CI job: the core compiles for `GOOS=ios`, both archives link,
Flutter builds the app, the archive contains `PlugIns/NECore.appex` whose
`NSExtensionPointIdentifier` is `com.apple.networkextension.packet-tunnel`, and
the payload is signature-free.

Not verified without a device: that the descriptor scan finds the utun socket on
a given iOS version, memory behaviour under real traffic, and keepalive across
network switches. Those need an install on hardware and a look at Console.app
for `PacketTunnelProvider` / jetsam messages.
