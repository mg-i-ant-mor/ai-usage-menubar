# Pace-aware risk signals — design

Issue: mg-i-ant-mor/ai-usage-menubar#22. Supersedes the risk parts of #21.

## Intent

AI Usage forecasts well (exhaustion time, daily budget) but signals badly:

1. **Blind start, then a sudden flip.** `QuotaWindow.minimumElapsedFraction = 0.1`
   silences the forecast for the first 10% of a window, then the ⏳ can switch
   on at once.
2. **Level colours ignore pace.** Tiles turn orange from 60% and red from 85%,
   even when usage is well under pace.
3. **Binary risk.** A window is at risk or not; the pace tick on the bar takes
   its colour from usage only.

The fix borrows TokenEater's signalling (MIT, `Shared/Helpers/SmartColor.swift`,
`PacingCalculator.swift`) on top of the existing forecast, which stays.

## Goals

- Signal grows smoothly from the start of the window (no 10% gate).
- A high reading on a calm pace stays muted; a reading projected past the
  limit keeps full colour; 100% is always red.
- Graded zones drive the ⏳ and the pace tick, without flicker at a boundary.
- Tooltip says when you would be back on pace if you paused.
- Claude's own `limits[].severity` is shown as information.

## Non-goals

- Predicting from recent readings (needs stored history).
- TokenEater's sensitivity profiles or a user setting for the calibration.
- Claude's `pace` / `indicator` fields (null on both accounts checked) and
  Claude Code's early-warning thresholds (dropped from #21).
- Colouring the menu bar icon (it has no colour today).

## Anti-goals

- Severity must never drive risk, ⏳, zones or colours: it read `"warning"` at
  76% while under pace, so it would undo the pace-aware muting.
- Tile, menu bar ⏳ and tooltip must never disagree about the zone.

## Calibration (decided by simulation)

Replay of real Claude Code usage from this Mac (25,829 requests, 2026-07-24 →
2026-11-26; 868 scaled 5 h windows, 126 weekly), one reading every 5 minutes.
`k` barely matters and plateaus from about 8; the margin is the real lever.

| ⏳ rule (k = 8) | Session lead / missed / false alarm | Weekly, calendar | Weekly, working time |
|---|---|---|---|
| today (10% gate, used > elapsed) | 0.8 h / 14% / 77% | 1.0 d / 4% / 67% | 2.9 d / 8% / 67% |
| margin 5 (chosen) | 0.8 h / 8% / 70% | 0.9 d / 15% / 54% | 2.1 d / 12% / 59% |
| margin 10 | 0.5 h / 10% / 62% | 0.5 d / 18% / 39% | 1.4 d / 14% / 46% |

The user chose **k = 8, margin 5, hysteresis 5**, as named constants in one
place so each is a one-line change. No settings UI.

## Approaches

- **A. Zone held in the store (chosen).** `UsageStore` computes each window's
  pace reading when a snapshot arrives, from the previous reading of the same
  window. Tile, menu bar and tooltip read the same value. The ⏳ changes only
  on a refresh (5 minutes by default), as in the simulation.
- **B. Zone held in the views.** `@State` in the tile plus a separate memory
  in the menu bar. No store change, but two memories can disagree near a
  boundary and the tile's is lost when the panel closes. Rejected.
- **No hysteresis.** Rejected: the user asked for it, and it needs memory.

## Design

### The pace reading (pure, in `AIUsage/Models/`)

A value computed for a `QuotaWindow` at its reading time (`fetchedAt`), with the
active `WorkSchedule?` and the previous zone of the same window:

- `elapsed` = `onPacePercent(now: fetchedAt, schedule:)` / 100 (already
  schedule-aware: working time for windows longer than a day, calendar time
  otherwise). No start or reset → no pace reading at all, and every surface
  behaves as today without a forecast (level colours unmuted, no tick, no ⏳).
- `confidence = 1 − e^(−k·elapsed)`, k = 8.
- `delta = used% − elapsed%`; `weighted = delta × confidence`.
- **Zone** from `weighted`, margin m = 5, hysteresis h = 5:
  - on track `≤ m` (includes under pace), ahead `m … 2m`, far ahead `> 2m`;
  - falling: far ahead is held until `weighted ≤ 2m − h`, ahead until
    `weighted ≤ m − h`. Rising never waits.
  - Builder's call made here: TokenEater's "chill" zone is merged into on
    track, because the agreed colours show it the same way. Add it back when
    something needs to show it.
- **Colour weight** `f = smoothstep(0.7, 1.0, used / elapsed)`; `f = 1` when
  `elapsed` is 0. Not confidence-weighted.
- **Cooling date** (only when `delta > 0`): when the on-pace line reaches the
  current usage if nothing more is used. Calendar windows:
  `fetchedAt + delta/100 × length`. Working-time windows:
  `schedule.date(byAddingWorkingTime: delta/100 × totalWorkingTime, to: fetchedAt)`.
  Never past the reset.

Constants `k`, `m`, `h` live together as `static let` on the pace type.
`QuotaWindow.minimumElapsedFraction` and its gate in `projectedExhaustion` go.

### Where it is held

`QuotaWindow` gains `var pace: <pace reading>? = nil`, filled by the store, so
it travels with the snapshot to every surface (including other accounts'
snapshots). `UsageStore`:

