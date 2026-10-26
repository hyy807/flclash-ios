# Universal signing (why this IPA can be re-signed anywhere)

The build in `.github/workflows/build-ios.yaml` produces an **unsigned** IPA:

* `CODE_SIGNING_ALLOWED=NO`, no certificate, no team, no profile;
* `_CodeSignature/`, `*.xcent` and `embedded.mobileprovision` are stripped from
  both the app and the extension before zipping;
* both `Info.plist`s derive the bundle identifiers from build settings
  (`$(APP_BUNDLE_ID)` and `$(APP_BUNDLE_ID).NECore`), so the pair stays
  consistent if a tool renames them;
* the extension is looked up at runtime as `<main bundle id>.NECore`, not from a
  hard-coded string.

That is what makes one artifact usable on any device: the signer supplies the
identity, and nothing in the payload is bound to a specific one.

## The part that is easy to get wrong: the App Group

`group.<bundle id>` is a *build-time guess*. Signing tools can rename the bundle
and grant a different group, and a guess that no longer matches its container
fails in the worst possible way — the app writes its VPN options into a
UserDefaults suite the extension cannot read, `startTunnel` bails with
`missingVPNOptions`, and the UI shows a VPN that never connects.

`ios/Shared/AppGroupResolver.swift` removes the guess: it reads
`com.apple.security.application-groups` from the provisioning profile the signer
embedded (`.app` for the app, the containing `.app` for the appex) and only falls
back to `group.<bundle id>` when there is no profile. Consequences:

| Signer | What happens |
|---|---|
| Paid certificate, bundle renamed | profile carries the new group → resolved correctly |
| Paid certificate, bundle kept | same |
| TrollStore (no profile) | derived `group.<bundle id>` is correct because the bundle id is untouched |
| Free Apple ID | installs, `startTunnel` fails: `packet-tunnel-provider` cannot be signed |

## Requirements on the signer's side

1. The profile must include **Network Extension**
   (`com.apple.developer.networking.networkextension` with `packet-tunnel-provider`)
   for *both* identifiers: the app and `<app>.NECore`.
2. The profile must include an App Group and both identifiers must be entitled
   to it. `group.<your bundle id>` is the simplest choice; any group the
   profile lists works, because it is read back from the profile.
3. If the tool changes the bundle id, it must change it for the app and the
   extension together, keeping the `.NECore` suffix.

## Verify before installing

```bash
unzip -q FlClash-0.9.2-ios-arm64-unsigned.ipa -d payload
codesign -d --entitlements :- payload/Payload/FlClash.app
codesign -d --entitlements :- payload/Payload/FlClash.app/PlugIns/NECore.appex
# expect: com.apple.developer.networking.networkextension = (packet-tunnel-provider)
#         com.apple.security.application-groups = (group.…)
```

If the `networkextension` entitlement is missing, the tunnel cannot start no
matter what the logs say — re-sign with a profile that has it.

## What a real device taught us

A paid certificate whose profile carries
`com.apple.developer.networking.networkextension = packet-tunnel-provider` is
**not enough**. Measured on iOS 27 with a validation profile:

* the app's code signature does carry the entitlement
  (`signed: ne=(packet-tunnel-provider, …)`), and the App Group resolves from the
  profile;
* `NETunnelProviderManager.saveToPreferences` is then called for the extension
  and **never calls back** — no error, no status change, five seconds later
  nothing. Re-signing with a bundle id equal to the profile's App ID changes
  nothing.

Cause: a provisioning profile names exactly **one** App ID. The tunnel extension
is a second bundle with a second App ID, and it has to be signed with a profile
matching *that* App ID. When a tool signs every embedded bundle with the one
profile it has, the appex ends up carrying the app's `application-identifier`,
and NetworkExtension silently refuses the configuration.

So a Network Extension client needs **two** App IDs and two profiles:

```
com.example.flclash            com.apple.developer.networking.networkextension
                               com.apple.security.application-groups
com.example.flclash.NECore     com.apple.developer.networking.networkextension
                               com.apple.security.application-groups
```

A single shared certificate ("通用签名" with one App ID) can never satisfy this,
and a wildcard App ID cannot carry Network Extension at all. The tools that do
work are the ones that create the App IDs and profiles per bundle themselves —
Sideloadly / AltStore with a paid account, or an Xcode build with a team — or a
hand-run `codesign` that supplies the second profile to `PlugIns/NECore.appex`.
