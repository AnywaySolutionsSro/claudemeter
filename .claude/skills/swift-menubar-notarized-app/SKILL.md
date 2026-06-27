---
name: swift-menubar-notarized-app
description: Use when building a macOS menu-bar (status item) app in Swift with SwiftPM and no Xcode project — covers bundling the .app, LSUIElement agent setup, login items, the NSStatusItem/popover gotchas, and Developer ID signing + notarization for sharing.
---

# Building a notarized macOS menu-bar app with SwiftPM

A menu-bar utility with no Xcode project. SwiftPM builds a bare executable; a shell script wraps
it into a signed `.app`. Split a pure, testable **core** library from the AppKit **app** target.

## Bundle assembly (no Xcode)

`swift build -c release` produces an executable, not an app. Assemble the bundle:

```
ClaudeMeter.app/Contents/
  MacOS/ClaudeMeter         # the built binary
  Info.plist                # LSUIElement=true, CFBundleIconFile, bundle id, NSPrincipalClass=NSApplication
  Resources/AppIcon.icns
```

- `Info.plist` must set `LSUIElement = true` (menu-bar agent: no Dock icon / window) and
  `CFBundleIconFile`. In `main.swift` also call `NSApp.setActivationPolicy(.accessory)`.
- Build with `MainActor.assumeIsolated { ... NSApplication.shared.run() }` in `main.swift` to
  construct a `@MainActor` app delegate from the nonisolated top-level entry.
- Generate `.icns`: draw PNGs at the iconset sizes (16…1024 + @2x) via Core Graphics, then
  `iconutil -c icns AppIcon.iconset -o AppIcon.icns`.

## Status item + popover gotchas (the important part)

- **`.transient` popovers don't auto-close for an agent app** — the window never becomes key. Add
  a global mouse-down monitor (`NSEvent.addGlobalMonitorForEvents`) and close on outside click.
- **No menu bar ⇒ no Cmd+V/C/X/A in text fields.** Install a minimal Edit menu with the standard
  selectors (`NSText.paste(_:)` etc., nil target → responder chain), set `NSApp.mainMenu`.
- **Redraw the status label on data changes**, not only on a timer — subscribe to your
  view-model's Combine `objectWillChange` (with `.receive(on: RunLoop.main)`), plus once after
  launch. Otherwise the bar is blank/stale until the next tick or a click.
- **Resolve colors for the menu bar appearance.** Render the label via
  `button.effectiveAppearance.performAsCurrentDrawingAppearance { ... }` so `labelColor` adapts to
  light/dark, and re-render on `AppleInterfaceThemeChangedNotification`.
- Build the bar content as an **NSImage** (`isTemplate = false` to keep brand colors); recreate
  the popover's SwiftUI content on open and release it on close so per-second tickers don't run
  while hidden (idle CPU ≈ 0).

## Start at login

Use `SMAppService.mainApp` (macOS 13+): `register()` / `unregister()`, status reflects System
Settings → Login Items. No legacy helper bundle needed.

## Keychain

The app's own items are read back without prompts **only with a stable code signature**. Ad-hoc
signatures change every build, so each rebuild re-prompts "Always Allow" — expected in dev,
gone once Developer ID signed. Store tokens in the Keychain (generic password), not UserDefaults.

## Signing & notarization

```bash
# local/dev:
codesign --force --deep --sign - ClaudeMeter.app          # ad-hoc

# distribution:
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: NAME (TEAMID)" ClaudeMeter.app
ditto -c -k --keepParent ClaudeMeter.app ClaudeMeter.zip
xcrun notarytool submit ClaudeMeter.zip --keychain-profile <profile> --wait
xcrun stapler staple ClaudeMeter.app
ditto -c -k --keepParent ClaudeMeter.app ClaudeMeter.zip   # re-zip stapled app
```

- A `notarytool` profile is **account/team-scoped**, not per-project — reuse one across apps;
  create a new one only for a different Apple team or independent revocation.
- Verify: `spctl -a -vvv -t install ClaudeMeter.app` → want `accepted / Notarized Developer ID`.
- Hardened runtime needs no special entitlements for Keychain + outbound network + login item.

## Structure that works

`Package.swift` with a pure `Core` target (models/parsing/crypto — unit-tested) and an
`executableTarget` app (AppKit/SwiftUI/networking/Keychain). Keep logic in core; the app stays a
thin shell. Many small files (<400 lines).
