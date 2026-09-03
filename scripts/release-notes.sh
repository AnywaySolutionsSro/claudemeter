#!/usr/bin/env bash
#
# Compose the GitHub release body for the commits since the previous release.
#
#   scripts/release-notes.sh <previous-tag-or-empty> <new-tag> [repo]
#
# Every squash commit on main carries its PR number ("... (#13)"). For each
# releasing commit (feat/fix/perf, see scripts/conventional.sh) the PR body's
# "## Release notes" section is fetched with `gh` and its bullets are grouped
# under emoji headings; a PR without bullets falls back to its emoji-prefixed
# title. Non-releasing PRs (ci, docs, ...) are not mentioned — the notes are for
# people using the app, not for the changelog. Prints markdown to stdout.
#
# Needs: git history covering the range, `gh` authenticated (GH_TOKEN in CI).
set -euo pipefail

# shellcheck source=scripts/conventional.sh
source "$(cd "$(dirname "$0")" && pwd)/conventional.sh"

previous="${1:-}"
tag="${2:?new tag required}"
repo="${3:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

range="HEAD"
[ -n "$previous" ] && range="${previous}..HEAD"

new_items=()
fix_items=()
perf_items=()

# Bullets of the "## Release notes" section of a PR body, one per line
# (everything from that heading up to the next heading; only "- " / "* " lines).
# `tr -d '\r'`: web-edited PR bodies arrive CRLF and a stray \r would ride into
# the release body and the in-app notes. `|| true`: a transient `gh` failure
# falls back to the title below instead of failing the release after the build.
release_notes_bullets() {
	local number="$1"
	{ gh pr view "$number" --repo "$repo" --json body -q .body || true; } |
		tr -d '\r' |
		awk '
			/^## / { in_section = ($0 ~ /^## [Rr]elease [Nn]otes/); next }
			in_section && /^[-*] / { sub(/^[-*] +/, ""); print }
		'
}

emoji_for() {
	case "$1" in
	feat) echo "✨" ;;
	fix) echo "🐛" ;;
	perf) echo "⚡" ;;
	esac
}

while IFS= read -r line; do
	[ -n "$line" ] || continue
	subject="${line#* }"
	bump="$(conventional_bump "$subject")"
	[ "$bump" != "none" ] || continue
	type="$(conventional_type "$subject")"

	number=""
	if [[ "$subject" =~ \(#([0-9]+)\)[[:space:]]*$ ]]; then number="${BASH_REMATCH[1]}"; fi
	suffix=""
	[ -n "$number" ] && suffix=" (#$number)"

	bullets=""
	[ -n "$number" ] && bullets="$(release_notes_bullets "$number")"
	if [ -z "$bullets" ]; then
		# Fallback: the title without its "type(scope): " prefix, emoji-prefixed.
		bullets="$(emoji_for "$type") ${subject#*: }"
		bullets="${bullets% (#"$number")}"
	fi

	while IFS= read -r bullet; do
		[ -n "$bullet" ] || continue
		item="- ${bullet}${suffix}"
		case "$type" in
		feat) new_items+=("$item") ;;
		fix) fix_items+=("$item") ;;
		perf) perf_items+=("$item") ;;
		esac
	done <<<"$bullets"
done < <(git log --format='%H %s' "$range" --)

section() {
	local title="$1"
	shift
	[ "$#" -gt 0 ] || return 0
	printf '## %s\n' "$title"
	printf '%s\n' "$@"
	printf '\n'
}

section "✨ New" ${new_items[@]+"${new_items[@]}"}
section "🐛 Fixes" ${fix_items[@]+"${fix_items[@]}"}
section "⚡ Faster" ${perf_items[@]+"${perf_items[@]}"}

if [ -n "$previous" ]; then
	printf '**Full Changelog**: https://github.com/%s/compare/%s...%s\n' "$repo" "$previous" "$tag"
fi
