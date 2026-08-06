# Text Size Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a four-step **Text size** preference that scales the dropdown popover, the Live Sessions window, the Settings window, and (within the menu bar's physical ceiling) the menu-bar pill.

**Architecture:** A pure `TextScale` enum in `ClaudeMeterCore` owns the multiplier arithmetic and the menu-bar clamp. A thin app-side bridge exposes it as a SwiftUI environment value plus two helpers, `scale.font(_:weight:) -> Font` and `scale.pt(_:) -> CGFloat`. Every hardcoded font size and layout literal in the five view files routes through those. `MenuBarLabel` (AppKit, not SwiftUI) derives its `NSFont` and padding from `TextScale.menuBarMetrics`, which takes an injected line-height measurement because `ClaudeMeterCore` has no AppKit.

**Tech Stack:** Swift 6.2 toolchain, SwiftPM, macOS 26 target, SwiftUI + AppKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-06-text-size-setting-design.md`

## Global Constraints

- **`ClaudeMeterCore` is Swift 6 language mode** (`Package.swift:17`) with strict concurrency. New core types must be `Sendable`-clean.
- **`ClaudeMeterCore` uses `Double`, never `CGFloat`.** The target has zero `CGFloat` occurrences. `CGFloat` conversion happens on the app side only.
- **The app target is Swift 5 language mode** (`Package.swift:33`). Do not "fix" this.
- **Tests are XCTest**, `final class XTests: XCTestCase`, `@testable import ClaudeMeterCore`.
- **No `print()`.** Use existing error types or `NSLog` sparingly.
- **Files stay under 400 lines.**
- **Commit style: Conventional Commits, no JIRA IDs.** This repo uses `feat(core):`, `fix(widget):`, `chore(core):`. The group.one conventions in `/Volumes/projects/CLAUDE.md` do **not** apply here.
- **Do not touch `CLAUDE.md`** (the contributor's global pre-push hook blocks it) or `Widget/` (explicit non-goal).
- **Do not convert anything to semantic fonts** (`.body`, `.caption`).
- **Branch:** `feat/text-size-setting`, already checked out.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `Sources/ClaudeMeterCore/Models/TextScale.swift` | The scale enum: multipliers, titles, `scaled()`, `fromStored()`, `menuBarMetrics()`. Pure. |
| `Tests/ClaudeMeterCoreTests/TextScaleTests.swift` | Unit tests for all of the above. |
| `Sources/ClaudeMeter/Support/TextScaleEnvironment.swift` | SwiftUI bridge: `\.textScale` environment key, `font(_:weight:)`, `pt(_:)`. |

**Modified:**

| File | Change |
|---|---|
| `Sources/ClaudeMeter/Support/Settings.swift` | `@Published var textScale` + `Keys.textScale`. |
| `Sources/ClaudeMeter/Views/SettingsView.swift` | The `Picker`, plus scaling its own font and frame and injecting the environment. |
| `Sources/ClaudeMeter/Views/UsageRow.swift` | 3 fonts + 1 spacing. |
| `Sources/ClaudeMeter/Views/Sparkline.swift` | Stroke width. |
| `Sources/ClaudeMeter/Views/MenuContentView.swift` | 29 fonts + all spacing/padding/frame literals. |
| `Sources/ClaudeMeter/Views/SessionsView.swift` | 8 fonts + 12 layout literals + `settings` injection. |
| `Sources/ClaudeMeter/Views/SessionRow.swift` | 5 fonts + layout literals. |
| `Sources/ClaudeMeter/App/SessionsWindowController.swift` | Accept `settings`, pass it through, scale initial content size. |
| `Sources/ClaudeMeter/Views/MenuBarLabel.swift` | `font` becomes scale-derived; `pill`/`gaugePill`/`glyph`/`image`/`recommendedSlotWidth` take the scale. |
| `Sources/ClaudeMeter/App/AppDelegate.swift` | Pass scale to `MenuBarLabel`; move `statusItem.length` into `updateLabel()`; pass `settings` to `SessionsWindowController`. |
| `README.md` | Document the setting; fix the stale "switch in the dropdown". |

**Task order rationale:** Core first (no dependencies). Then the bridge plus Settings, which makes the knob real and self-previewing. Then the smallest view (UsageRow/Sparkline) so the call-site pattern gets reviewed on a 4-line diff before being applied 29 times. Then MenuContentView. Then the Sessions window, which carries the subtle live-reaction wiring bug. Then the pill, which carries the one empirical unknown. Then docs and the cross-surface sweep.

---

### Task 1: `TextScale` in ClaudeMeterCore

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/TextScale.swift`
- Test: `Tests/ClaudeMeterCoreTests/TextScaleTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum TextScale: String, CaseIterable, Identifiable, Sendable` with cases `.standard, .large, .larger, .largest`; `var id: String`; `var title: String`; `var multiplier: Double`; `static func fromStored(_ raw: String?) -> TextScale`; `func scaled(_ base: Double) -> Double`; `func menuBarMetrics(base: Double, padding: Double, thickness: Double, textHeight: (Double) -> Double) -> (font: Double, padding: Double)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeMeterCoreTests/TextScaleTests.swift`:

