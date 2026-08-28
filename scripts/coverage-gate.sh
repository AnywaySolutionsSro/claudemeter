#!/usr/bin/env bash
#
# Run the unit tests with code coverage and fail when ClaudeMeterCore's line
# coverage drops below the threshold. Used by the `tests` CI job; run locally
# with `scripts/coverage-gate.sh`.
#
#   COVERAGE_THRESHOLD   minimum line coverage in percent (default 80)
#   SWIFT_TEST_FLAGS     extra flags for `swift test` (CI passes warnings-as-errors)
#
set -euo pipefail

THRESHOLD="${COVERAGE_THRESHOLD:-80}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC2086  # SWIFT_TEST_FLAGS is intentionally word-split
swift test --enable-code-coverage ${SWIFT_TEST_FLAGS:-}

bin="$(swift build --show-bin-path)"
xctest="$(find "${bin}" -maxdepth 1 -name '*.xctest' | head -1)"
if [ -z "${xctest}" ]; then
	echo "ERROR: no .xctest bundle under ${bin}" >&2
	exit 1
fi
binary="${xctest}/Contents/MacOS/$(basename "${xctest}" .xctest)"
profdata="${bin}/codecov/default.profdata"

# Only the core is unit-tested by design (the AppKit shell is not linked into
# the test bundle); exclude the tests themselves and the build directory.
report="$(xcrun llvm-cov report "${binary}" -instr-profile="${profdata}" \
	-ignore-filename-regex='Tests/|\.build/')"
echo "${report}"

# TOTAL row columns: name, regions, missed, %, functions, missed, %, lines, missed, %, ...
line_cov="$(echo "${report}" | awk '/^TOTAL/ { sub("%", "", $10); print $10 }')"
if [ -z "${line_cov}" ]; then
	echo "ERROR: could not read line coverage from the llvm-cov report" >&2
	exit 1
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "### ClaudeMeterCore coverage: ${line_cov}% lines (threshold ${THRESHOLD}%)"
		echo
		echo '```'
		echo "${report}"
		echo '```'
	} >> "${GITHUB_STEP_SUMMARY}"
fi

if awk -v c="${line_cov}" -v t="${THRESHOLD}" 'BEGIN { exit !(c + 0 < t + 0) }'; then
	echo "ERROR: ClaudeMeterCore line coverage ${line_cov}% is below the ${THRESHOLD}% threshold" >&2
	exit 1
fi
echo "==> Coverage gate passed: ${line_cov}% >= ${THRESHOLD}%"
