#!/usr/bin/env bash
#
# Build, install, or notarize ClaudeMeter.app — always including the widget extension.
#
#   ./build.sh              Build dist/ClaudeMeter.app (app + widget, dev-team signed)
#   ./build.sh --install    Build, install to /Applications, consolidate widget registration, launch
#   ./build.sh --release    Build, Developer ID sign, notarize when possible, zip to ~/Desktop
#   ./build.sh --notarize   Build, Developer ID sign, notarize, staple, and zip to dist/
#   ./build.sh --spm        Widget-less SwiftPM fallback build (no Xcode/team needed; ad-hoc signed)
#
# Requires: xcodegen (brew install xcodegen), Xcode, and a Developer team (override with
# DEVELOPMENT_TEAM). The --spm fallback needs only the Swift toolchain.
#
# Notarizing requires an Apple Developer account and these environment variables:
#
#   CODESIGN_ID     "Developer ID Application: Your Name (TEAMID)"
#                   List candidates with:  security find-identity -v -p codesigning
#   NOTARY_PROFILE  Name of a stored notarytool credential profile (default: ClaudeMeterNotary)
#                   Create once with:
#                     xcrun notarytool store-credentials ClaudeMeterNotary \
#                       --apple-id you@example.com --team-id TEAMID \
#                       --password <app-specific-password>
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClaudeMeter"
DIST="${ROOT}/dist"
APP="${DIST}/${APP_NAME}.app"
APPEX="${APP}/Contents/PlugIns/ClaudeMeterWidget.appex"
TEAM="${DEVELOPMENT_TEAM:-72K9YQF24J}"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
MODE="${1:-}"

# Full app + widget via the XcodeGen project. The result lands in dist/ already
# dev-team signed (stable signature -> the Keychain "Always Allow" persists).
build_app() {
	echo "==> Generating Xcode project"
	xcodegen generate --spec "${ROOT}/project.yml"

	echo "==> Building Release (app + widget, team ${TEAM})"
	xcodebuild -project "${ROOT}/${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" \
		-configuration Release -destination 'platform=macOS' \
		-allowProvisioningUpdates DEVELOPMENT_TEAM="${TEAM}" build

	local built
	built="$(find ~/Library/Developer/Xcode/DerivedData/${APP_NAME}-*/Build/Products/Release \
		-maxdepth 1 -name "${APP_NAME}.app" 2>/dev/null | head -1)"
	if [ -z "${built}" ]; then echo "ERROR: built app not found" >&2; exit 1; fi

	echo "==> Staging ${APP_NAME}.app in dist/"
	rm -rf "${APP}"
	mkdir -p "${DIST}"
	cp -R "${built}" "${APP}"

	if [ ! -d "${APPEX}" ]; then
		echo "ERROR: widget appex missing from the built app" >&2
		exit 1
	fi
}

# Widget-less SwiftPM fallback for machines without Xcode/xcodegen/a team.
build_spm() {
	echo "==> Building widget-less SwiftPM binary (fallback)"
	swift build -c release
	local bin_dir
	bin_dir="$(swift build -c release --show-bin-path)"

	echo "==> Assembling ${APP_NAME}.app (no widget)"
	rm -rf "${APP}"
	mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
	cp "${bin_dir}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
	cp "${ROOT}/Info.plist" "${APP}/Contents/Info.plist"
	if [ -f "${ROOT}/Resources/AppIcon.icns" ]; then
		cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
	fi
	codesign --force --deep --sign - "${APP}"
	codesign --verify --deep --strict "${APP}" && echo "    signature OK"
}

# Developer ID signatures with hardened runtime + secure timestamp, required for
# notarization. Signed inside-out (appex first, then the app) and WITHOUT --deep,
# because each bundle needs its OWN entitlements: the hardened runtime silently
# denies Apple Events (auto-resume -> iTerm2) without
# com.apple.security.automation.apple-events on the app, and the widget carries
# only the app-group entitlement.
sign_developer_id() {
	if [ -z "${CODESIGN_ID:-}" ]; then
		echo "ERROR: CODESIGN_ID is not set (see header of this script)." >&2
		exit 1
	fi
	echo "==> Developer ID code signing (${CODESIGN_ID})"
	codesign --force --options runtime --timestamp \
		--entitlements "${ROOT}/ClaudeMeterWidget.entitlements" \
		--sign "${CODESIGN_ID}" "${APPEX}"
	codesign --force --options runtime --timestamp \
		--entitlements "${ROOT}/${APP_NAME}.entitlements" \
		--sign "${CODESIGN_ID}" "${APP}"
	codesign --verify --deep --strict --verbose=2 "${APP}"
}