```swift
import XCTest
@testable import ClaudeMeterCore

final class TextScaleTests: XCTestCase {
    /// `NSFont.monospacedDigitSystemFont` line heights measured on macOS 26.
    /// Measured: 11→14, 13→16, 15→19, 17→20. The 12/14/16 rows are plausible
    /// fill-ins so the step-down path is exercised; the real values are supplied
    /// by AppKit at runtime, which is exactly why `textHeight` is injected.
    private static let heights: [Double: Double] = [
        11: 14, 12: 15, 13: 16, 14: 17, 15: 19, 16: 19, 17: 20,
    ]

    private func stubHeight(_ font: Double) -> Double {
        Self.heights[font] ?? font + 3
    }

    /// The real menu bar: `NSStatusBar.system.thickness` is 22.0 and
    /// `MenuBarLabel.verticalPadding` is 2.
    private func metrics(_ scale: TextScale, thickness: Double = 22) -> (font: Double, padding: Double) {
        scale.menuBarMetrics(base: 11, padding: 2, thickness: thickness, textHeight: stubHeight)
    }

    func testMultipliersAndTitles() {
        XCTAssertEqual(TextScale.standard.multiplier, 1.0)
        XCTAssertEqual(TextScale.large.multiplier, 1.15)
        XCTAssertEqual(TextScale.larger.multiplier, 1.3)
        XCTAssertEqual(TextScale.largest.multiplier, 1.5)
        XCTAssertEqual(TextScale.allCases.map(\.title), ["Default", "Large", "Larger", "Largest"])
        XCTAssertEqual(TextScale.larger.id, "larger")
    }

    func testScaledRoundsToWholePointsHalfAwayFromZero() {
        XCTAssertEqual(TextScale.standard.scaled(11), 11)
        XCTAssertEqual(TextScale.largest.scaled(11), 17)   // 16.5 rounds up
        XCTAssertEqual(TextScale.large.scaled(10), 12)     // 11.5 rounds up
        XCTAssertEqual(TextScale.larger.scaled(10), 13)    // 13.0 exactly
        XCTAssertEqual(TextScale.larger.scaled(11), 14)    // 14.3 rounds down
    }

    func testFromStoredFallsBackToStandard() {
        XCTAssertEqual(TextScale.fromStored(nil), .standard)
        XCTAssertEqual(TextScale.fromStored(""), .standard)
        XCTAssertEqual(TextScale.fromStored("percentage"), .standard)
        XCTAssertEqual(TextScale.fromStored("larger"), .larger)
    }

    func testMenuBarMetricsAtEachScale() {
        XCTAssertEqual(metrics(.standard).font, 11)
        XCTAssertEqual(metrics(.standard).padding, 2)

        XCTAssertEqual(metrics(.large).font, 13)
        XCTAssertEqual(metrics(.large).padding, 2)

        XCTAssertEqual(metrics(.larger).font, 14)
        XCTAssertEqual(metrics(.larger).padding, 2)

        // 17pt needs the compressed padding: 20 + 2*2 = 24 overflows, 20 + 2*1 = 22 fits.
        XCTAssertEqual(metrics(.largest).font, 17)
        XCTAssertEqual(metrics(.largest).padding, 1)
    }

    func testPaddingCompressesOnlyWhenItBuysAStep() {
        // Every scale whose font already fits at the preferred padding keeps it.
        for scale in [TextScale.standard, .large, .larger] {
            XCTAssertEqual(metrics(scale).padding, 2, "\(scale) should not compress padding")
        }
    }

    func testMenuBarFontIsMonotonicInScale() {
        let fonts = TextScale.allCases.map { metrics($0).font }
        XCTAssertEqual(fonts, fonts.sorted(), "a larger scale must never yield a smaller font")
    }

    func testNeverReturnsBelowBaseEvenWhenNothingFits() {
        // Degenerate thickness: not even (11, 1) fits. The base floor wins over
        // fitting the bar, because base is today's unconditional behaviour.
        let result = metrics(.largest, thickness: 10)
        XCTAssertEqual(result.font, 11)
        XCTAssertEqual(result.padding, 2)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TextScaleTests`
Expected: FAIL to compile with `cannot find 'TextScale' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ClaudeMeterCore/Models/TextScale.swift`:

```swift
import Foundation

/// How large the app renders text and layout, relative to its design-time sizes.
///
/// Exists because every size in the app is a hardcoded absolute, and macOS scales
/// neither those nor `@ScaledMetric` (both measured inert on macOS 26), so a
/// custom multiplier is the only mechanism available.
public enum TextScale: String, CaseIterable, Identifiable, Sendable {
    case standard
    case large
    case larger
    case largest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return "Default"
        case .large: return "Large"
        case .larger: return "Larger"
        case .largest: return "Largest"
        }
    }

    /// Applied to every design-time font size and layout metric.
    public var multiplier: Double {
        switch self {
        case .standard: return 1.0
        case .large: return 1.15
        case .larger: return 1.3
        case .largest: return 1.5
        }
    }

    /// Maps a persisted value to a scale; nil or unrecognised falls back.
    public static func fromStored(_ raw: String?) -> TextScale {
        TextScale(rawValue: raw ?? "") ?? .standard
    }

    /// `base` scaled and rounded to a whole point; fractional font sizes render soft.
    public func scaled(_ base: Double) -> Double {
        (base * multiplier).rounded()
    }

    /// The scaled font clamped to what the menu bar can actually show, plus the
    /// vertical padding it needs.
    ///
    /// `textHeight` maps a font size to its rendered line height. It is injected
    /// because line height is an `NSFont` measurement and this target has no
    /// AppKit: `MenuBarLabel` passes the real measurement, tests pass a stub.
    /// It is not computable arithmetic: measured ratios are 1.273, 1.231, 1.267,
    /// 1.176.
    ///
    /// Starting from `scaled(base)`, returns the first candidate satisfying
    /// `textHeight(font) + 2 * padding <= thickness`, trying the preferred padding
    /// before the compressed one at each font size, then stepping the font down a
    /// point.
    ///
    /// Never returns below `base`: that is today's unconditional size, so the pill
    /// can never come out worse than it already is. When even the compressed base
    /// overflows, `(base, padding)` is returned and the overflow is accepted.
    public func menuBarMetrics(
        base: Double,
        padding: Double,
        thickness: Double,
        textHeight: (Double) -> Double
    ) -> (font: Double, padding: Double) {
        let paddings: [Double] = padding > 1 ? [padding, 1] : [padding]
        var font = max(base, scaled(base))
        while font >= base {
            for candidate in paddings where textHeight(font) + 2 * candidate <= thickness {
                return (font, candidate)
            }
            font -= 1
        }
        return (base, padding)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TextScaleTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Run the full suite to confirm nothing regressed**

Run: `swift test`
Expected: PASS, all tests across the now-27 test files.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/TextScale.swift Tests/ClaudeMeterCoreTests/TextScaleTests.swift
git commit -m "feat(core): add TextScale with menu-bar height clamp"
```

---

### Task 2: SwiftUI bridge, persistence, and the Settings picker

**Files:**
- Create: `Sources/ClaudeMeter/Support/TextScaleEnvironment.swift`
- Modify: `Sources/ClaudeMeter/Support/Settings.swift:1-2` (imports), `:34-48` (add property), `:58-70` (init), `:72-78` (Keys)
- Modify: `Sources/ClaudeMeter/Views/SettingsView.swift:10-20` (body), `:24-33` (picker), `:142-150` (sectionHeader)

