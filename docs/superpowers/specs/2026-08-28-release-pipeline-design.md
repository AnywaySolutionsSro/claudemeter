# Release pipeline — design (2026-08-28)

## Goal

Every release of ClaudeMeter is a Developer ID signed, notarized, stapled `ClaudeMeter.zip`
that anyone can download from the GitHub Releases page and open without Gatekeeper warnings,
built reproducibly by GitHub Actions instead of on Jakub's Mac.

## Versioning policy

Tags and release names use `vMM.mm.pp` (two-digit, zero-padded), starting at `v01.00.00`.

| Bump | When |
| --- | --- |
| major (`MM`) | a major new feature is introduced |
| minor (`mm`) | any new (smaller) feature |
| patch (`pp`) | any fix |

`vMM.mm.pp-rcN` publishes a **pre-release** (used to rehearse the pipeline). The workflow
rejects tags that don't match the pattern or aren't newer than the latest published release.
`CFBundleShortVersionString` = `MM.mm.pp` from the tag; `CFBundleVersion` = the workflow run
number (monotonic). `project.yml`'s values are only the fallback for local builds.

## Trigger

- `push` of a tag `v*` — creatable only by repository admins (the **release tags** ruleset;
  only Jakub is admin).
- `workflow_dispatch` with an existing tag to rebuild/replace its assets (skips the
  "must be newer" guard).

## Job (`.github/workflows/release.yml`, `macos-26`)

1. **Resolve version** from the tag; validate pattern; compare with the latest release.
2. **Check secrets** — fail fast with the doc link if any is empty or `PLACEHOLDER`.
3. Checkout the tag, select Xcode 26, `brew install xcodegen`.
4. **Temporary keychain**: import `MACOS_CERT_P12`, set the key partition list (no prompts),
   prepend to the search list, assert `CODESIGN_ID` resolves.
5. **notarytool profile** `ClaudeMeterNotary` from the App Store Connect API key, stored in
   that keychain.
6. `BUILD_UNSIGNED=1 MARKETING_VERSION=… CURRENT_PROJECT_VERSION=… NOTARY_KEYCHAIN=…
   ./build.sh --notarize` — the existing script: XcodeGen project, app + widget, inside-out
   Developer ID signing with hardened runtime, notarize, staple, zip, `.sha256`.
7. **Verify**: `codesign --verify`, `spctl -a -t install` must report
   `source=Notarized Developer ID`, `stapler validate`, plist version == tag version,
   checksum.
8. **Publish**: `gh release create <tag> ClaudeMeter.zip ClaudeMeter.zip.sha256
   --generate-notes --verify-tag [--prerelease]`, or `gh release upload --clobber` when the
   release already exists (rebuild).
9. `always()`: delete the keychain and key files.

## `build.sh` changes

- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` env overrides passed to `xcodebuild`.
- `BUILD_UNSIGNED=1` replaces `-allowProvisioningUpdates DEVELOPMENT_TEAM=…` with
  `CODE_SIGNING_ALLOWED=NO …`. CI has no Apple Development cert; the Developer ID signature
  from `sign_developer_id` is the only one (locally it already re-signs over the dev-team
  signature). Consequence: no embedded development provisioning profile in release builds.
- `NOTARY_KEYCHAIN` optional `--keychain` for `notarytool submit`.
- `Info.plist` uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` like the widget's;
  the `--spm` fallback stamps the values with PlistBuddy.
- `--notarize` also writes `ClaudeMeter.zip.sha256`.

## Secrets (repository → Actions)

Created with the value `PLACEHOLDER`; Jakub replaces them (how-to in `docs/release.md`).

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | base64 of a `.p12` export of *Developer ID Application: Jakub Zak (72K9YQF24J)* **with private key** |
| `MACOS_CERT_PASSWORD` | password chosen at export |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key (Team key, role Developer/Admin) |

`CODESIGN_ID` and the team ID are public and live in the workflow as plain values.

## Rehearsal

First run on `v01.00.00-rc1` (pre-release). Verify the downloaded zip on a Mac with
`spctl -a -vvv -t install` and a normal double-click launch before tagging `v01.00.00`.

## Out of scope

DMG packaging, Sparkle/auto-update, Homebrew cask, Mac App Store.
