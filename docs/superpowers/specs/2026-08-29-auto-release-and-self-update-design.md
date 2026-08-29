# Automatic releases + in-app self-update — design

**Date:** 2026-08-29
**Status:** approved (chat), implemented in two PRs: (1) release pipeline, (2) updater

## Problem

Today a release is a hand-pushed `vMM.mm.pp` tag, and installing one means: download the
zip from GitHub, quit the app, replace the bundle, relaunch. Both halves should be automatic:
every merge to `main` that changes the shipped app publishes a release, and the running app
notices a new release once a day, offers it, and installs itself.

## Part 1 — release on merge

### Signal: the PR title (Conventional Commits)

`main` takes **squash merges only**, with the squash commit title set to the **PR title**.
The PR title therefore *is* the commit that lands and is the single source of truth:

| PR title type                                                   | Effect                     |
| --------------------------------------------------------------- | -------------------------- |
| `feat`                                                          | minor bump → release       |
| `fix`, `perf`                                                   | patch bump → release       |
| `build`, `chore`, `ci`, `docs`, `refactor`, `style`, `test`     | merge allowed, no release  |
| `feat!:` / `BREAKING CHANGE`                                    | **rejected** by the PR gate |

Major bumps are manual only (`workflow_dispatch` with `bump: major`).

Why the title and not the branch name: it is durable (in `git log`), enforceable as a
required status check, already the repo's convention, and it covers Dependabot / fork PRs
whose branch names we don't control (`build(deps): …` needs no special casing).

### Enforcement

- Repository settings: merge commits and rebase merges disabled; squash title = `PR_TITLE`,
  body = `PR_BODY`.
- `ci.yml` job **`pr-title`** (pull_request events only) runs `scripts/check-pr-title.sh`
  and is a required status check in the `main: tests` ruleset.
- The `release tags` ruleset keeps update/delete/force protection on `v*` but no longer
  restricts creation, so the workflow's `GITHUB_TOKEN` can create the tag. Only
  collaborators and Actions can push tags regardless.

### `release.yml`

Triggers: `push` to `main`; `workflow_dispatch` with `bump` (major/minor/patch, default
major) or `rebuild_tag` (rebuild the assets of an existing release).

Jobs:

1. **plan** (ubuntu, seconds): finds the latest published release tag, runs
   `scripts/release-plan.sh <previous> [bump]`, which folds every commit subject in
   `previous..HEAD` through the table above and takes the **highest** bump. This makes the
   pipeline robust to Actions collapsing queued runs (two quick merges → one release carrying
   both). No releasing type → the release job is skipped. A `!`/breaking marker that somehow
   landed fails the plan with an instruction to dispatch a major.
2. **release** (macos-26): unchanged build/notarize/staple/verify steps, then — only after a
   green build — `gh release create <tag> --target <sha> --generate-notes
   --notes-start-tag <previous>` uploading `ClaudeMeter.zip` + `ClaudeMeter.zip.sha256`.
   A failed build leaves no tag behind; re-run the workflow.

Version stays derived from the tag (no version-bump commit on `main`). Scheme unchanged:
`vMM.mm.pp`, two-digit, zero-padded. `-rcN` pre-releases are dropped (rehearse with
`rebuild_tag` instead).

## Part 2 — in-app updater

Built-in, GitHub-Releases-native. The trust anchor is the release pipeline's own Developer ID
signature + notarization, verified locally before anything is replaced. No Sparkle: it would
add a framework, an EdDSA key secret and appcast hosting for the same one-click result.

### Core (`ClaudeMeterCore`, pure, TDD)

- `AppVersion` — parses `01.02.03` / `v01.02.03`; numeric `Comparable`.
- `ReleaseDecoder` → `ReleaseInfo` — lenient parse of GitHub `releases/latest` JSON: version,
  notes, page URL, `ClaudeMeter.zip` + `.sha256` asset URLs, published date. Unknown shape
  → `nil`.
- `Sha256Manifest` — parses `<hex>  ClaudeMeter.zip`.
- `UpdatePolicy` — current version + latest release + last-check date + skipped version +
  auto-check flag → `checkDue` / `upToDate` / `available` / `skipped`.

### App (`ClaudeMeter`)

- `UpdateService` (@MainActor, `@Published state`): idle → checking → available →
  downloading(progress) → installing → failed. First check ~1 min after launch, then every
  24 h, plus on wake when overdue. One unauthenticated API call per check. Every decision is
  logged at `.notice`, category `updater`.
- `UpdateInstaller`, strictly ordered gates: download zip + sha256 → verify hash → unzip
  with `ditto -x -k` → verify bundle with Security.framework (valid signature, Team ID
  `72K9YQF24J`, bundle ID `com.jakubzak.claudemeter`, `CFBundleShortVersionString` equals the
  release) → move the new bundle next to the installed one → `FileManager.replaceItemAt`
  swap (the installed path is never empty, the old bundle is kept as a backup through the
  swap and trashed afterwards) → `lsregister -f` + kick `chronod` (as `build.sh --install`)
  → detached `open` + terminate. Diagnostics: `ClaudeMeter --update-check` (check + download
  + verify, nothing installed) and `--update-install` (the real swap, GUI quit first).

### UX

- Notification "ClaudeMeter X is available" with Install / Later.
- Dropdown row "Update to X — Install" with progress and a release-notes link.
- Settings: current version, "Check for updates automatically" (default on), "Check now",
  "Skip this version". "Later" re-offers at the next daily check.

### Fallbacks

Not running from `/Applications`, directory not writable, or app-translocated → the offer is
"Download" (opens the release page). Network/API failure → silent, retry next day.
Verification failure → notification with the reason, nothing replaced, temp files removed.

### Testing

Core: fixture JSON (real shape, malformed, missing assets), version ordering, policy cases.
App: installer gates modelled as a small state machine so a step cannot be skipped.
End-to-end: install the current release locally and let it update to the first release the
new pipeline produces.