**Interfaces:**
- Consumes: `TextScale` from Task 1.
- Produces: `EnvironmentValues.textScale: TextScale`; `TextScale.font(_ size: Double, weight: Font.Weight = .regular) -> Font`; `TextScale.pt(_ value: Double) -> CGFloat`; `Settings.textScale: TextScale`.

- [ ] **Step 1: Create the SwiftUI bridge**

Create `Sources/ClaudeMeter/Support/TextScaleEnvironment.swift`:

Use the explicit `EnvironmentKey`, **not** the `@Entry` macro. Verified on this
machine: `@Entry` fails with `external macro implementation type
'SwiftUIMacros.EntryMacro' could not be found; plugin for module 'SwiftUIMacros'
not found`, under both bare `swiftc` and a real `swift build` on a
`swift-tools-version:6.2` / `.macOS(.v26)` package. The toolchain is
CommandLineTools-only (`xcode-select -p` → `/Library/Developer/CommandLineTools`,
no `/Applications/Xcode.app`), so the SwiftUI macro plugin is absent from both the
`swift build` and `xcodebuild` paths. The explicit key works everywhere and costs
six lines.

```swift
import SwiftUI
import ClaudeMeterCore

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: TextScale = .standard
}

extension EnvironmentValues {
    /// How large this subtree renders. Set by whichever view owns `Settings`;
    /// read by every view with hardcoded design sizes.
    var textScale: TextScale {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension TextScale {
    /// A system font at the scaled size.
    ///
    /// Returns a `Font` value rather than wrapping the view in a `ViewModifier`
    /// so each call site stays a one-for-one replacement of the
    /// `.font(.system(size:))` it replaces, and so the two hierarchies that
    /// re-render every second gain no extra layers.
    ///
    /// Existing `.monospacedDigit()` chains keep working untouched: it is an
    /// environment transform applied after font resolution, independent of
    /// nesting depth.
    func font(_ size: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight)
    }

    /// A scaled layout metric: padding, spacing, corner radius, frame.
    ///
    /// Deliberately unrounded, unlike `font()`. Fractional layout is fine, and
    /// rounding every metric would introduce drift that whole-point font sizes
    /// need but layout does not.
    func pt(_ value: Double) -> CGFloat {
        CGFloat(value * multiplier)
    }
}
```

**If `@Entry` fails to compile**, use the explicit key instead. `@Entry` is a macro
and this is the awkward combination for it: an app target in Swift 5 language mode
(`Package.swift:33`) declaring an entry whose type comes from a Swift 6 module.
Replace only the `EnvironmentValues` extension with:

```swift
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: TextScale = .standard
}

extension EnvironmentValues {
    /// How large this subtree renders. Set by whichever view owns `Settings`;
    /// read by every view with hardcoded design sizes.
    var textScale: TextScale {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}
```

Everything downstream is identical either way: the call sites use `\.textScale`
and never name the key.

- [ ] **Step 2: Add the persisted property to `Settings`**

In `Sources/ClaudeMeter/Support/Settings.swift`, add the import after line 2:

```swift
import ClaudeMeterCore
```

Add the property after `displayMode` (after line 36):

```swift
    @Published var textScale: TextScale {
        didSet { defaults.set(textScale.rawValue, forKey: Keys.textScale) }
    }
```

In `init`, after the `displayMode` line:

```swift
        self.textScale = TextScale.fromStored(defaults.string(forKey: Keys.textScale))
```

In `private enum Keys`, after `displayMode`:

```swift
        static let textScale = "textScale"
```

No migration is needed: the key has never existed, and absent means `.standard`.

- [ ] **Step 3: Add the picker and scale the Settings window**

In `Sources/ClaudeMeter/Views/SettingsView.swift`, add a scale accessor after the two `@ObservedObject` properties (after line 8):

```swift
    /// Read from `settings` directly rather than the environment: this view sets
    /// the environment value for its own children, and a value set in `body`
    /// does not apply to the view that sets it.
    private var scale: TextScale { settings.textScale }
```

Replace `body` (lines 10-20):

```swift
    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            autoResumeTab
                .tabItem { Label("Auto-Resume", systemImage: "bolt.fill") }
        }
        .frame(width: scale.pt(460), height: scale.pt(400))
        .environment(\.textScale, scale)
    }
```

In `generalTab`, add the picker directly below the "Menu-bar style" picker (after line 29):

```swift
                Picker("Text size", selection: $settings.textScale) {
                    ForEach(TextScale.allCases) { Text($0.title).tag($0) }
                }
```

In `sectionHeader`, replace line 148:

```swift
        .font(scale.font(12, weight: .semibold))
```

- [ ] **Step 4: Build and verify the setting works end to end**

Run: `swift build -c release`
Expected: builds with no errors and no new warnings.

Run: `./build.sh --install`

Then, in the running app: open Settings ▸ General. Confirm a **Text size** row sits under **Menu-bar style** with four options. Select **Largest**. Expected: the section header text grows and the window itself gets wider and taller. Quit and relaunch the app, reopen Settings, and confirm **Largest** is still selected (proving `UserDefaults` persistence).

If the window does **not** resize, the cause is `NSHostingController` not propagating `preferredContentSize`; fix by adding `hosting.sizingOptions = [.preferredContentSize]` in `SettingsWindowController.show()` after line 20.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeter/Support/TextScaleEnvironment.swift \
        Sources/ClaudeMeter/Support/Settings.swift \
        Sources/ClaudeMeter/Views/SettingsView.swift
git commit -m "feat(settings): add text size preference and scale the Settings pane"
```

---

### Task 3: Scale `UsageRow` and `Sparkline`

Smallest surface, done first so the call-site pattern is reviewed on a tiny diff before it is applied 29 times in Task 4.

**Files:**
- Modify: `Sources/ClaudeMeter/Views/UsageRow.swift:5-33`
- Modify: `Sources/ClaudeMeter/Views/Sparkline.swift:4-31`

**Interfaces:**
- Consumes: `\.textScale`, `TextScale.font(_:weight:)`, `TextScale.pt(_:)` from Task 2.
- Produces: nothing new. Both views read the environment; callers set it.

- [ ] **Step 1: Scale `UsageRow`**

In `Sources/ClaudeMeter/Views/UsageRow.swift`, add after `let now: Date` (line 8):

```swift
    @Environment(\.textScale) private var scale