- on a successful fetch, fills `pace` on each window of the new snapshot (and
  of each `otherAccounts` snapshot), using the previous snapshot's window of the
  same account id and kind as the previous zone;
- gains `setWorkSchedule(_:)`, called where `setRefreshInterval` is called
  (MenuBarController, SettingsView), which recomputes `pace` on the current
  snapshots when the schedule changes.

A failure that keeps the last good snapshot keeps its `pace`. Restart → no
previous zone.

### Risk = zone ahead or far ahead

- At risk = `pace.zone ≥ ahead`, `usedPercent < 100`, and the reset is still
  ahead of `now`. (Builder's call: a full window is red, not at risk; it shows
  the reset line with no ⏳ and no cooling date, as today.)
  `ProviderSnapshot.isAtRisk` / `exhaustion(for:)`, `QuotaTimingPresentation`
  and `MenuBarReading.isAtRisk` / `exhaustsAt` all follow this. When at risk,
  the "Full …" text comes from `projectedExhaustion` as today; when not, the
  tile shows the budget/reset line as today. (Weighted delta > 5 implies used >
  elapsed, so an at-risk window always has an exhaustion time before reset.)
- The ⏳ on the tile is orange when ahead, red when far ahead.
- The menu bar ⏳ and its accessibility suffix are unchanged in form.

### Colours

- **Tile bar fill:** `normalUsage.mix(with: level, by: f)`, where `level` is
  `warning` from 60% and `critical` from 85% (`Color.mix`, macOS 26 target).
  Below 60%, `normalUsage`. At 100%, `critical` regardless of f.
- **Tile number:** same rule, mixing from `labelColor`.
- **Pace tick:** zone colour, not mixed: on track `normalUsage`, ahead
  `warning`, far ahead `critical`.
- **Tooltip icon** (emoji cannot blend), in this order: 🔴 at 100%, or from 85%
  with `f ≥ 0.5`; ⏳ when at risk; 🟠 from 60% with `f ≥ 0.5`; 🟢 otherwise.
- Display mode "left" keeps working from `usedPercent`, as today.

### Cooling date copy

Tooltip only, only when at risk, in the detail line:
`Full by 15:20 at this pace · Back on pace by 16:40 if you pause · Resets 18:00`,
with the existing clock-time formatting. A stale reading (last refresh failed,
last good snapshot kept) shows everything, prefixed with "Not updated":
`Not updated · Full by 15:20 at this pace · Back on pace by 16:40 if you pause · Resets 18:00`
(user's decision; today "Not updated" replaces "Full by …"). The title line
keeps its ⚠️ for stale readings, and the menu bar keeps showing stale over risk.

### Claude severity (information only)

- `QuotaWindow.providerHighUsage: Bool = false`. Only `ClaudeUsageMapper` sets it.
- Carried over from the #21 plan: rows of `limits[]` map to windows as
  `kind == "session"` → Session, `"weekly_all"` → Weekly, `"weekly_scoped"` with
  `scope.model.display_name` starting with "sonnet" / "fable" (case-insensitive)
  → Sonnet / Fable. A row counts when `severity` is a string other than
  `"normal"`; missing or non-string is no flag. Tests carried over:
  `testClaudeReadsServerSeverity`, `testClaudeWithoutSeverityHasNoWarning`
  (assert `providerHighUsage`).
- Tile: a small secondary-colour `exclamationmark.circle` after the title, with
  help text and VoiceOver "Claude: high usage". No extra line, so the tile keeps
  its compact height.
- Tooltip: an indented line `Claude: high usage` under that window.
- `docs/provider-contracts.md` documents the field; `pace` / `indicator` are
  noted as present but not read.

## Constraints

- Swift / SwiftUI, XCTest; `xcodebuild test -project AIUsage.xcodeproj -scheme
  AIUsage -destination 'platform=macOS'`. No new dependencies.
- Applies to every provider with a start and a reset, not only Claude.
- Branch from `develop`, PR to `develop`. No Claude attribution in commits or PR.
- The old plan `docs/superpowers/plans/2026-11-26-claude-native-usage-warnings.md`
  is deleted once the new plan exists.

## Docs and README images (builder's call)

- Update the prose that describes the old behaviour: `PRODUCT.md` (forecast and
  on-pace mark, about lines 62-80) and `README.md` (about lines 47-51 and
  112-125): average pace now confidence-weighted, ⏳ from a margin, zone memory
  kept in memory between refreshes, tick in the zone colour, muted level colours.
- `ReadmeShowcaseTests` and `scripts/render_readme_images.sh` go through a real
  `UsageStore`: keep their fixtures compiling and adjust them so the hero still
  shows an at-risk session. Re-rendering the images needs Screen Recording and a
  screen, so it is left to the user, flagged in the PR.

## Left to the builder

- Names of the pace type, its zone enum and helpers; which file they live in.
- How the store pairs old and new windows (by account id + kind).
- Test layout, beyond: the pace maths (confidence, zones with hysteresis, f,
  cooling date in calendar and working time), the store carrying the previous
  zone across fetches and recomputing on a schedule change, risk following the
  zone, tooltip icons and copy, severity mapping, and a visual check that the
  tile stays compact with the severity icon.
