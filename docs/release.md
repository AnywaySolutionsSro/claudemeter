# Release & notarization

## TL;DR

**Official releases are built by GitHub Actions** — push a version tag and a notarized
`ClaudeMeter.zip` lands on the [Releases page](https://github.com/AnywaySolutionsSro/claudemeter/releases):

```bash
git tag v01.02.03 && git push origin v01.02.03
```

Local one-off builds for sharing still work:

```bash
export CODESIGN_ID="Developer ID Application: Jakub Zak (72K9YQF24J)"
export NOTARY_PROFILE="mbx-notary"
./build.sh --release
# → notarized, stapled ~/Desktop/ClaudeMeter.zip
```

## Versioning policy

Tags and release names are `vMM.mm.pp` — two-digit, zero-padded — starting at `v01.00.00`.

| Bump          | When                                  |
| ------------- | ------------------------------------- |
| major (`MM`)  | a major new feature is introduced     |
| minor (`mm`)  | any new (smaller) feature             |
| patch (`pp`)  | any fix                               |

- `vMM.mm.pp-rcN` publishes a **pre-release** — use one to rehearse the pipeline.
- The workflow refuses a tag that doesn't match the pattern or isn't newer than the latest
  published release (`sort -V` order).
- `CFBundleShortVersionString` = `MM.mm.pp` from the tag; `CFBundleVersion` = the workflow run
  number. `project.yml`'s `MARKETING_VERSION` is only the fallback for local builds.
- Only repository admins can create/move/delete `v*` tags (the **release tags** ruleset).

## Releases via GitHub Actions

`.github/workflows/release.yml` runs on `macos-26` for every `v*` tag (or manually via
*Actions → release → Run workflow* with an existing tag to rebuild its assets). It runs the
same `./build.sh --notarize` as a local release; CI only provides a temporary keychain with
the Developer ID certificate and a notarytool profile named `ClaudeMeterNotary`, verifies the
result (`spctl` must say `Notarized Developer ID`, `stapler validate`, version == tag) and
publishes `ClaudeMeter.zip` + `ClaudeMeter.zip.sha256` with generated notes.

### Secrets (repository → Settings → Secrets and variables → Actions)

All five exist with the value `PLACEHOLDER`; the workflow fails fast naming any that still
hold it. Replace each with the real value:

| Secret                | Value                                                              |
| --------------------- | ------------------------------------------------------------------ |
| `MACOS_CERT_P12`      | base64 of a `.p12` export of the Developer ID certificate + key    |
| `MACOS_CERT_PASSWORD` | the password you chose when exporting the `.p12`                   |
| `ASC_KEY_ID`          | App Store Connect API key ID (10 chars, e.g. `A1B2C3D4E5`)         |
| `ASC_ISSUER_ID`       | App Store Connect issuer ID (UUID, shown above the keys table)     |
| `ASC_KEY_P8`          | full contents of the downloaded `AuthKey_<KEY_ID>.p8`              |

**Developer ID certificate (`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`)**

1. Keychain Access → *login* keychain → *My Certificates* → **Developer ID Application:
   Jakub Zak (72K9YQF24J)**. Expand it: the private key must be listed underneath (if not,
   the cert was created on another Mac — export it from there).
2. Right-click the certificate → *Export…* → format **Personal Information Exchange (.p12)** →
   save as `ClaudeMeter-DeveloperID.p12` → set an export password (this is
   `MACOS_CERT_PASSWORD`).
3. `base64 -i ClaudeMeter-DeveloperID.p12 | pbcopy` → paste as `MACOS_CERT_P12`.
4. Delete the `.p12` file once the secret is saved.

Or from the terminal in one go:

```bash
gh secret set MACOS_CERT_P12 --body "$(base64 -i ClaudeMeter-DeveloperID.p12)"
gh secret set MACOS_CERT_PASSWORD   # paste the export password, Enter
```

**App Store Connect API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`)**

1. <https://appstoreconnect.apple.com/access/integrations/api> (Users and Access →
   Integrations → **App Store Connect API** → *Team Keys*).
2. **Generate API Key** → name `claudemeter-ci-notary`, access **Developer** (enough for
   notarization; Admin also works).
3. Copy the **Issuer ID** (top of the page) → `ASC_ISSUER_ID`, the key's **KEY ID** →
   `ASC_KEY_ID`, and **Download API Key** (the `.p8` can be downloaded **only once**).
4. `gh secret set ASC_KEY_P8 < ~/Downloads/AuthKey_<KEY_ID>.p8`, then delete the file.

This key is separate from the local `mbx-notary` profile (an Apple-ID app-specific password),
so it can be revoked on its own without touching local releases.

### Cutting a release

```bash
git checkout main && git pull
git tag v01.00.00-rc1 && git push origin v01.00.00-rc1   # rehearsal → pre-release
# download ClaudeMeter.zip from the pre-release, unzip, then:
spctl -a -vvv -t install ClaudeMeter.app                  # want: source=Notarized Developer ID
git tag v01.00.00 && git push origin v01.00.00           # the real one
```

Watch it under *Actions → release*. A failed run leaves no release behind; fix and re-run via
*Run workflow* with the same tag.

## How `build.sh` modes differ

All modes except `--spm` build the **full app + widget extension** via the XcodeGen project.

| Command              | Signing                         | Distributable?                          |
| -------------------- | ------------------------------- | --------------------------------------- |
| `./build.sh`         | dev team                        | local only                              |
| `./build.sh --install` | dev team, installs to /Applications | local only; stable signature (Keychain prompts once) |
| `./build.sh --release` | Developer ID + hardened runtime | yes — notarized if a notary profile exists |
| `./build.sh --notarize` | Developer ID + hardened runtime | yes — **what CI runs**: notarization mandatory (fails otherwise), zip + `.sha256` in `dist/` |
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
