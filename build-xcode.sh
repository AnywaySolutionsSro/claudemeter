#!/usr/bin/env bash
#
# Kept for muscle memory: ./build.sh now always builds the widget-embedded app,
# so this simply forwards to it.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/build.sh" --install
