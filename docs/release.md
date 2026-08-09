# Release & notarization

## TL;DR

```bash
export CODESIGN_ID="Developer ID Application: Jakub Zak (72K9YQF24J)"
export NOTARY_PROFILE="mbx-notary"
./build.sh --release
# → notarized, stapled ~/Desktop/ClaudeMeter.zip
```

## How `build.sh` modes differ

All modes except `--spm` build the **full app + widget extension** via the XcodeGen project.

| Command              | Signing                         | Distributable?                          |
| -------------------- | ------------------------------- | --------------------------------------- |
| `./build.sh`         | dev team                        | local only                              |
| `./build.sh --install` | dev team, installs to /Applications | local only; stable signature (Keychain prompts once) |
| `./build.sh --release` | Developer ID + hardened runtime | yes — notarized if a notary profile exists |
| `./build.sh --spm`   | ad-hoc (`-`), **no widget**     | local fallback for Xcode-less toolchains |

Release signing is **inside-out and per-bundle** (appex with `ClaudeMeterWidget.entitlements`,
then the app with `ClaudeMeter.entitlements`) — never `--deep`, which would stamp the app's
entitlements onto the appex.

`--release` notarizes when `xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"`
succeeds; otherwise it ships a Developer ID signed but **un-notarized** build (friend must
right-click → Open the first time).

## Notary profiles are account-scoped, not per-project

A notarytool profile stores Apple credentials that authenticate your **Developer team**
(`72K9YQF24J`). Any app signed with that team's Developer ID notarizes through the same profile.
Reusing `mbx-notary` across projects is correct and conventional.

Create a separate profile only for: a **different Apple team**, or **independent revocation**
(e.g. CI should get its own credential — prefer a scoped App Store Connect **API key** there).

### Creating a profile (one-time, interactive)

```bash
# app-specific password from appleid.apple.com → Sign-In and Security → App-Specific Passwords
xcrun notarytool store-credentials <profile-name> \
  --apple-id <apple-id-email> --team-id 72K9YQF24J --password <app-specific-password>
```

## Verify a build

```bash
codesign --verify --deep --strict --verbose=2 dist/ClaudeMeter.app
spctl -a -vvv -t install dist/ClaudeMeter.app      # want: accepted / source=Notarized Developer ID
xcrun stapler validate dist/ClaudeMeter.app
```

## Signing identities on this machine

```bash
security find-identity -v -p codesigning
# 2) Developer ID Application: Jakub Zak (72K9YQF24J)   ← use this for release
```