```

Then four replacements:

| Line | Before | After |
|---|---|---|
| 11 | `VStack(alignment: .leading, spacing: 5) {` | `VStack(alignment: .leading, spacing: scale.pt(5)) {` |
| 14 | `.font(.system(size: 12, weight: .semibold))` | `.font(scale.font(12, weight: .semibold))` |
| 17 | `.font(.system(size: 12))` | `.font(scale.font(12))` |
| 28 | `.font(.system(size: 10))` | `.font(scale.font(10))` |

Leave the `.monospacedDigit()` calls at lines 19 and 30 exactly as they are. Leave the `ProgressView` at lines 22-24 alone: its intrinsic height is fixed and raising it means replacing it with a custom bar, which is out of scope.

- [ ] **Step 2: Scale the `Sparkline` stroke**

In `Sources/ClaudeMeter/Views/Sparkline.swift`, add after `var color: Color = ...` (line 6):

```swift
    @Environment(\.textScale) private var scale
```

Replace line 31:

```swift
                    .stroke(color, style: StrokeStyle(lineWidth: scale.pt(1.5), lineJoin: .round))
```

The rest of `Sparkline` needs no change: it is entirely `GeometryReader`-driven with no fonts and no fixed dimensions, and its height comes from the caller.

- [ ] **Step 3: Build**

Run: `swift build -c release`
Expected: builds clean.

- [ ] **Step 4: Verify no test regression**

Run: `swift test`
Expected: PASS. (These are view changes with no core logic, so no new tests; the suite confirms nothing upstream broke.)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeter/Views/UsageRow.swift Sources/ClaudeMeter/Views/Sparkline.swift
git commit -m "feat(views): scale UsageRow text and Sparkline stroke"
```

---

### Task 4: Scale `MenuContentView`

The largest mechanical change: 29 font sites plus every layout literal, including the signed-out login path that a partial pass would miss.

**Files:**
- Modify: `Sources/ClaudeMeter/Views/MenuContentView.swift` (throughout)

**Interfaces:**
- Consumes: `\.textScale`, `font(_:weight:)`, `pt(_:)` from Task 2.
- Produces: nothing new.

- [ ] **Step 1: Add the environment property**

In `Sources/ClaudeMeter/Views/MenuContentView.swift`, add after `@EnvironmentObject var settings: Settings` (line 14):

```swift
    @Environment(\.textScale) private var scale
```

`AppDelegate.openPopover()` already injects `settings` as an environment object; Task 6 adds the matching `.environment(\.textScale, ...)`. Until then the view compiles and renders at `.standard`.

- [ ] **Step 2: Replace every font call site**

**Mandatory before you start**, since this step edits from a table rather than by reading the file:

Run: `grep -c '\.system(size:' Sources/ClaudeMeter/Views/MenuContentView.swift`
Expected: `29`. If it is not 29, the file has drifted from this plan and the line numbers below cannot be trusted. Stop and re-derive them with `grep -n` before editing.

Mechanical rule: `.font(.system(size: N))` becomes `.font(scale.font(N))`, and `.font(.system(size: N, weight: W))` becomes `.font(scale.font(N, weight: W))`. All 29 sites, by line:

- Line 39: `size: 13, weight: .bold`
- Lines 68, 71: `size: 11`, `size: 12`
- Lines 80, 82, 85: `size: 11, weight: .medium`, `size: 11`, `size: 11`
- Line 90: `size: 10`
- Line 101: `size: 10`
- Lines 111, 113, 118: `size: 12, weight: .semibold`, `size: 11`, `size: 11`
- Lines 128, 135, 139, 145, 146: `size: 10`, `size: 10`, `size: 11`, `size: 11`, `size: 11`
- Line 159: `size: 11`
- Lines 192, 195, 201: `size: 12`, `size: 10`, `size: 10`
- Lines 210, 213, 215: `size: 12`, `size: 10`, `size: 11`
- Lines 221, 224, 228, 232, 238: `size: 11`, `size: 11`, `size: 10`, `size: 11`, `size: 11`
- Line 249: `size: 11`

**Mandatory after editing:**

Run: `grep -c '\.system(size:' Sources/ClaudeMeter/Views/MenuContentView.swift`
Expected: `0`. Any non-zero count means a site was missed, and it will render at
`.standard` while everything around it grows.

- [ ] **Step 3: Replace every layout literal**

`VStack`/`HStack` spacings, paddings and frames, by line:

| Line | Before | After |
|---|---|---|
| 20 | `spacing: 12` | `spacing: scale.pt(12)` |
| 31 | `.padding(14)` | `.padding(scale.pt(14))` |
| 32 | `.frame(width: 300)` | `.frame(width: scale.pt(300))` |
| 37 | `spacing: 6` | `spacing: scale.pt(6)` |
| 59 | `spacing: 12` | `spacing: scale.pt(12)` |
| 76 | `spacing: 6` | `spacing: scale.pt(6)` |
| 77 | `spacing: 4` | `spacing: scale.pt(4)` |
| 95 | `.frame(height: 28)` | `.frame(height: scale.pt(28))` |
| 96 | `.padding(.top, 2)` | `.padding(.top, scale.pt(2))` |
| 109 | `spacing: 6` | `spacing: scale.pt(6)` |
| 120 | `.padding(8)` | `.padding(scale.pt(8))` |
| 121 | `cornerRadius: 8` | `cornerRadius: scale.pt(8)` |
| 126 | `spacing: 8` | `spacing: scale.pt(8)` |
| 158 | `.frame(width: 28)` | `.frame(width: scale.pt(28))` |
| 190 | `spacing: 10` | `spacing: scale.pt(10)` |
| 206 | `spacing: 10` | `spacing: scale.pt(10)` |
| 207 | `spacing: 8` | `spacing: scale.pt(8)` |
| 219 | `spacing: 8` | `spacing: scale.pt(8)` |

Line 158 is the one that visibly breaks without this change: the `⋯` menu clips at larger fonts.

Lines 190, 206, 207 and 219 are the signed-out and login states, the first screen a new user sees. Do not skip them because the popover is normally signed in.

- [ ] **Step 4: Build**

Run: `swift build -c release`
Expected: builds clean.

- [ ] **Step 5: Verify visually at both extremes**

Run: `./build.sh --install`

With the app signed in, set Settings ▸ General ▸ Text size to **Default**, open the dropdown, and note the layout. Switch to **Largest** and reopen the dropdown. Confirm: all text is visibly larger, the panel is proportionally wider, the `⋯` button is not clipped, the sparkline is taller, and nothing is truncated or overlapping.

Then sign out (footer ▸ Sign out) and check the signed-out panel at **Largest** too: the "Connect your Claude account" copy, the error line, and the "Paste code manually" link should all be scaled.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeMeter/Views/MenuContentView.swift
git commit -m "feat(views): scale the dropdown popover with text size"
```

---

### Task 4b: Scale the Settings pane's semantic `.caption` labels

Added during execution. The Task 3 review surfaced a gap in this plan: `SettingsView` uses
`.font(.caption)` at six sites, and the plan's conversion rule only ever mentioned
`.font(.system(size:))`. Semantic fonts do not scale on macOS (finding 1 of the Empirical
Findings applies to them as much as to absolutes), so as written the Settings pane would ship
half-scaled: a scaled section header above six fixed-size body labels. The spec says the
Settings pane scales, so this closes it.

**Files:**
- Modify: `Sources/ClaudeMeter/Views/SettingsView.swift:64,86,113,115,128,143`

**Interfaces:**
- Consumes: the `scale` computed property already added to `SettingsView` in Task 2, and
  `TextScale.font(_:weight:)`.
- Produces: nothing new.

- [ ] **Step 1: Confirm the site count**

Run: `grep -c '\.font(\.caption' Sources/ClaudeMeter/Views/SettingsView.swift`
Expected: `6`. If not 6, stop and re-derive the lines with `grep -n`.

- [ ] **Step 2: Convert all six**

macOS `.caption1` measures **exactly 10.0pt** (verified via
`NSFont.preferredFont(forTextStyle: .caption1).pointSize`), so `scale.font(10)` is
size-preserving at `.standard` and scales correctly above it. No visual change at the default
setting is expected or acceptable.

| Line | Before | After |
|---|---|---|
| 64 | `.font(.caption).foregroundStyle(.secondary)` | `.font(scale.font(10)).foregroundStyle(.secondary)` |
| 86 | `.font(.caption).foregroundStyle(.secondary)` | `.font(scale.font(10)).foregroundStyle(.secondary)` |
| 113 | `.font(.caption).foregroundStyle(.secondary)` | `.font(scale.font(10)).foregroundStyle(.secondary)` |
| 115 | `.font(.caption).foregroundStyle(.secondary)` | `.font(scale.font(10)).foregroundStyle(.secondary)` |
| 128 | `.font(.caption.weight(.semibold))` | `.font(scale.font(10, weight: .semibold))` |
| 143 | `.font(.caption).foregroundStyle(.secondary)` | `.font(scale.font(10)).foregroundStyle(.secondary)` |

`scale` is already in scope: Task 2 added `private var scale: TextScale { settings.textScale }`
to this struct.

- [ ] **Step 3: Confirm none remain**

Run: `grep -c '\.font(\.caption' Sources/ClaudeMeter/Views/SettingsView.swift`
Expected: `0`.

- [ ] **Step 4: Build**

Run: `swift build -c release`
Expected: succeeds. One pre-existing deprecation warning at `SettingsView.swift:78` is expected
and not to be fixed here.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeter/Views/SettingsView.swift
git commit -m "feat(settings): scale the Settings pane's caption labels"
```

---

### Task 5: Scale the Live Sessions window, and make it react live

Carries the subtle wiring bug: the window caches its hosting controller, so without explicit injection it would only pick up a scale change on relaunch, while the popover changes instantly.

**Files:**
- Modify: `Sources/ClaudeMeter/App/SessionsWindowController.swift:10-40`
- Modify: `Sources/ClaudeMeter/Views/SessionsView.swift:7-14`, `:48-128`
- Modify: `Sources/ClaudeMeter/Views/SessionRow.swift:6-71`
- Modify: `Sources/ClaudeMeter/App/AppDelegate.swift` (the `sessionsWindow` construction)

**Interfaces:**
- Consumes: `\.textScale`, `font(_:weight:)`, `pt(_:)` from Task 2; `Settings` from Task 2.
- Produces: `SessionsWindowController.init(monitor:armed:settings:onTestResume:)` and `SessionsView(monitor:armed:settings:onTestResume:)`, both with `settings` as the third label.

- [ ] **Step 1: Thread `Settings` into the window controller**

In `Sources/ClaudeMeter/App/SessionsWindowController.swift`, add the stored property after `armed` (line 11):

```swift
    private let settings: Settings
```

Replace the initialiser (lines 15-21):

```swift
    init(monitor: SessionMonitor, armed: ArmedSessions, settings: Settings,
         onTestResume: @escaping (SessionUsage) -> Void = { _ in }) {
        self.monitor = monitor
        self.armed = armed
        self.settings = settings
        self.onTestResume = onTestResume
        super.init()
    }
```

Replace the `NSHostingController` construction (lines 27-28):

```swift
            let hosting = NSHostingController(
                rootView: SessionsView(monitor: monitor, armed: armed, settings: settings,
                                       onTestResume: onTestResume))
```

Replace line 32 so a fresh window opens at a scale-appropriate size:

```swift
            window.setContentSize(NSSize(width: settings.textScale.pt(440),
                                         height: settings.textScale.pt(640)))
```

Note: this applies only when the window is first created. A scale change while the window already exists resizes its *content minimums* (Step 2) but does not force the frame, which is correct, since the window is user-resizable and fighting a manual resize would be worse.

- [ ] **Step 2: Make `SessionsView` observe settings and inject the environment**

In `Sources/ClaudeMeter/Views/SessionsView.swift`, add after `@ObservedObject var armed: ArmedSessions` (line 8):

```swift
    @ObservedObject var settings: Settings
```

Add after the `activeOnly` property (line 12):

```swift
    /// Read from `settings` rather than the environment, since this view sets the
    /// environment value for its children. Observing `settings` is what makes an
    /// already-open window react to a scale change: the hosting controller is
    /// created once and cached, so a value captured at construction would go stale.
    private var scale: TextScale { settings.textScale }
```

Add `import ClaudeMeterCore` is already present at line 2, so no import change.

Replace `body` (lines 48-56):

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: scale.pt(380), minHeight: scale.pt(420))
        .environment(\.textScale, scale)
        .onReceive(ticker) { now = $0 }
    }
