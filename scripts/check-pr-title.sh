#!/usr/bin/env bash
#
# PR title gate (the `pr-title` job in ci.yml, a required status check on main).
#
#   scripts/check-pr-title.sh "<title>" [body-file]
#
# The PR title becomes the squash commit on main and drives the release bump
# (scripts/release-plan.sh), so it must be a Conventional Commits subject with
# a known type. Breaking markers are refused: major releases are manual only
# (Actions -> release -> Run workflow -> bump: major). See docs/release.md.
set -euo pipefail

# shellcheck source=scripts/conventional.sh
source "$(cd "$(dirname "$0")" && pwd)/conventional.sh"

title="${1:-}"
body_file="${2:-}"

fail() {
	echo "::error::$1"
	echo
	echo "PR titles must look like:  <type>(<optional scope>): <summary>"
	echo "  release types  : $CONVENTIONAL_RELEASING_TYPES   (feat -> minor, fix/perf -> patch)"
	echo "  no-release     : $CONVENTIONAL_SILENT_TYPES"
	echo "  examples       : feat(usage): show weekly limits · fix: keep pill in sync · ci: cache SwiftPM"
	echo "  breaking (\"!\" / BREAKING CHANGE) is not allowed — majors are released manually."
	exit 1
}

[ -n "$title" ] || fail "PR title is empty."

if conventional_is_breaking "$title"; then
	fail "PR title '$title' carries a breaking-change marker."
fi

type="$(conventional_type "$title")"
[ -n "$type" ] || fail "PR title '$title' is not a Conventional Commits subject."

conventional_type_allowed "$type" || fail "PR title type '$type' is not allowed."

# The Conventional Commits footer form only ("BREAKING CHANGE: ..." / "BREAKING-CHANGE: ..."
# at the start of a line), so a PR that merely talks about breaking changes passes.
if [ -f "$body_file" ] && grep -qE '^BREAKING[ -]CHANGE:' "$body_file"; then
	fail "PR body has a 'BREAKING CHANGE:' footer; majors are released manually."
fi

echo "PR title OK: type '$type' -> release bump '$(conventional_bump "$title")'"