# The widget appex is emitted two ways that both shadow the installed copy: as a
# standalone build product next to the app, and embedded inside every stale
# ClaudeMeter.app in DerivedData / .build. LaunchServices/chronod discover ALL of
# them for the one bundle ID and flip-flop; when they pick a stale path the
# timeline provider is never invoked and the widget wedges or vanishes from the
# gallery. Delete the standalone copies, unregister every stale bundle, re-assert
# /Applications, and kick chronod.
consolidate_widget_registration() {
	local target="$1"
	echo "==> Consolidating widget registration (${target} only)"

	find ~/Library/Developer/Xcode/DerivedData/${APP_NAME}-*/Build/Products \
		-maxdepth 2 -name 'ClaudeMeterWidget.appex' -not -path "*/${APP_NAME}.app/*" \
		-exec rm -rf {} + 2>/dev/null || true

	while IFS= read -r staleApp; do
		[ -n "${staleApp}" ] && "${LSREG}" -u "${staleApp}" 2>/dev/null || true
	done < <(find ~/Library/Developer/Xcode/DerivedData "${ROOT}/.build" \
		-maxdepth 6 -name "${APP_NAME}.app" 2>/dev/null)

	"${LSREG}" -f "${target}" 2>/dev/null || true
	pluginkit -a "${target}/Contents/PlugIns/ClaudeMeterWidget.appex" 2>/dev/null || true
	killall chronod 2>/dev/null || true
}

install_and_launch() {
	local target="/Applications/${APP_NAME}.app"

	echo "==> Installing to ${target}"
	pkill -x "${APP_NAME}" 2>/dev/null || true
	sleep 1
	rm -rf "${target}"
	cp -R "${APP}" "${target}"

	if [ -d "${target}/Contents/PlugIns/ClaudeMeterWidget.appex" ]; then
		consolidate_widget_registration "${target}"
	fi

	echo "==> Installed. Launching."
	open "${target}"
}

notarize_and_package() {
	local profile="${NOTARY_PROFILE:-ClaudeMeterNotary}"
	local zip="${DIST}/${APP_NAME}.zip"

	echo "==> Zipping for notarization"
	rm -f "${zip}"
	/usr/bin/ditto -c -k --keepParent "${APP}" "${zip}"

	echo "==> Submitting to Apple notary service (this can take a few minutes)"
	xcrun notarytool submit "${zip}" --keychain-profile "${profile}" --wait

	echo "==> Stapling ticket"
	xcrun stapler staple "${APP}"
	xcrun stapler validate "${APP}"

	echo "==> Repackaging stapled app"
	rm -f "${zip}"
	/usr/bin/ditto -c -k --keepParent "${APP}" "${zip}"

	echo "==> Done. Share this with friends: ${zip}"
	echo "    They unzip it, drag ${APP_NAME}.app to /Applications, and open it normally."
}

# Developer ID signed release zipped to the Desktop for sharing. Notarizes when a notary
# profile is available, otherwise ships signed-but-un-notarized (friend right-clicks > Open).
package_release() {
	local profile="${NOTARY_PROFILE:-ClaudeMeterNotary}"
	local desktop_zip="${HOME}/Desktop/${APP_NAME}.zip"

	if xcrun notarytool history --keychain-profile "${profile}" >/dev/null 2>&1; then
		echo "==> Notarizing with profile '${profile}'"
		local tmp_zip="${DIST}/${APP_NAME}-notarize.zip"
		rm -f "${tmp_zip}"
		/usr/bin/ditto -c -k --keepParent "${APP}" "${tmp_zip}"
		xcrun notarytool submit "${tmp_zip}" --keychain-profile "${profile}" --wait
		xcrun stapler staple "${APP}"
		xcrun stapler validate "${APP}"
		rm -f "${tmp_zip}"
		echo "==> Notarized + stapled (opens with a normal double-click)"
	else
		echo "==> No notary profile '${profile}' found — shipping Developer ID signed (un-notarized)."
		echo "    Friend: right-click ${APP_NAME}.app > Open the first time to bypass Gatekeeper."
	fi

	rm -f "${desktop_zip}"
	/usr/bin/ditto -c -k --keepParent "${APP}" "${desktop_zip}"
	echo "==> Release on your Desktop: ${desktop_zip}"
}

case "${MODE}" in
	--release)
		build_app
		sign_developer_id
		package_release
		;;
	--notarize)
		build_app
		sign_developer_id
		notarize_and_package
		;;
	--install)
		build_app
		install_and_launch
		;;
	--spm)
		build_spm
		echo "==> Built ${APP} (no widget — SwiftPM fallback)"
		;;
	*)
		build_app
		echo "==> Built ${APP} (app + widget)"
		;;
esac
