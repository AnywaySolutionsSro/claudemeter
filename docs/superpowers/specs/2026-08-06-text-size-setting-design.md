# ClaudeMeter — Text Size Setting

**Date:** 2026-08-06
**Status:** Approved design
**Branch:** `feat/text-size-setting`

## Goal

Make ClaudeMeter readable on a large, low-DPI external display. Every text size in
the app is currently a hardcoded absolute, which is precisely the category macOS
and SwiftUI will never scale on the user's behalf: **46 SwiftUI
`.font(.system(size:))` call sites** across five view files (`MenuContentView` 29,
`SessionsView` 8, `SessionRow` 5, `UsageRow` 3, `SettingsView` 1), plus **2 AppKit
`NSFont` sizes** in `MenuBarLabel` (`:68` at 11pt, `:188` at 6.5pt) that match
neither pattern and are counted separately throughout this document. 48 sites
total. Add a **Text size** preference that scales the dropdown popover,
the Live Sessions window, the Settings window, and (within a hard physical limit)
the menu-bar pill.

## Scope

In scope:

- **Dropdown popover** (`MenuContentView`, `UsageRow`, `Sparkline`): 32 of the 46
  SwiftUI font sizes, 29 of them in `MenuContentView` alone, several at 10pt.
- **Live Sessions window** (`SessionsView`, `SessionRow`).
- **Menu-bar pill** (`MenuBarLabel`): capped, see "Menu-bar ceiling".
- **Settings window** (`SettingsView`): so the picker previews its own effect.
- **Padding, spacing and small graphics**, not fonts alone. See "Why spacing
  scales too".

Explicitly **out of scope**:

- **The widget** (`Widget/`, 18 hardcoded font sizes). A sandboxed widget cannot read
  the non-sandboxed app's `UserDefaults` (see the App Group gotcha in
  `CLAUDE.md`), so the scale would have to ride inside `snapshot.json`. Separate
  change if wanted; `project.yml` scopes the widget target to `Widget/` only, so
  it shares no view code and nothing here blocks it later.
- **Converting anything to semantic fonts** (`.body`, `.caption`). Tempting while
  touching 46 sites, but it enlarges the diff and changes rendering the maintainer
  did not ask for.

## Empirical findings (measured 2026-08-06, macOS 26)

These rule out the two obvious off-the-shelf mechanisms, and correct two
assumptions made earlier in design.

1. **`.dynamicTypeSize()` does nothing on macOS.** Apple's own text-scaling
   environment is inert here, so relative fonts (`.system(size:relativeTo:)`)
   would buy nothing.
2. **`@ScaledMetric` is inert too.** Measured `ScaledMetric(wrappedValue: 100)`
   at `xSmall`, `large` and `accessibility5`: all returned `100.0`, even with the
   environment value propagating correctly. Consequence: **every** padding,
   spacing and graphic dimension must route through our own multiplier
   explicitly, or stay frozen. This is what makes spacing a scope decision rather
   than a detail.
3. **`View.monospacedDigit()` survives any font nesting.** Rendering
   `"1111111111"` at 60pt: proportional 269.0pt wide, and all four monospaced
   arrangements (font-value trait, font-inside-modifier plus outer
   `.monospacedDigit()`, and both orderings) measured 366.0pt. It is an
   environment transform applied after font resolution, so nesting depth is
   irrelevant. **The existing `.monospacedDigit()` chains stay untouched**
   (`UsageRow.swift:19,30`, `SessionRow.swift:39,43`) and the font helper needs no
   monospace parameter.
4. **Menu-bar headroom is 4pt.** `NSStatusBar.system.thickness` is 22.0; the pill
   is already 18.0 tall at 11pt with `verticalPadding = 2`.

   | font | text height | pill height | fits 22? |
   |------|-------------|-------------|----------|
   | 11 (current) | 14.0 | 18.0 | yes |
   | 13 | 16.0 | 20.0 | yes |
   | 15 | 19.0 | 23.0 | no |
   | 17 | 20.0 | 24.0 | no |

   At fixed padding the cap is 13pt, i.e. 1.18x, and only two of four steps would
   change anything. Clamping on pill *height* while letting padding compress from
   2 to 1 raises that materially: at 17pt, `20 + 2·1 = 22 ≤ 22` fits, so `largest`
   is reachable at compressed padding and the pill gains ~55%.

   **Two consequences for the design.** First, `textHeight` is *not* a clean
   function of font size (ratios across the table are 1.273, 1.231, 1.267, 1.176),
   because these are `NSFont` line heights, not arithmetic. It cannot be computed
   in `ClaudeMeterCore`, which has no AppKit. It must be **injected** (see
   `menuBarMetrics`). Second, the table has no 14pt row, which is exactly what
   `larger` needs (11 × 1.3 = 14.3 → 14), so no tabulated ceiling would be
   complete anyway.

   Whether 17pt at padding 1 is *visually* acceptable (the border nearly touches
   the glyphs, and the pill exactly equals the bar thickness with zero margin) is
   a judgment reserved for the build check in "Verification". If it reads as
   cramped, the ladder shortens. This document does not promise a specific
   ceiling; it specifies how the ceiling is derived.

