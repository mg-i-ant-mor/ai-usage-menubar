# Usage Pace Forecast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For each quota window, project when it runs out at its current average pace and warn when that comes before the reset.

**Architecture:** Each mapper sets the moment its window started (`QuotaWindow.startsAt`), from the provider's own data or from `resetsAt` minus the window's known length. A pure function on `QuotaWindow` derives the projected exhaustion from `startsAt`, `resetsAt`, `usedPercent`, and the snapshot's `fetchedAt`. The quota tile and the menu bar label read that function. Nothing is stored between refreshes.

**Tech Stack:** Swift, SwiftUI/AppKit, XCTest, macOS 26, Xcode 27.

**Spec:** https://github.com/burakgon/ai-usage-menubar/issues/33 (updated body), plus `PRODUCT.md`.

## Global Constraints

- The feature keeps no usage history, cache, or persisted samples (`PRODUCT.md`: "AI Usage creates no usage cache or history of its own").
- No new dependencies and no new permissions. There are no notifications in this version.
- Status and meaning must never depend on color alone. The at-risk state needs a symbol and accessibility text.
- The primary experience stays compact and non-scrolling. `VisualSnapshotTests` size bounds must still pass.
- Test command: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`. Add `-only-testing:AIUsageTests/<Class>/<test>` to run a single test.
- The test target uses synchronized folders, so new files in `AIUsageTests/` need no `project.pbxproj` edit.
- Commit messages carry no Claude attribution (the user's global rule).

## Review Focus

1. **Stale reading.** `usedPercent` was measured at `fetchedAt`, not at render time. The projection must use `fetchedAt` as its clock, otherwise an hourly refresh makes the pace look slower and slower as time passes until the next fetch. *Task 1 test `testProjectionUsesMeasurementTimeNotRenderTime`.*
2. **Short months.** A monthly window ending 1 March starts on 1 February (28 days), not 30 days earlier. *Task 3 test `testMonthlyStartIsOneCalendarMonthBeforeReset`.*
3. **Projected exhaustion already in the past** (refresh is late, pace is high). The tile must not show a negative or empty countdown. *Task 4 test `testPastProjectionReadsFullSoon`.*
4. **Window already at 100%, or a reset already passed** (`fetchedAt >= resetsAt`). There is no forecast, and the tile keeps its existing critical styling. *Task 1 tests `testNoProjectionAtOrAbove100Percent` and `testNoProjectionAfterReset`.*
5. **Narrow tile.** A two-column tile with `Full 1h 20m · Reset 3h 5m` must not overflow. It falls back to the short text through `ViewThatFits`. *Task 4 test `testAtRiskTileStaysCompact`.*

---

### Task 1: Window start and pace projection on `QuotaWindow`

**Files:**
- Modify: `AIUsage/Models/ProviderModels.swift:358-365` (`QuotaWindow`)
- Create: `AIUsageTests/PaceForecastTests.swift`

**Interfaces:**
- Produces:
  - `QuotaWindow.startsAt: Date?`, declared `var startsAt: Date? = nil` so the memberwise init keeps working at every existing call site.
  - `QuotaWindow.minimumElapsedFraction: Double = 0.1` (static).
  - `func QuotaWindow.projectedExhaustion(measuredAt: Date) -> Date?`

- [ ] **Step 1: Write the failing tests** in `AIUsageTests/PaceForecastTests.swift` (`final class PaceForecastTests: XCTestCase`).

  All tests use `t0 = Date(timeIntervalSince1970: 1_800_000_000)` and a 5h session `QuotaWindow(kind: .session, usedPercent: U, resetsAt: t0 + 5h, startsAt: t0)`, measured at `M`:
  - `testProjectsExhaustionBeforeReset`: U=40, M=t0+1h → `t0 + 2.5h`
  - `testNoProjectionWhenPaceReachesResetFirst`: U=10, M=t0+1h → `nil` (projection t0+10h is after the reset)
  - `testNoProjectionBeforeTenPercentElapsed`: U=30, M=t0+20min → `nil` (10% of 5h is 30min)
  - `testNoProjectionAtZeroUsage`: U=0, M=t0+2h → `nil`
  - `testNoProjectionAtOrAbove100Percent`: U=100, M=t0+1h → `nil`
  - `testNoProjectionWithoutStartOrReset`: `startsAt: nil` → `nil`, and `resetsAt: nil` → `nil`
  - `testNoProjectionAfterReset`: U=50, M=t0+5h → `nil`
  - `testProjectionUsesMeasurementTimeNotRenderTime`: U=40, M=t0+1h gives `t0 + 2.5h`. The result depends only on the window and `measuredAt`, so the same call returns the same date whenever it is evaluated (assert equality across two calls; there is no `now` parameter).

- [ ] **Step 2: Run the tests and confirm they fail.** Run `-only-testing:AIUsageTests/PaceForecastTests`. Expected: compile failure, because `startsAt` and `projectedExhaustion` don't exist yet.

- [ ] **Step 3: Implement.** Add `var startsAt: Date? = nil` after `resetsAt` (it must stay last so the existing positional memberwise calls compile). Add `projectedExhaustion(measuredAt:)`:

  ```swift
  guard let start = startsAt, let reset = resetsAt,
        usedPercent > 0, usedPercent < 100,
        start < measuredAt, measuredAt < reset else { return nil }
  let elapsed = measuredAt.timeIntervalSince(start)
  guard elapsed >= reset.timeIntervalSince(start) * Self.minimumElapsedFraction
  else { return nil }
  let exhaustion = measuredAt.addingTimeInterval(
      (100 - usedPercent) * elapsed / usedPercent
  )
  return exhaustion < reset ? exhaustion : nil
  ```

- [ ] **Step 4: Run the tests and confirm they pass.** Same command. Expected: all PASS. Then run the full suite to confirm the existing `QuotaWindow(...)` call sites still compile.

- [ ] **Step 5: Commit** `Project when a quota window runs out at its current pace`.

---

### Task 2: Window starts for session, daily, and weekly windows

**Files:**
- Modify: `AIUsage/Infrastructure/ProviderParsing.swift` (helper)
- Modify: `AIUsage/Providers/Claude/ClaudeUsageMapper.swift` (`appendWindow`, `appendFable`)
- Modify: `AIUsage/Providers/Codex/CodexUsageMapper.swift` (`window(kind:outputKind:candidates:now:)`)
- Modify: `AIUsage/Providers/Antigravity/AntigravityUsageMapper.swift` (`window(kind:bucket:)`)
- Modify: `AIUsage/Providers/Grok/GrokUsageMapper.swift`
- Modify: `AIUsage/Providers/Devin/DevinUsageMapper.swift` (`window(_:_:)`)
- Modify: `AIUsage/Providers/ZAI/ZAIUsageMapper.swift` (`window(_:)`, `tokenWindowKind`)
- Test: `AIUsageTests/MapperTests.swift`, `AIUsageTests/AntigravityTests.swift`, `AIUsageTests/ZAITests.swift`

**Interfaces:**
- Consumes: `QuotaWindow.startsAt` (Task 1).
- Produces: `static func ProviderParsing.windowStart(endingAt reset: Date?, length: TimeInterval) -> Date?`, which returns `reset - length`, or `nil` when `reset` is `nil`.

Window lengths:

| Mapper | Window | Length / source |
|---|---|---|
| Claude | `five_hour` → session | 18 000 s |
| Claude | `seven_day`, `seven_day_sonnet`, Fable `weekly_scoped` | 604 800 s |
| Codex | primary/secondary | the window's own `limit_window_seconds`; `nil` when absent (header-only fallback) |
| Antigravity | `*-5h` buckets → session / claudePool | 18 000 s |
| Antigravity | `*-weekly`, argon weekly | 604 800 s |
| Grok | weekly period | `currentPeriod.start` when present, otherwise 604 800 s |
| Devin | daily / weekly | 86 400 s / 604 800 s |
| Z.ai | token limits | `unit` × `number` seconds, from the computation already in `tokenWindowKind` |
| Z.ai | `TIME_LIMIT` (web searches) | `nil`: no declared length |

- [ ] **Step 1: Write the failing tests.** Extend the existing mapper tests with one assertion per window kind: `XCTAssertEqual(window.startsAt, window.resetsAt?.addingTimeInterval(-length))`. In `testClaudeMapsAllSupportedWindowsAndPlan`, assert all four windows. In `testCodexClassifiesWeeklyInPrimaryAndMapsSpark`, assert the weekly window starts 604 800 s before its reset. In `testCodexFallsBackToPercentHeadersWhenBodyOmitsPercent`, assert `startsAt == nil`. Add `testGrokUsesPeriodStartWhenPresent`: fixture with `"start": "2027-01-08T00:00:00Z"` → `startsAt` equals that date. Antigravity and Z.ai get the same in their own test files, plus Z.ai web searches → `nil`.

- [ ] **Step 2: Run the tests and confirm they fail.** Run `-only-testing:AIUsageTests/MapperTests -only-testing:AIUsageTests/AntigravityTests -only-testing:AIUsageTests/ZAITests`. Expected: FAIL on `startsAt` being `nil`.

- [ ] **Step 3: Implement.** Add the helper. In each mapper, pass `startsAt:` with the length from the table. For Z.ai, have `tokenWindowKind` also expose the seconds it already computes; return a `(kind, seconds)` tuple rather than computing it twice.

- [ ] **Step 4: Run the tests and confirm they pass.** Same command, then the full suite.

- [ ] **Step 5: Commit** `Give session, daily and weekly windows their start time`.

---

### Task 3: Window starts for monthly cycles

**Files:**
- Modify: `AIUsage/Infrastructure/ProviderParsing.swift`
- Modify: `AIUsage/Providers/Cursor/CursorUsageMapper.swift`
- Modify: `AIUsage/Providers/Copilot/CopilotUsageMapper.swift` (`quotaWindow`, `legacyWindow`)
- Modify: `AIUsage/Providers/Kiro/KiroUsageMapper.swift` (`creditWindow` only)
- Test: `AIUsageTests/MapperTests.swift`, `AIUsageTests/KiroTests.swift`, `AIUsageTests/PaceForecastTests.swift`

**Interfaces:**
- Produces: `static func ProviderParsing.monthStart(endingAt reset: Date?) -> Date?`. It uses `Calendar(identifier: .gregorian)` with `timeZone = UTC` and `date(byAdding: .month, value: -1, to:)`.

- [ ] **Step 1: Write the failing tests.**
  - `testMonthlyStartIsOneCalendarMonthBeforeReset` (PaceForecastTests): reset `2027-03-01T00:00:00Z` → `2027-02-01T00:00:00Z`; reset `2027-03-31T00:00:00Z` → `2027-02-28T00:00:00Z`; `nil` → `nil`.
  - Cursor: in `testCursorMapsTotalAutoAPIAndPlan`, all three windows have `startsAt == monthStart(endingAt: reset)`. Add `testCursorUsesBillingCycleStartWhenPresent`: fixture `"billingCycleStart": 1797500000000` → `startsAt == Date(timeIntervalSince1970: 1_797_500_000)`.
  - Copilot: in `testCopilotConvertsRemainingQuotaToUsed`, `startsAt` is one calendar month before the reset.
  - Kiro: the credits window has a monthly start, and the free-trial window has `startsAt == nil`.

- [ ] **Step 2: Run the tests and confirm they fail.** Expected: compile failure on `monthStart`, then FAIL on `nil` starts.

- [ ] **Step 3: Implement.** Cursor reads `billingCycleStart` with `ProviderParsing.date` and falls back to `monthStart(endingAt: reset)`. Copilot and Kiro credits use `monthStart`. Leave Kiro free trial alone (`nil`).

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit** `Give monthly billing windows their start time`.

---

### Task 4: Forecast on the quota tile

**Files:**
- Modify: `AIUsage/Views/ProviderSectionView.swift` (`QuotaTile` ~366-460, its call site ~339)
- Test: `AIUsageTests/PaceForecastTests.swift`, `AIUsageTests/VisualSnapshotTests.swift`

**Interfaces:**
- Consumes: `projectedExhaustion(measuredAt:)`, `CompactCountdown.text(until:from:)`.
- Produces:

  ```swift
  struct QuotaTimingPresentation: Equatable {
      let isAtRisk: Bool
      let text: String?           // "Full 1h 20m · Reset 3h 5m" or "Reset 3h 5m"
      let compactText: String?    // "Full 1h 20m" when at risk, else == text
      let accessibilityText: String?
      init(window: QuotaWindow, measuredAt: Date, now: Date)
  }
  ```

  Copy:
  - **Not at risk:** keeps today's `Reset <countdown>` / `Resetting`.
  - **At risk:** `Full <countdown> · Reset <countdown>`. The countdown is `Full soon` once the projected exhaustion has passed. Accessibility: `full in <countdown> at this pace, Reset <countdown>`.

- [ ] **Step 1: Write the failing tests** (PaceForecastTests):
  - `testAtRiskTimingShowsFullBeforeReset`: Task 1's U=40 window, measured at t0+1h, now = t0+1h10m → `isAtRisk`, `text == "Full 1h 20m · Reset 3h 50m"`, `compactText == "Full 1h 20m"`.
  - `testSafeTimingKeepsResetOnly`: U=10, same times → `!isAtRisk`, `text == "Reset 3h 50m"`.
  - `testPastProjectionReadsFullSoon`: U=40, measured at t0+1h, now = t0+3h10m → `text == "Full soon · Reset 1h 50m"`.
  - `testAtRiskTileStaysCompact` (VisualSnapshotTests): render a provider surface with two at-risk tiles side by side, the same way `testProviderSurfaceKeepsOddQuotaCountCompact` does, and assert the same width and height bounds as that test.

  The times avoid whole hours on purpose: `CompactCountdown` floors minutes to at least 1, so exactly 4 hours reads `4h 1m`.

- [ ] **Step 2: Run the tests and confirm they fail.**

- [ ] **Step 3: Implement.** Add `QuotaTimingPresentation`, next to `ResetsPresentation`. Give `QuotaTile` a `measuredAt: Date` and pass `snapshot.fetchedAt` from the call site. Replace the reset `HStack` with:
  - Icon `exclamationmark.triangle.fill`, tinted `UsagePalette.warning`, when at risk; otherwise today's `clock`.
  - `ViewThatFits { Text(text); Text(compactText) }`.

  `accessibilityValue` uses `accessibilityText`. Compute the presentation with `context.date` from the existing `TimelineView`.

- [ ] **Step 4: Run the tests and confirm they pass.** Then run the full suite. Its snapshot size bounds are part of the gate.

- [ ] **Step 5: Commit** `Show when a quota window runs out before its reset`.

---

### Task 5: At-risk mark in the menu bar

**Files:**
- Modify: `AIUsage/Store/UsageStore.swift` (`MenuBarReading`, `menuBarReadings`)
- Modify: `AIUsage/Models/ProviderModels.swift` (`ProviderSnapshot`)
- Modify: `AIUsage/Views/MenuBarLabelView.swift` (`MenuBarPresentation`, `MenuBarMetricPresentation`, `MenuBarProviderLabelView`)
- Test: `AIUsageTests/MenuBarPresentationTests.swift`, `AIUsageTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `projectedExhaustion(measuredAt:)`.
- Produces:
  - `func ProviderSnapshot.isAtRisk(_ metric: MenuBarMetricID) -> Bool`, which is true when `window(for: metric)?.projectedExhaustion(measuredAt: fetchedAt) != nil`.
  - `MenuBarReading.isAtRisk: Bool`, an init parameter with default `false` so existing tests compile.
  - `MenuBarPresentation.showsRiskIndicator` and `MenuBarMetricPresentation.showsRiskIndicator: Bool`.