```

- [ ] **Step 3: Scale the rest of `SessionsView`**

Fonts (8 sites):

| Line | Before | After |
|---|---|---|
| 62 | `.font(.system(size: 13, weight: .bold))` | `.font(scale.font(13, weight: .bold))` |
| 63 | `.font(.system(size: 10))` | `.font(scale.font(10))` |
| 68 | `.font(.system(size: 10))` | `.font(scale.font(10))` |
| 69 | `.font(.system(size: 11, weight: .semibold))` | `.font(scale.font(11, weight: .semibold))` |
| 78 | `.font(.system(size: 10))` | `.font(scale.font(10))` |
| 93 | `.font(.system(size: 24))` | `.font(scale.font(24))` |
| 95 | `.font(.system(size: 12))` | `.font(scale.font(12))` |
| 99 | `.font(.system(size: 10))` | `.font(scale.font(10))` |

Layout literals (9 rows, 10 substitutions — the `:71` row carries two):

| Line | Before | After |
|---|---|---|
| 59 | `spacing: 8` | `spacing: scale.pt(8)` |
| 61 | `spacing: 1` | `spacing: scale.pt(1)` |
| 67 | `spacing: 3` | `spacing: scale.pt(3)` |
| 71 | `.padding(.horizontal, 7).padding(.vertical, 3)` | `.padding(.horizontal, scale.pt(7)).padding(.vertical, scale.pt(3))` |
| 86 | `.padding(12)` | `.padding(scale.pt(12))` |
| 91 | `spacing: 6` | `spacing: scale.pt(6)` |
| 114 | `.padding(.horizontal, 12)` | `.padding(.horizontal, scale.pt(12))` |
| 122 | `.padding(.leading, 30)` | `.padding(.leading, scale.pt(30))` |
| 125 | `.padding(.vertical, 4)` | `.padding(.vertical, scale.pt(4))` |

Leave line 49 (`spacing: 0`, scaling zero is pointless), line 105 (`LazyVStack(spacing: 0)`, same), and line 77 (`.controlSize(.mini)`, a discrete AppKit size with no continuous knob).

- [ ] **Step 4: Scale `SessionRow`**

In `Sources/ClaudeMeter/Views/SessionRow.swift`, add after `var onArmChange: (Bool) -> Void = { _ in }` (line 14):

```swift
    @Environment(\.textScale) private var scale
