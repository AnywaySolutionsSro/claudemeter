#!/usr/bin/env bash
#
# Decide the next release from the commits merged since the previous one.
#
#   scripts/release-plan.sh <previous-tag-or-empty> [major|minor|patch]
#
# Prints key=value lines (consumed by release.yml via $GITHUB_OUTPUT):
#
#   bump=none|patch|minor|major
#   previous=<tag or empty>
#   version=MM.mm.pp          (empty when bump=none)
#   tag=vMM.mm.pp             (empty when bump=none)
#
# Without an explicit bump, every commit subject in <previous>..HEAD is folded
# through scripts/conventional.sh and the HIGHEST bump wins, so a run that covers
# several merges (Actions collapses queued runs) still releases once with the
# right number. A breaking marker fails the plan: majors are manual only.
#
# Versions are vMM.mm.pp, two-digit zero-padded, starting at v01.00.00.
set -euo pipefail

# shellcheck source=scripts/conventional.sh
source "$(cd "$(dirname "$0")" && pwd)/conventional.sh"

previous="${1:-}"
manual_bump="${2:-}"

if [ -n "$previous" ] && ! [[ "$previous" =~ ^v[0-9]{2,}\.[0-9]{2,}\.[0-9]{2,}$ ]]; then
	echo "::error::Previous tag '$previous' is not vMM.mm.pp." >&2
	exit 1
fi

# --- 1. Which bump? ---------------------------------------------------------
bump=none
if [ -n "$manual_bump" ]; then
	case "$manual_bump" in
	major | minor | patch) bump="$manual_bump" ;;
	*)
		echo "::error::Manual bump must be major, minor or patch (got '$manual_bump')." >&2
		exit 1
		;;
	esac
else
	range="HEAD"
	[ -n "$previous" ] && range="${previous}..HEAD"
	best_rank=0
	while IFS= read -r subject; do
		[ -n "$subject" ] || continue
		candidate="$(conventional_bump "$subject")"
		rank="$(conventional_bump_rank "$candidate")"
		echo "  $candidate  <- $subject" >&2
		if [ "$rank" -gt "$best_rank" ]; then
			best_rank="$rank"
			bump="$candidate"
		fi
	done < <(git log --format=%s "$range" --)

	if [ "$bump" = "breaking" ]; then
		echo "::error::A breaking-change commit reached main. Majors are manual: Actions -> release -> Run workflow -> bump: major." >&2
		exit 1
	fi
fi

# --- 2. Next version ---------------------------------------------------------
version=""
tag=""
if [ "$bump" != "none" ]; then
	if [ -z "$previous" ]; then
		major=1 minor=0 patch=0
	else
		IFS=. read -r major minor patch <<<"${previous#v}"
		# 10# strips the zero padding so "08" is not read as octal.
		major=$((10#$major)) minor=$((10#$minor)) patch=$((10#$patch))
		case "$bump" in
		major) major=$((major + 1)) minor=0 patch=0 ;;
		minor) minor=$((minor + 1)) patch=0 ;;
		patch) patch=$((patch + 1)) ;;
		esac
	fi
	version="$(printf '%02d.%02d.%02d' "$major" "$minor" "$patch")"
	tag="v${version}"
fi

echo "bump=$bump"
echo "previous=$previous"
echo "version=$version"
echo "tag=$tag"
