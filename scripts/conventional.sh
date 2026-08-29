#!/usr/bin/env bash
#
# Conventional Commits helpers shared by scripts/check-pr-title.sh (the PR gate)
# and scripts/release-plan.sh (the release bump). Source this file; it defines
# functions only. Single source of truth for the type -> release-bump table:
#
#   feat                  -> minor
#   fix, perf             -> patch
#   build chore ci docs refactor style test -> none (merge allowed, no release)
#   any "!" / "BREAKING CHANGE" marker      -> breaking (majors are manual only)
#
# A subject is "<type>(<scope>)?!?: <text>"; scope is optional, "!" marks a
# breaking change. Anything else is invalid.

CONVENTIONAL_RELEASING_TYPES="feat fix perf"
CONVENTIONAL_SILENT_TYPES="build chore ci docs refactor style test"

# Prints the type of a conventional subject, or nothing if it isn't one.
conventional_type() {
	local subject="$1"
	if [[ "$subject" =~ ^([a-z]+)(\([^\)]+\))?(!)?:\ .+ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	fi
}

# Returns 0 when the subject carries the "!" breaking marker.
conventional_is_breaking() {
	local subject="$1"
	[[ "$subject" =~ ^[a-z]+(\([^\)]+\))?!: ]]
}

# Returns 0 when the type is one this repo allows in a PR title.
conventional_type_allowed() {
	local type="$1" t
	for t in $CONVENTIONAL_RELEASING_TYPES $CONVENTIONAL_SILENT_TYPES; do
		[ "$t" = "$type" ] && return 0
	done
	return 1
}

# Prints the release bump a subject implies: breaking | minor | patch | none.
# Unknown or malformed subjects count as "none" (they cannot reach main through
# the PR gate; a direct admin push must not produce a surprise release).
conventional_bump() {
	local subject="$1" type
	if conventional_is_breaking "$subject"; then
		echo breaking
		return
	fi
	type="$(conventional_type "$subject")"
	case "$type" in
	feat) echo minor ;;
	fix | perf) echo patch ;;
	*) echo none ;;
	esac
}

# Ranks bumps so callers can keep the highest: none < patch < minor < breaking.
conventional_bump_rank() {
	case "$1" in
	breaking) echo 3 ;;
	minor) echo 2 ;;
	patch) echo 1 ;;
	*) echo 0 ;;
	esac
}