```

Fonts (5 sites):

| Line | Before | After |
|---|---|---|
| 24 | `.font(.system(size: 12, weight: .semibold))` | `.font(scale.font(12, weight: .semibold))` |
| 29 | `.font(.system(size: 10))` | `.font(scale.font(10))` |
| 38 | `.font(.system(size: 12, weight: .semibold))` | `.font(scale.font(12, weight: .semibold))` |
| 41 | `.font(.system(size: 9))` | `.font(scale.font(9))` |
| 66 | `.font(.system(size: 8, weight: .bold))` | `.font(scale.font(8, weight: .bold))` |

Layout literals:

| Line | Before | After |
|---|---|---|
| 17 | `spacing: 10` | `spacing: scale.pt(10)` |
| 19 | `.padding(.top, 3)` | `.padding(.top, scale.pt(3))` |
| 21 | `spacing: 2` | `spacing: scale.pt(2)` |
| 22 | `spacing: 6` | `spacing: scale.pt(6)` |
| 34 | `Spacer(minLength: 8)` | `Spacer(minLength: scale.pt(8))` |
| 36 | `spacing: 2` | `spacing: scale.pt(2)` |
| 55 | `.padding(.vertical, 3)` | `.padding(.vertical, scale.pt(3))` |
| 61 | `.frame(width: 8, height: 8)` | `.frame(width: scale.pt(8), height: scale.pt(8))` |
| 68 | `.padding(.horizontal, 4)` | `.padding(.horizontal, scale.pt(4))` |
| 69 | `.padding(.vertical, 1)` | `.padding(.vertical, scale.pt(1))` |
| 70 | `cornerRadius: 3` | `cornerRadius: scale.pt(3)` |

Leave line 50 (`.controlSize(.mini)`) alone.

- [ ] **Step 5: Update the `AppDelegate` construction site**

In `Sources/ClaudeMeter/App/AppDelegate.swift`, find the `sessionsWindow` lazy property (around line 26-33) and add `settings: settings,` to the initialiser call, after the `armed:` argument.

- [ ] **Step 6: Build**

Run: `swift build -c release`
Expected: builds clean. A missing-argument error at the `SessionsWindowController` call site means Step 5 was skipped.

- [ ] **Step 7: Verify the live-reaction fix specifically**

Run: `./build.sh --install`

Open the Sessions window (dropdown ▸ list icon) and **leave it open**. Now open Settings and change Text size from **Default** to **Largest**. Expected: the Sessions window text grows **while it is still open**, without closing or relaunching. This is the whole point of the `@ObservedObject` in Step 2; if it only changes after a relaunch, the injection is captured at construction instead of derived in `body`.

Also confirm at **Largest**: project names and token totals are not truncated, the "N armed" capsule is not clipped, and the row dividers still align.

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeMeter/App/SessionsWindowController.swift \
        Sources/ClaudeMeter/Views/SessionsView.swift \
        Sources/ClaudeMeter/Views/SessionRow.swift \
        Sources/ClaudeMeter/App/AppDelegate.swift
git commit -m "feat(sessions): scale the Live Sessions window and react to scale changes live"
```

---

### Task 6: Scale the menu-bar pill

AppKit, not SwiftUI: an `NSImage` drawn with Core Graphics, whose status-item slot width must be recomputed. Carries the one empirical unknown in the whole feature.

**Files:**
- Modify: `Sources/ClaudeMeter/Views/MenuBarLabel.swift:10-101`, `:105-136`, `:196-202`
- Modify: `Sources/ClaudeMeter/App/AppDelegate.swift:48`, `:208-226`, `:237-244`

