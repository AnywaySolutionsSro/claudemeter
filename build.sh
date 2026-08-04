#!/usr/bin/env bash
#
# Build, install, or notarize ClaudeMeter.app.
#
#   ./build.sh              Build dist/ClaudeMeter.app (ad-hoc signed, for local use)
#   ./build.sh --install    Build, install to /Applications (or ~/Applications), and launch
#   ./build.sh --notarize   Build, Developer ID sign, notarize, staple, and zip for sharing
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
MODE="${1:-}"

build_binary() {
	echo "==> Building release binary"
	swift build -c release
	BIN_DIR="$(swift build -c release --show-bin-path)"
}

assemble_bundle() {
	echo "==> Assembling ${APP_NAME}.app"
	rm -rf "${APP}"
	mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
	cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
	cp "${ROOT}/Info.plist" "${APP}/Contents/Info.plist"
	if [ -f "${ROOT}/Resources/AppIcon.icns" ]; then
		cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
	fi
}

# Ad-hoc signature: stable enough for one machine, but every rebuild changes the identity,
# so macOS re-prompts for Keychain access after each update.
sign_adhoc() {
	echo "==> Ad-hoc code signing"
	codesign --force --deep --sign - "${APP}"
	codesign --verify --deep --strict "${APP}" && echo "    signature OK"
}

# Developer ID signature with hardened runtime + secure timestamp, required for notarization.
# A stable certificate means the friend's "Always Allow" Keychain choice persists across updates.
sign_developer_id() {
	if [ -z "${CODESIGN_ID:-}" ]; then
		echo "ERROR: CODESIGN_ID is not set (see header of this script)." >&2
		exit 1
	fi
	echo "==> Developer ID code signing (${CODESIGN_ID})"
	# --entitlements is required here: the hardened runtime silently denies Apple Events
	# (auto-resume -> iTerm2) without com.apple.security.automation.apple-events.
	codesign --force --deep --options runtime --timestamp \
		--entitlements "${ROOT}/ClaudeMeter.entitlements" \
		--sign "${CODESIGN_ID}" "${APP}"
	codesign --verify --deep --strict --verbose=2 "${APP}"
}

install_and_launch() {
	if [ -w /Applications ]; then
		DEST="/Applications"
	else
		DEST="${HOME}/Applications"
		mkdir -p "${DEST}"
	fi
	TARGET="${DEST}/${APP_NAME}.app"

	echo "==> Installing to ${TARGET}"
	pkill -f "${TARGET}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
	rm -rf "${TARGET}"
	cp -R "${APP}" "${TARGET}"
	codesign --force --deep --sign - "${TARGET}"

	echo "==> Installed. Launching — click the 'Sign in' pill in the menu bar to connect."
	open "${TARGET}"
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
	echo "    They unzip it, drag ClaudeMeter.app to /Applications, and open it normally."
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
		echo "    Friend: right-click ClaudeMeter.app > Open the first time to bypass Gatekeeper."
	fi

	rm -f "${desktop_zip}"
	/usr/bin/ditto -c -k --keepParent "${APP}" "${desktop_zip}"
	echo "==> Release on your Desktop: ${desktop_zip}"
}

build_binary
assemble_bundle

case "${MODE}" in
	--release)
		sign_developer_id
		package_release
		;;
	--notarize)
		sign_developer_id
		notarize_and_package
		;;
	--install)
		sign_adhoc
		install_and_launch
		;;
	*)
		sign_adhoc
		echo "==> Built ${APP}"
		;;
esac
