#!/usr/bin/env bash
#
# Build & install the FULL app (menu-bar app + WidgetKit extension) via the
# XcodeGen-generated project. Use this instead of ./build.sh when you want the
# widget. (./build.sh still builds the widget-less SwiftPM app.)
#
#   ./build-xcode.sh            Build Release, sign with the dev team, install to /Applications, launch
#
# Requires: xcodegen (brew install xcodegen), Xcode, and a Developer team.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TEAM="${DEVELOPMENT_TEAM:-72K9YQF24J}"

echo "==> Generating Xcode project"
xcodegen generate --spec "${ROOT}/project.yml"

echo "==> Building Release (team ${TEAM})"
xcodebuild -project "${ROOT}/ClaudeMeter.xcodeproj" -scheme ClaudeMeter \
    -configuration Release -destination 'platform=macOS' \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="${TEAM}" build

APP="$(find ~/Library/Developer/Xcode/DerivedData/ClaudeMeter-*/Build/Products/Release \
    -maxdepth 1 -name 'ClaudeMeter.app' 2>/dev/null | head -1)"
if [ -z "${APP}" ]; then echo "ERROR: built app not found" >&2; exit 1; fi

echo "==> Installing to /Applications"
pkill -x ClaudeMeter 2>/dev/null || true
sleep 1
rm -rf /Applications/ClaudeMeter.app
cp -R "${APP}" /Applications/ClaudeMeter.app

# The widget appex is also emitted as a standalone build product under
# DerivedData. LaunchServices/chronod discover those copies and flip-flop
# between them and the installed one, which leaves the widget wedged on its
# placeholder (timeline provider never invoked). Remove the standalone copies
# so /Applications is the single registration source, then kick chronod.
echo "==> Consolidating widget registration (/Applications only)"
PRODUCTS_DIR="$(dirname "${APP}")/.."
find "${PRODUCTS_DIR}" -maxdepth 2 -name 'ClaudeMeterWidget.appex' -not -path '*/ClaudeMeter.app/*' \
    -exec rm -rf {} + 2>/dev/null || true
pluginkit -a /Applications/ClaudeMeter.app/Contents/PlugIns/ClaudeMeterWidget.appex 2>/dev/null || true
killall chronod 2>/dev/null || true

echo "==> Launching"
open /Applications/ClaudeMeter.app
echo "Done. Add the widget from the desktop widget gallery (right-click desktop -> Edit Widgets -> Claude Sessions)."