**Interfaces:**
- Consumes: `TextScale.menuBarMetrics(base:padding:thickness:textHeight:)` from Task 1.
- Produces: `MenuBarLabel.image(mode:signedIn:snapshot:burn:errorMessage:now:scale:)` and `MenuBarLabel.recommendedSlotWidth(for scale: TextScale) -> CGFloat`.

- [ ] **Step 1: Derive the font and padding from the scale**

In `Sources/ClaudeMeter/Views/MenuBarLabel.swift`, replace the static font and padding constants (lines 68-70):

```swift
    /// Design-time base size. The clamp never returns below this, so the pill is
    /// never smaller than it was before the text-size setting existed.
    private static let baseFontSize: Double = 11
    private static let basePadding: Double = 2
    private static let horizontalPadding: CGFloat = 6

    /// Font and vertical padding for a scale, clamped to the real menu-bar height.
    /// The line-height measurement is what `TextScale` cannot compute itself.
    private static func metrics(for scale: TextScale) -> (font: NSFont, verticalPadding: CGFloat) {
        let clamped = scale.menuBarMetrics(
            base: baseFontSize,
            padding: basePadding,
            thickness: Double(NSStatusBar.system.thickness),
            textHeight: { size in
                let candidate = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(size), weight: .regular)
                return Double(("0" as NSString).size(withAttributes: [.font: candidate]).height)
            })
        return (NSFont.monospacedDigitSystemFont(ofSize: CGFloat(clamped.font), weight: .regular),
                CGFloat(clamped.padding))
    }
```

Keep `lineWidth` and `cornerRadius` as they are: a thicker border at larger text is not an improvement, and the corner radius is already clamped against the rect in `gaugePill`.

- [ ] **Step 2: Thread the scale through the drawing functions**

Change these signatures and pass the metrics down. `image` gains a `scale:` parameter; the three drawing helpers take the resolved font and padding rather than reading statics.

```swift
    static func image(
        mode: DisplayMode,
        signedIn: Bool,
        snapshot: UsageSnapshot?,
        burn: BurnEstimate?,
        errorMessage: String?,
        now: Date,
        scale: TextScale
    ) -> NSImage {
```

Inside `image`, resolve once at the top:

```swift
        let (font, verticalPadding) = metrics(for: scale)
```

Then pass `font: font, verticalPadding: verticalPadding` to every `pill(...)`, `gaugePill(...)` and `glyph(...)` call inside `image` (lines 19, 22, 36, 41, 43, 46, 51).

Update the three helpers to take them as parameters instead of reading the removed statics:

```swift
    private static func pill(text: String, textColor: NSColor, borderColor: NSColor,
                             font: NSFont, verticalPadding: CGFloat) -> NSImage {
```

```swift
    private static func gaugePill(text: String, remaining: Double,
                                  font: NSFont, verticalPadding: CGFloat) -> NSImage {
```

```swift
    private static func glyph(_ glyph: String, color: NSColor,
                              font: NSFont, verticalPadding: CGFloat) -> NSImage {
```

In each body, replace the bare `font` static reference in the `attributes` dictionary with the parameter (same name, so the line is unchanged) and `verticalPadding` likewise. No other logic changes.

`fuelGauge` stays exactly as it is: a fixed 40x18 vector dial whose only text is the 6.5pt E/F labels. It has the same headroom the pill does, so this is a judgment call, not a constraint: redrawing a hand-tuned gauge at arbitrary scales invites regressions for no readability gain.

- [ ] **Step 3: Make the slot width scale-aware**

Replace `recommendedSlotWidth()` (lines 97-101):

```swift
    /// Width of the fixed menu-bar slot, sized to the widest Classic content so the
    /// item never resizes at a given scale (which would shift the button and
    /// misalign the popover).
    static func recommendedSlotWidth(for scale: TextScale) -> CGFloat {
        let reference = "100% · 4h59m"
        let (font, _) = metrics(for: scale)
        let textWidth = (reference as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth + horizontalPadding * 2 + lineWidth * 2 + 4)
    }
```

- [ ] **Step 4: Update `AppDelegate` to pass the scale and resize the slot**

In `Sources/ClaudeMeter/App/AppDelegate.swift`, replace line 48:

```swift
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarLabel.recommendedSlotWidth(for: settings.textScale))
```

In `updateLabel()`, add the length update and pass the scale. Replace the body (lines 208-226):

```swift
    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let mode = settings.displayMode
        let scale = settings.textScale
        let signedIn = auth.isSignedIn
        let snapshot = store.snapshot
        let burn = store.burnEstimate
        let error = store.errorMessage
        let now = Date()

        // Re-assert the slot width here, not just at launch: the width is fixed
        // *per scale*, and a text-size change must widen the slot or the new image
        // lands in a stale one. `settings.objectWillChange` already routes here.
        statusItem.length = MenuBarLabel.recommendedSlotWidth(for: scale)

        var image = NSImage()
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = MenuBarLabel.image(
                mode: mode, signedIn: signedIn, snapshot: snapshot, burn: burn,
                errorMessage: error, now: now, scale: scale
            )
        }
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
    }
```

- [ ] **Step 5: Inject the scale into the popover**

In `openPopover()`, add the environment value to the content chain (after line 243):

```swift
            .environment(\.textScale, settings.textScale)
```

The popover is rebuilt on every open and nilled on close, so this alone is enough for it; no observation is needed.

- [ ] **Step 6: Build**

Run: `swift build -c release`
Expected: builds clean.

- [ ] **Step 7: Measure the actual ceiling (the open empirical question)**

Run: `./build.sh --install`

Cycle Text size through all four values and watch the pill at each. Record which of the four produce a *visibly* different pill. Three outcomes are possible, and they need different responses:

1. **The pill grows at each step up to the clamp.** Expected and fine. Note where it stops growing.
2. **The pill looks identical at every scale.** `NSStatusBarButton` is scaling the oversized image proportionally back down to fit the bar. The height clamp is then the wrong lever: reduce the ladder so no candidate ever exceeds the bar, i.e. drop the compressed-padding branch by passing `padding: 1` as the *preferred* padding, and re-check.
3. **The pill is clipped or vertically off-centre at `largest`.** The 17pt/padding-1 candidate exactly equals the bar thickness with zero margin and reads as cramped. Tighten by requiring one point of margin: pass `thickness: Double(NSStatusBar.system.thickness) - 1`.