## Mechanism

A custom scale enum plus a SwiftUI environment value. Given findings 1 and 2,
a custom knob is the only option; `.scaleEffect` is rejected because it
rasterises then transforms, blurring text and breaking popover sizing and hit
testing.

### `Sources/ClaudeMeterCore/Models/TextScale.swift` (new, pure, tested)

```swift
public enum TextScale: String, CaseIterable, Identifiable, Sendable {
    case standard, large, larger, largest

    public var id: String { rawValue }
    public var title: String        // "Default" / "Large" / "Larger" / "Largest"
    public var multiplier: Double   // 1.0 / 1.15 / 1.3 / 1.5

    /// Maps a nil or unrecognised persisted value to `.standard`.
    public static func fromStored(_ raw: String?) -> TextScale

    /// Base size multiplied and rounded to the nearest whole point,
    /// half away from zero (`Double.rounded()`). Whole points because
    /// fractional font sizes render soft.
    public func scaled(_ base: Double) -> Double

    /// The scaled font clamped to what the status bar can actually show, with the
    /// padding it needs.
    ///
    /// `textHeight` maps a font size to its rendered line height. It is injected
    /// because line height is an `NSFont` measurement and this target has no
    /// AppKit; `MenuBarLabel` passes the real measurement, tests pass a stub.
    ///
    /// Starting from `scaled(base)`, returns the first candidate that satisfies
    /// `textHeight(font) + 2 * padding <= thickness`, trying in order:
    /// `(font, padding)`, `(font, 1)`, `(font - 1, padding)`, `(font - 1, 1)`, …
    /// down to `font == base`.
    ///
    /// **Invariant precedence:** never return below `base`. If not even
    /// `(base, 1)` fits, return `(base, padding)` and accept the overflow, because that
    /// is today's unconditional behaviour, so the floor guarantees the pill is
    /// never *worse* than it is now. Fitting the thickness is subordinate to that.
    public func menuBarMetrics(base: Double, padding: Double, thickness: Double,
                               textHeight: (Double) -> Double) -> (font: Double, padding: Double)
}
```

Design constraints this obeys:

- **`Double`, never `CGFloat`.** `ClaudeMeterCore` has zero `CGFloat`
  occurrences; every analog is `Double` (`Formatting.percent`,
  `UsageGauge.percentLeft`, `Personality.moodEmoji`). `CGFloat` compiles via
  Foundation's re-export but breaks the target's "pure, dependency-free" style.
  Conversion happens at the app boundary.
- **`Identifiable` is required, not decorative.** `SettingsView.swift:28` uses
  `ForEach(DisplayMode.allCases)` with no `id:`, relying on `DisplayMode:
  Identifiable`. Without it the new `Picker` will not compile.
- **Injected measurement, not an AppKit dependency.** The `textHeight` closure
  keeps `menuBarMetrics` pure and unit-testable. This mirrors the repo's existing
  convention: `SessionsView.swift:28-29` injects `paths:`/`parents:` closures, and
  `ProcessProbe` is a protocol for the same reason.
- **`fromStored` handles nil and unrecognised values only.** Unlike
  `DisplayMode.fromStored`, which exists to map the legacy `"percentage"` key
  (`Settings.swift:26`), `TextScale` is new and has no legacy value to migrate.

Tests: `Tests/ClaudeMeterCoreTests/TextScaleTests.swift`, joining the 26 existing
test files. Coverage:

- multipliers, and `scaled()` rounding at a `.5` boundary in both directions
  (11 × 1.5 = 16.5 → 17, 10 × 1.15 = 11.5 → 12).
- `fromStored` returning `.standard` for nil, `""` and an unrecognised string.
- `menuBarMetrics` at all four scales against thickness 22.0 with a stubbed
  `textHeight` reproducing the measured table, asserting the exact
  `(font, padding)` pair each scale yields.
- padding compresses only when it actually buys a step, never gratuitously.
- **monotonicity**: a larger scale never yields a smaller font than a smaller
  scale. This is the assertion that would catch a step-down loop that overshoots.
