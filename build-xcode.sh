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

# The widget appex is emitted two ways that both shadow the installed copy:
#   1. as a *standalone* build product (ClaudeMeterWidget.appex next to the app), and
#   2. *embedded* inside every ClaudeMeter.app that xcodebuild leaves in DerivedData
#      (Debug + Release) and .build/xcodedd.
# LaunchServices/chronod discover ALL of these copies for the one widget bundle ID
# and flip-flop between them; when they pick a stale path the timeline provider is
# never invoked and the widget wedges on its placeholder / vanishes from the gallery.
# Fix: delete the standalone copies AND lsregister -u every stale app bundle, then
# re-assert /Applications as the single registration source, and kick chronod.
echo "==> Consolidating widget registration (/Applications only)"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PRODUCTS_DIR="$(dirname "${APP}")/.."

# 1. Remove standalone appex build products.
find "${PRODUCTS_DIR}" -maxdepth 2 -name 'ClaudeMeterWidget.appex' -not -path '*/ClaudeMeter.app/*' \
    -exec rm -rf {} + 2>/dev/null || true

# 2. Unregister every ClaudeMeter.app outside /Applications (their embedded appexes
#    otherwise remain registered and shadow the canonical copy).
while IFS= read -r staleApp; do
    [ -n "${staleApp}" ] && "${LSREG}" -u "${staleApp}" 2>/dev/null || true
done < <(find ~/Library/Developer/Xcode/DerivedData "${ROOT}/.build" \
    -maxdepth 6 -name 'ClaudeMeter.app' 2>/dev/null)

# 3. Re-assert the installed copy as the one true registration, then restart chronod.
"${LSREG}" -f /Applications/ClaudeMeter.app 2>/dev/null || true
pluginkit -a /Applications/ClaudeMeter.app/Contents/PlugIns/ClaudeMeterWidget.appex 2>/dev/null || true
killall chronod 2>/dev/null || true

echo "==> Launching"
open /Applications/ClaudeMeter.app
echo "Done. Add the widget from the desktop widget gallery (right-click desktop -> Edit Widgets -> Claude Sessions)."
