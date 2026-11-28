# Time format setting (12h / 24h) — short design

Date: 2026-11-27 · Status: draft for approval · Ships as its own PR, before Codex support.

- **Why:** Jakub wants to pick 12-hour (AM/PM) or 24-hour time across the whole app.
- **Setting:** Settings → General → "Time format": System (default, today's behaviour) /
  24-hour / 12-hour.
- **Scope:** every rendered time — reset times, "Updated…", "as of…", update reminder, API spend
  fetch time, Sessions window, notifications, all widgets. Date order and weekday names stay
  locale-driven. Non-display formatters (ISO, HTTP dates) untouched.
- **How:** a `ClockStyle` enum in `ClaudeMeterCore` and one formatter entry point
  (`Formatting.time` / the existing reset-moment formatter taking the style instead of only
  `uses12Hour(locale)`); the ~10 ad-hoc `.formatted(time: .shortened)` call sites switch to it.
  Unit-tested in core.
- **Widget:** can't read the app's defaults (sandbox), so `clockStyle` rides as an optional field
  in `snapshot.json` and `api-spend.json`; a missing field means System.
- **Approaches:** only sensible one — a per-view `Environment` value would still need the widget
  file field and wouldn't cover notifications.
- **Left to builder:** naming, file layout, Settings wording.