- the **degenerate case** where the two invariants collide (thickness 10, so not
  even `(base, 1)` fits), asserting the documented precedence: `(base, padding)`
  is returned and the thickness is exceeded.

### `Sources/ClaudeMeter/Support/TextScaleEnvironment.swift` (new, ~25 lines)

The app-side bridge:

- `EnvironmentKey` + `\.textScale`, defaulting to `.standard`.
- `func font(_ size: Double, weight: Font.Weight = .regular) -> Font`: returns a
  **`Font` value**, not a `ViewModifier`. Both behave identically (finding 3, and
  `.font()` propagates through the environment, so `Button`, `Label`, `Toggle`,
  `Menu`, `TextField` and SF Symbol `Image` sites are all fine either way). The
  `Font` value wins on reviewability: each changed line stays visually parallel
  to the line it replaces, and it adds no wrapper layers to two hierarchies that
  re-render every second (`MenuContentView.swift:17`, `SessionsView.swift:14`).
- `func pt(_ value: Double) -> CGFloat` for paddings, spacings and frames. Same
  multiplier as `font()`, but **no rounding**: fractional layout metrics are fine,
  and rounding every padding would introduce drift that whole-point fonts need but
  layout does not.

Call-site shape: `.font(scale.font(12, weight: .semibold))`, `.padding(scale.pt(14))`.

## Persistence and UI

`Settings.swift` gains one property, structurally identical to `displayMode`:

```swift
@Published var textScale: TextScale {
    didSet { defaults.set(textScale.rawValue, forKey: Keys.textScale) }
}
```

initialised via `TextScale.fromStored(defaults.string(forKey: Keys.textScale))`,
key `"textScale"`, default `.standard`. No migration needed: the key has never
existed, and absent means default.

UI is one `Picker` in the existing General ▸ Appearance section of
`SettingsView`, directly under "Menu-bar style".

## Menu-bar ceiling

`MenuBarLabel` is AppKit, not SwiftUI: it draws an `NSImage` with Core Graphics
and its `static let font` (`MenuBarLabel.swift:68`) is a stored constant. Changes:

- `static let font` becomes `static func font(for: TextScale) -> NSFont`, derived
  from `menuBarMetrics(base: 11, padding: 2, thickness: NSStatusBar.system.thickness,
  textHeight:)`, where the closure measures a candidate via
  `NSFont.monospacedDigitSystemFont(ofSize:weight:)` and
  `NSString.size(withAttributes:).height`. The thickness is read at runtime rather
  than hardcoded to 22.
- `recommendedSlotWidth()` becomes `recommendedSlotWidth(for:)`.
- `pill`, `gaugePill` and `glyph` take the scale so they use the matching font and
  the possibly-compressed padding.
- `fuelGauge` stays as-is. It is a fixed 40x18 vector dial whose only text is the
  6.5pt "E"/"F" labels. It has the same 4pt of headroom the pill does, so this is a
  judgment call rather than a constraint: a slightly larger dial is not what the
  user asked for, and redrawing a hand-tuned gauge at arbitrary scales invites
  regressions for no readability gain.

Both consumers are in `AppDelegate.swift` (lines 48 and 219), so the signature
change is contained.

Expected outcome at the measured thickness of 22.0, per the `menuBarMetrics` trace:
`standard` → (11, 2), `large` → (13, 2), `largest` → (17, 1), i.e. up to ~55%. The
`larger` step depends on `textHeight(14)`, which is unmeasured, so it resolves at
runtime. The windows still scale further and without a ceiling, and the picker
makes no promise of a proportional pill.

## Why spacing scales too

Because `@ScaledMetric` is inert (finding 2), fonts-only scaling inside a
proportionally widened box reads as loose text floating in a stretched panel.
**The rule, not a list:** every numeric spacing, padding, corner-radius and frame
literal in the five view files (`MenuContentView`, `UsageRow`, `SessionsView`,
`SessionRow`, `SettingsView`) routes through `scale.pt(...)`, except the
exclusions below. A rule rather than an enumeration because an enumeration invites
partial application: an earlier draft of this spec listed only `MenuContentView`
and `SessionRow` sites, which would have shipped an entirely unscaled signed-out
login screen (`MenuContentView.swift:190,206,207,219`), the first thing a new user
sees. `SessionsView` alone has 12 such literals
(`:49,59,61,67,71,86,91,105,114,122,125`).

`Sparkline` needs no font changes (it is pure `GeometryReader`, zero fonts, and its
height comes from the caller at `MenuContentView.swift:95`), but its
`lineWidth: 1.5` (`Sparkline.swift:31`) does scale, or the trace reads hairline
beside 18pt text.

Exclusions, deliberate:

- `ProgressView(.linear)` (`UsageRow.swift:22-24`) has a fixed intrinsic height
  that cannot be raised without replacing it with a custom bar. It stays
  hairline-thin: an accepted cosmetic limitation, and the most visible one.
- `.controlSize(.mini)` toggles (`SessionRow.swift:50`, `SessionsView.swift:77`)
  keep AppKit's discrete control sizes; there is no continuous knob to scale.

## Wiring fixes

Five places where scaling silently fails to take effect. Each was verified
against the current code.

1. **The Sessions window would only change on relaunch.**
   `SessionsWindowController.swift:26-36` builds its `NSHostingController` once
   behind `if window == nil`, and `SessionsView` holds only `monitor` and `armed`.
   The popover has no such problem (`AppDelegate.swift:244` rebuilds it on every
   open; `:286` nils it on close), so the asymmetry is easy to miss in testing.
   Fix: pass `settings` into `SessionsWindowController`, hold it as
   `@ObservedObject` in `SessionsView`, and set `.environment(\.textScale, ...)`
   inside `body` so it re-derives when `Settings` publishes.
2. **`statusItem.length` is set once**, at `AppDelegate.swift:48`. The pill image
   already redraws on `settings.objectWillChange` (line 65, with
   `.receive(on: RunLoop.main)` ensuring the post-change value is read), so
   without this the new image lands in a stale slot. Move the
   `recommendedSlotWidth(for:)` assignment into `updateLabel()`. The fixed-width
   rationale in the comment at `:46-47` still holds: the width stays fixed *per
   scale*, so mode switches and countdown changes never resize the item.
3. **Fixed frames**: `MenuContentView.swift:32` (width 300),
   `SessionsView.swift:54` (min 380x420), `SessionsWindowController.swift:32`
   (content 440x640), `SettingsView.swift:19` (460x400). The popover's height
   already auto-sizes via `hosting.sizingOptions = [.preferredContentSize]`
   (`AppDelegate.swift:245`).
4. **`MenuContentView.swift:158`**: the `⋯` quick-links menu is pinned to
   `width: 28` and clips once the font grows. Becomes `scale.pt(28)`.
5. **`SettingsView.swift:148`** is a hardcoded `.font(.system(size: 12, weight:
   .semibold))`, not a semantic font, so the Settings pane needs it scaled
   explicitly along with its frame.

## Verification

Empirical results:

- **Does `NSStatusBarButton` scale an oversized image proportionally down?** This
  was unmeasured. If it does, a larger pill font renders at the same visual size
  and the setting appears broken on that surface specifically. Answered
  2026-08-06: it does not. Built at `largest` and confirmed on a 6144x2560
  1:1-scaled display that the pill genuinely grows; it is neither clipped nor
  scaled back down. Measured metrics, via real `NSFont` line heights against
  `NSStatusBar.system.thickness` of 22.0: `standard` 11pt/padding 2 (pill 18.0),
  `large` 13pt/padding 2 (20.0), `larger` 14pt/padding 2 (21.0), `largest`
  17pt/padding 1 (22.0, exactly the bar height). All four steps are visually
  distinct.
- `swift test` could not be run in the contributor's environment: both the
  `XCTest` and `Testing` modules are absent from a CommandLineTools-only
  toolchain, which reproduces at the merge-base commit and is unrelated to this
  branch. `TextScaleTests` is therefore committed but unexecuted. The logic it
  covers was instead verified by compiling `TextScale.swift` standalone under
  `swiftc -swift-version 6` against 26 assertions mirroring the test file, all
  passing, including all four `menuBarMetrics` pairs, monotonicity and the
  degenerate-thickness precedence. A maintainer with full Xcode should run
  `swift test` to confirm.
- All four surfaces were checked at `standard` and `largest`, confirming: no
  clipped `⋯`, the Sessions window reacting live to a scale change while open,
  the pill centred in its slot rather than clipped or floating, and no popover
  truncation.

## Documentation

`README.md` only. Its "Personality & extras" section (`README.md:39`) already
documents the display modes, and is already stale in claiming they "switch in the
dropdown" when they live in Settings (`SettingsView.swift:27`); the text-size
setting goes there and that stale phrase gets corrected in passing.

`CLAUDE.md` is deliberately left untouched. Nothing here is a hard-won gotcha of
the kind that file collects, and the contributor's global pre-push hook blocks
`CLAUDE.md`, so touching it would force a `--no-verify` push.

## Commit and PR

Conventional Commits per this repo's history (`fix(core):`, `fix(widget):`,
`feat(widget):`), e.g. `feat(settings): add text size setting for large displays`.
No JIRA IDs. Fork and PR from the fork, since the contributor has `pull`
permission only.