- [ ] **Step 1: Write the failing tests.**
  - `testAtRiskPercentageAddsRiskToAccessibility` (MenuBarPresentationTests): Claude session at 40% with `isAtRisk: true` → `showsRiskIndicator`, and `accessibilityLabel` ends with `", runs out before reset at this pace"`. When the reading is also stale, both suffixes appear, in the order `..., stale, runs out before reset at this pace`.
  - `testMenuBarReadingCarriesRiskFromSnapshot` (UsageStoreTests): a snapshot whose session window is Task 1's U=40 case → `menuBarReading(for:)?.isAtRisk == true`. With U=10 → `false`.

- [ ] **Step 2: Run the tests and confirm they fail.**

- [ ] **Step 3: Implement.** `menuBarReadings` passes `state.snapshot?.isAtRisk(item.metric) ?? false`. `MenuBarProviderLabelView` draws `Image(systemName: "exclamationmark.triangle.fill")` at `microFontSize` after the value when `showsRiskIndicator` is set and `showsStaleIndicator` is not. Stale wins visually, because stale data makes the projection itself doubtful. The accessibility label still says both.

- [ ] **Step 4: Run the tests and confirm they pass.** Then run the full suite, including the width bound in `testMenuBarLabelKeepsUsageMeaningOutOfVisibleText`.

- [ ] **Step 5: Commit** `Mark menu bar readings that run out before their reset`.

---

### Task 6: Product docs

**Files:**
- Modify: `PRODUCT.md` (Capabilities and Constraints)
- Modify: `README.md` (feature bullets near line 104)

- [ ] **Step 1: Edit `PRODUCT.md`.** Add one capability line: "Windows with a known start show when they will run out at their average pace since the window started, only when that comes before the reset. The projection is computed from the current reading alone; no usage history is kept." The "no usage history" lines stay unchanged.

- [ ] **Step 2: Edit `README.md`.** Add one bullet next to the banked-resets bullet with the same content in user terms.

- [ ] **Step 3: Run the full suite** (`ReadmeShowcaseTests` reads the README). Expected: PASS.

- [ ] **Step 4: Commit** `Document the usage pace forecast`.

Skipped: notifications, a setting to turn the forecast off, and new README screenshots. Add them when someone asks.