Whichever holds, also confirm the pill stays horizontally centred in its slot and that switching display mode (Classic ▸ Burn rate ▸ Mood ▸ Pet ▸ Fuel gauge) at **Largest** never clips.

- [ ] **Step 8: Record the finding**

Add one line to the spec's Verification section stating which of the three outcomes occurred, so the PR description and any future reader know the ceiling was measured rather than assumed. Edit `docs/superpowers/specs/2026-08-06-text-size-setting-design.md`, replacing the "Does `NSStatusBarButton` scale an oversized image proportionally down?" bullet's final sentence with the observed result.

- [ ] **Step 9: Commit**

```bash
git add Sources/ClaudeMeter/Views/MenuBarLabel.swift \
        Sources/ClaudeMeter/App/AppDelegate.swift \
        docs/superpowers/specs/2026-08-06-text-size-setting-design.md
git commit -m "feat(menubar): scale the pill within the status-bar height limit"
```

---

### Task 7: Document, and sweep every surface

**Files:**
- Modify: `README.md:37-39`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Document the setting in the README**

In `README.md`, the "Personality & extras" section opens with a **Display modes** bullet that wrongly says the modes "switch in the dropdown", when they live in Settings (`SettingsView.swift:27`). Replace line 39's opening so it is accurate, and add the text-size bullet directly after that bullet's block:

```markdown
- **Display modes** (Settings ▸ General): `Classic` (% + reset countdown) · `Burn rate`
```

```markdown
- **Text size** (Settings ▸ General): `Default` / `Large` / `Larger` / `Largest`, for
  large or low-DPI displays. Scales the dropdown, the Sessions window and Settings;
  the menu-bar pill scales too, up to the fixed height of the macOS menu bar.
```

Do **not** document this in `CLAUDE.md`: nothing here is a hard-won gotcha of the kind that file collects, and the contributor's global pre-push hook blocks `CLAUDE.md`, which would force a `--no-verify` push.

- [ ] **Step 2: Confirm no font site was missed**

Run:

```bash
grep -rnE '\.font\(\.(system\(size:|caption|body|headline|footnote|title|callout|subheadline)' \
  Sources/ClaudeMeter/Views/ Sources/ClaudeMeter/App/
```

Expected: no output. This catches BOTH absolute `.system(size:)` sites and semantic sites
(`.caption` and friends), which the original narrower grep would have missed — that omission is
what let the six `SettingsView` `.caption` labels slip past the plan until the Task 3 review
caught them. (`MenuBarLabel`'s `NSFont` sizes match neither pattern and are handled by
`metrics(for:)`.)

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: PASS, including the 7 `TextScaleTests`.

- [ ] **Step 4: Full-surface sweep at both extremes**

Run: `./build.sh --install`

At **Default**, then at **Largest**, check all four surfaces:

| Surface | What to confirm |
|---|---|
| Menu-bar pill | Grows to the recorded ceiling, centred, not clipped, in all five display modes |
| Dropdown, signed in | Wider panel, no truncation, `⋯` not clipped, sparkline taller, cooldown box intact at low usage |
| Dropdown, signed out | Login copy, error line and "Paste code manually" all scaled |
| Sessions window | Reacts while open, no truncation, "N armed" capsule intact, dividers aligned |
| Settings window | All three tabs fit without scrolling, window grows, picker previews itself |

The known cosmetic limitation: the linear `ProgressView` in each usage row stays hairline-thin, because its intrinsic height is fixed and raising it means replacing it with a custom bar. This is accepted, not a bug to chase.

- [ ] **Step 5: Verify the diff is scoped**

Run: `git diff main --stat`

Expected: only the files in the File Structure table. Specifically **no** changes under `Widget/`, and **no** change to `CLAUDE.md`.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: document the text size setting"
```

- [ ] **Step 7: Fork, push, and open the PR**

The contributor has `pull` permission only on `AnywaySolutionsSro/claudemeter`, so this goes through a fork:

```bash
gh repo fork AnywaySolutionsSro/claudemeter --remote=false
git remote add fork https://github.com/datune/claudemeter.git
git push fork feat/text-size-setting
gh pr create --repo AnywaySolutionsSro/claudemeter \
  --head datune:feat/text-size-setting \
  --title "feat: add a text size setting for large displays"
```

The PR body should state: what the setting does, that `@ScaledMetric` and `.dynamicTypeSize()` were measured inert on macOS 26 (which is why a custom multiplier exists), the measured menu-bar ceiling from Task 6 Step 7, and the accepted `ProgressView` limitation. Confirm with the repo owner before pushing, since this is an outward-facing action.

---

## Self-Review

**Spec coverage.** Every section maps to a task: mechanism and `TextScale` → Task 1; the SwiftUI bridge, persistence and UI → Task 2; "Why spacing scales too" → Tasks 3, 4, 5 (the rule is applied per file, with the spec's two exclusions honoured in Task 3 Step 1, Task 5 Step 3 and Task 5 Step 4); "Menu-bar ceiling" → Task 6; all five wiring fixes → fix 1 in Task 5 Step 2, fix 2 in Task 6 Step 4, fix 3 across Tasks 4/5/2, fix 4 in Task 4 Step 3, fix 5 in Task 2 Step 3; Verification → Task 6 Step 7 and Task 7 Step 4; Documentation → Task 7 Step 1; Commit and PR → Task 7 Step 7. Non-goals are enforced by Task 7 Step 5.

**Placeholder scan.** No TBD/TODO. Every code step carries real code or an exhaustive line-by-line table. The one genuinely unknown value, the pill's visual ceiling, is not left as "handle appropriately": Task 6 Step 7 enumerates all three possible outcomes with the specific response to each.

**Type consistency.** `menuBarMetrics(base:padding:thickness:textHeight:)` returning `(font: Double, padding: Double)` is defined in Task 1 and consumed with that exact signature in Task 6 Step 1. `font(_:weight:)` returning `Font` and `pt(_:)` returning `CGFloat` are defined in Task 2 and used with those names in Tasks 3, 4, 5. `scaled(_:)` takes and returns `Double` throughout. `SessionsWindowController.init(monitor:armed:settings:onTestResume:)` is defined in Task 5 Step 1 and called with that label order in Task 5 Step 5. `MenuBarLabel.image(...scale:)` is defined in Task 6 Step 2 and called in Task 6 Step 4. `recommendedSlotWidth(for:)` likewise.
