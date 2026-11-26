# Pace-Aware Risk Signals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing pace forecast into graded, confidence-weighted signals (zones with hysteresis, pace-muted level colours, a cooling date) and show Claude's own severity as information only.

**Architecture:** A pure `PaceReading` (new file) turns a `QuotaWindow` at its reading time into a zone, a colour weight and a cooling date. `UsageStore` owns the work schedule and stores each window's `PaceReading` on the window when a snapshot arrives, seeded by the previous zone of the same window, so tile, menu bar and tooltip read one value. Risk becomes "zone ahead or far ahead"; the exhaustion time and daily budget stay as they are.

**Tech Stack:** Swift, SwiftUI/AppKit (macOS 26 target, so `Color.mix(with:by:)` is available), XCTest. No new dependencies. The Xcode project uses synchronized folders: new files under `AIUsage/` and `AIUsageTests/` are picked up without editing the project.

**Spec:** `docs/superpowers/specs/2026-11-26-pace-aware-risk-design.md` (issue mg-i-ant-mor/ai-usage-menubar#22).

## Global Constraints

- Constants, together as `static let` on `PaceReading`: `confidenceRate = 8` (k), `margin = 5` (m, percentage points), `hysteresis = 5` (h). No settings UI.
- `confidence = 1 − e^(−k·elapsed)`; `weighted = (used% − elapsed%) × confidence`, where elapsed% is `QuotaWindow.onPacePercent(now:schedule:calendar:)`.
- Zones: on track `weighted ≤ m`, ahead `m < weighted ≤ 2m`, far ahead `weighted > 2m`. Falling: far ahead is held while `weighted > 2m − h`, ahead (from ahead or far ahead) while `weighted > m − h`. No "chill" zone.
- Colour weight `f = smoothstep(0.7, 1.0, used / elapsed)`, `f = 1` when elapsed is 0 or there is no pace reading. Not confidence-weighted.
- At risk = zone ≥ ahead **and** `usedPercent < 100` **and** `now < resetsAt`.
- Level colours: `warning` from 60%, `critical` from 85%, mixed from the base by `f`; 100% is `critical` regardless of `f`.
- Tooltip icons, in order: 🔴 at 100% or from 85% with `f ≥ 0.5`; ⏳ when at risk; 🟠 from 60% with `f ≥ 0.5`; 🟢 otherwise.
- Copy (exact): `Back on pace by <time> if you pause`; `Claude: high usage`. Existing copy (`Full by <time> at this pace`, `Resets <time>`, `Not updated`, `Full <countdown>`, `Reset <countdown>`) is unchanged.
- Severity never drives risk, zones, ⏳ or colours.
- Applies to every provider with a start and a reset.
- Test command: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`; one class with `-only-testing:AIUsageTests/<Class>`.
- Branch from `develop` (the fork's `develop`, already contained in this branch); PR to `develop` on `mg-i-ant-mor/ai-usage-menubar`. No Claude attribution in commits, PR or issues.

## Review Focus

- **Reading from before the reset, looked at after it.** Expect no ⏳, no "Full …", no cooling date. Pinned by `testSnapshotRiskEndsOnceResetHasPassed`, updated in Task 3.
- **A full window whose zone is far ahead.** Expect red, the plain reset line, no ⏳. Pinned by `testFullWindowIsNotAtRisk` (Task 3).
- **Windows without a start or reset** (Sonnet with `resets_at: null`, providers without `startsAt`). Expect no pace reading, an unmuted level colour, no tick, no ⏳. Pinned by `testNoPaceWithoutStartOrReset` (Task 1) and `testWindowWithoutStartKeepsFullLevelColour` (Task 4).
- **A second account's windows.** Expect their own pace, seeded from that account's previous zone, not the default login's. Pinned by `testOtherAccountsGetTheirOwnPace` (Task 2).
- **Changing the work schedule between refreshes.** Expect zones and risk to follow at once, without a refetch. Pinned by `testScheduleChangeRecomputesPaceWithoutRefetching` (Task 2).

---

### Task 1: `PaceReading` maths, and no 10% gate

**Files:**
- Create: `AIUsage/Models/PaceReading.swift`
- Modify: `AIUsage/Models/ProviderModels.swift` (`QuotaWindow`, ~lines 367-404: delete `minimumElapsedFraction` and both guards that use it in `projectedExhaustion`)
- Create: `AIUsageTests/PaceReadingTests.swift`
- Modify: `AIUsageTests/PaceForecastTests.swift` (`testNoProjectionBeforeTenPercentElapsed`)

**Interfaces:**
- Produces:
  ```swift
  struct PaceReading: Equatable, Sendable {
      enum Zone: Int, Comparable, Sendable { case onTrack, ahead, farAhead }
      static let confidenceRate = 8.0
      static let margin = 5.0
      static let hysteresis = 5.0
      let zone: Zone
      let levelWeight: Double   // f
      let coolsAt: Date?        // nil unless used% > elapsed%
      init?(window: QuotaWindow, at date: Date, previous: Zone?,
            schedule: WorkSchedule?, calendar: Calendar = .current)
      static func confidence(elapsed: Double) -> Double   // elapsed is a 0…1 fraction
      static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double
  }
  ```
  `init?` returns nil when `window.onPacePercent(now: date, schedule:, calendar:)` is nil, i.e. no start or reset, or `date` outside the window.

- [ ] **Step 1: Write the failing tests** in `PaceReadingTests`. Use `t0 = Date(timeIntervalSince1970: 1_800_000_000)`, `hour = 3_600`, a session from `t0` to `t0 + 5 h`, and a helper `pace(_ used: Double, at hours: Double, previous: PaceReading.Zone? = nil) -> PaceReading?`.

```swift
func testConfidenceGrowsFromZero() {
    XCTAssertEqual(PaceReading.confidence(elapsed: 0), 0)
    XCTAssertEqual(PaceReading.confidence(elapsed: 0.1), 0.5507, accuracy: 0.0001)
    XCTAssertEqual(PaceReading.confidence(elapsed: 1), 0.9997, accuracy: 0.0001)
}

func testZoneFromWeightedDelta() {          // at 1 h: elapsed 20%, confidence 0.798
    XCTAssertEqual(pace(26, at: 1)?.zone, .onTrack)   // weighted 4.79
    XCTAssertEqual(pace(27, at: 1)?.zone, .ahead)     // 5.59
    XCTAssertEqual(pace(32, at: 1)?.zone, .ahead)     // 9.58
    XCTAssertEqual(pace(33, at: 1)?.zone, .farAhead)  // 10.38
}

func testZoneHysteresisOnTheWayDown() {
    XCTAssertEqual(pace(27, at: 1, previous: .farAhead)?.zone, .farAhead)
    XCTAssertEqual(pace(26, at: 1, previous: .farAhead)?.zone, .ahead)
    XCTAssertEqual(pace(21, at: 1, previous: .ahead)?.zone, .ahead)     // 0.80
    XCTAssertEqual(pace(20, at: 1, previous: .ahead)?.zone, .onTrack)   // 0
    XCTAssertEqual(pace(26, at: 1, previous: .onTrack)?.zone, .onTrack)
    XCTAssertEqual(pace(27, at: 1, previous: .onTrack)?.zone, .ahead)
}

func testSignalStartsWithoutTheTenPercentGate() {
    XCTAssertEqual(pace(30, at: 0.25)?.zone, .ahead)  // 5% elapsed, weighted 8.24
}

func testLevelWeightFollowsPace() {         // at 2.5 h: elapsed 50%
    XCTAssertEqual(pace(35, at: 2.5)!.levelWeight, 0, accuracy: 0.0001)
    XCTAssertEqual(pace(40, at: 2.5)!.levelWeight, 0.2593, accuracy: 0.001)
    XCTAssertEqual(pace(50, at: 2.5)!.levelWeight, 1, accuracy: 0.0001)
}

func testCoolingDateInCalendarTime() {
    XCTAssertEqual(pace(30, at: 1)?.coolsAt, t0.addingTimeInterval(1.5 * hour))
    XCTAssertNil(pace(20, at: 1)?.coolsAt)
}

func testCoolingDateInWorkingTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let weekly = QuotaWindow(
        kind: .weekly, usedPercent: 30,
        resetsAt: ProviderParsing.date("2027-01-25T08:00:00Z"),
        startsAt: ProviderParsing.date("2027-01-18T08:00:00Z")
    )
    // Tue 09:00: 9 of 45 working hours gone (20%); 10 points = 4.5 working hours.
    let reading = PaceReading(window: weekly, at: ProviderParsing.date("2027-01-19T09:00:00Z")!,
                              previous: nil, schedule: .standard, calendar: calendar)
    XCTAssertEqual(reading?.zone, .ahead)
    XCTAssertEqual(reading?.coolsAt, ProviderParsing.date("2027-01-19T13:30:00Z"))
}

func testNoPaceWithoutStartOrReset() {
    // session without startsAt, session without resetsAt, and the normal session at t0 + 5 h + 600 s
    // all give nil
}
```

In `PaceForecastTests`, replace `testNoProjectionBeforeTenPercentElapsed` with:

```swift
func testProjectsFromTheStartOfTheWindow() {
    XCTAssertEqual(session(used: 30).projectedExhaustion(measuredAt: t0.addingTimeInterval(20 * 60)),
                   t0.addingTimeInterval(4_000))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' -only-testing:AIUsageTests/PaceReadingTests -only-testing:AIUsageTests/PaceForecastTests`
Expected: build failure, `cannot find 'PaceReading' in scope`.

- [ ] **Step 3: Implement `PaceReading`** in `AIUsage/Models/PaceReading.swift`. The rules are in Global Constraints. The zone and cooling rules need these bodies:

```swift
let m = Self.margin, h = Self.hysteresis
if weighted > 2 * m || (previous == .farAhead && weighted > 2 * m - h) { zone = .farAhead }
else if weighted > m || ((previous ?? .onTrack) >= .ahead && weighted > m - h) { zone = .ahead }
else { zone = .onTrack }
```

Cooling, when `delta > 0`. A window longer than a day with a schedule uses `needed = delta / 100 × schedule.workingTime(from: start, to: reset)` and `schedule.date(byAddingWorkingTime: needed, to: date, calendar:) ?? reset`. Any other window uses `date + delta / 100 × reset.timeIntervalSince(start)`. Both are capped with `min(…, reset)`. This is the same `> 86_400` rule `onPacePercent` uses.

- [ ] **Step 4: Remove the gate.** Delete `QuotaWindow.minimumElapsedFraction` and its two uses in `projectedExhaustion`. Keep the `elapsed > 0` guard in the working-time branch.

- [ ] **Step 5: Run the tests to verify they pass**

Run: the command from Step 2.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add AIUsage/Models/PaceReading.swift AIUsage/Models/ProviderModels.swift AIUsageTests/PaceReadingTests.swift AIUsageTests/PaceForecastTests.swift
git commit -m "Add confidence-weighted pace zones and drop the 10% forecast gate"
```

### Task 2: The store holds each window's pace and the work schedule

**Files:**
- Modify: `AIUsage/Models/ProviderModels.swift` (`QuotaWindow`, `ProviderSnapshot.windows` becomes `var`)
- Modify: `AIUsage/Models/PaceReading.swift` (extensions)
- Modify: `AIUsage/Store/UsageStore.swift` (init, `applyFetchResults`, reading functions ~lines 256-371)
- Modify: `AIUsage/MenuBar/MenuBarController.swift` (`trackMenuBarState`, ~lines 476-509)
- Test: `AIUsageTests/UsageStoreTests.swift`, plus every caller of the removed `workSchedule:` arguments (`grep -rn "workSchedule:" AIUsage AIUsageTests`)

**Interfaces:**
- Consumes: `PaceReading` (Task 1).
- Produces:
  - `QuotaWindow.pace: PaceReading?`, a `var` defaulting to `nil`, declared after `startsAt`.
  - `QuotaWindow.withPace(at: Date, previous: PaceReading.Zone?, schedule: WorkSchedule?, calendar: Calendar = .current) -> QuotaWindow`.
  - `ProviderSnapshot.paced(previous: ProviderSnapshot?, schedule: WorkSchedule?, calendar: Calendar = .current) -> ProviderSnapshot`. Each window is paced at `fetchedAt`. Its previous zone comes from `previous`'s window of the same `kind`. Each `otherAccounts[i].snapshot` is paced against `previous?.otherAccounts` with the same `id`.
  - `UsageStore.workSchedule: WorkSchedule?` (`private(set)`), an init parameter `workSchedule: WorkSchedule? = nil`, and `func setWorkSchedule(_ schedule: WorkSchedule?)`. When the schedule changes, it re-paces every state's snapshot with `previous:` set to that same snapshot.
  - `menuBarReadings(for:displayMode:)`, `menuBarProviderReadings(for:displayMode:)` and `menuBarReading(for:displayMode:)` lose their `workSchedule:` parameter and use `self.workSchedule`.

- [ ] **Step 1: Write the failing tests** in `UsageStoreTests`. Use `SequencedProvider` and `FixedProviderAvailabilityChecker` as `testMenuBarReadingCarriesRiskFromSnapshot` does: a session from `t0` to `t0 + 5 h`, and `zone(_ store:) = store.states[.claude]?.snapshot?.windows.first?.pace?.zone`.

```swift
func testStoreHoldsTheZoneAcrossRefreshes() async {
    // results: [30% fetched at t0 + 1 h, 43% fetched at t0 + 2 h]
    await store.refresh(); XCTAssertEqual(zone(store), .ahead)
    await store.refresh(); XCTAssertEqual(zone(store), .ahead)     // weighted 2.88, held
    // a fresh store whose only result is the 43% snapshot
    await fresh.refresh(); XCTAssertEqual(zone(fresh), .onTrack)
}

func testScheduleChangeRecomputesPaceWithoutRefetching() async {
    // the weekly 85% Saturday snapshot from testMenuBarReadingsFollowTheWorkSchedule, one result only
    await store.refresh()
    XCTAssertEqual(zone(store), .farAhead)
    store.setWorkSchedule(.standard)
    XCTAssertEqual(zone(store), .onTrack)
}

func testOtherAccountsGetTheirOwnPace() async {
    // primary: session 10% at t0 + 1 h; otherAccounts: [ProviderAccount(id: "work", name: "Work",
    // snapshot: session 30% at t0 + 1 h)]
    XCTAssertEqual(zone(store), .onTrack)
    XCTAssertEqual(store.states[.claude]?.snapshot?.otherAccounts.first?.snapshot?
        .windows.first?.pace?.zone, .ahead)
}
```

Update `testMenuBarReadingsFollowTheWorkSchedule`: replace the `workSchedule: .standard` arguments with `store.setWorkSchedule(.standard)` before the second pair of assertions. The expected values stay the same.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' -only-testing:AIUsageTests/UsageStoreTests`
Expected: build failure, `value of type 'QuotaWindow' has no member 'pace'` / `no member 'setWorkSchedule'`.

- [ ] **Step 3: Implement** the Interfaces above.
  - `applyFetchResults` stores `snapshot.paced(previous: state.snapshot, schedule: workSchedule)` on success.
  - The reading functions keep computing `isAtRisk` / `exhaustsAt` as today, but with `self.workSchedule`. Risk moves to the zone in Task 3.
  - In `MenuBarController.trackMenuBarState`, call `store.setWorkSchedule(preferences.activeWorkSchedule)` right after `store.setTrackedProviders(...)` at the top. Add `workSchedule: preferences.activeWorkSchedule` to the observed tuple, so a schedule change still re-runs the tracking.
  - Update the other callers that `grep` finds.

- [ ] **Step 4: Run the whole suite to verify it passes**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add AIUsage AIUsageTests
git commit -m "Keep each window's pace zone in the store across refreshes"
```

### Task 3: Risk follows the zone; tick and ⏳ take the zone colour

**Files:**
- Modify: `AIUsage/Models/PaceReading.swift` (or `ProviderModels.swift`): `QuotaWindow.isAtRisk`
- Modify: `AIUsage/Models/ProviderModels.swift` (`ProviderSnapshot.isAtRisk`, `exhaustion`, ~lines 567-583)
- Modify: `AIUsage/Store/UsageStore.swift` (`readings(for:in:displayMode:)`)
- Modify: `AIUsage/Views/ProviderSectionView.swift` (`QuotaTimingPresentation.init` ~line 258, `QuotaTile` tick ~line 489 and hourglass ~line 503)
- Modify: `AIUsage/Views/UsagePalette.swift`
- Test: `AIUsageTests/PaceForecastTests.swift`

**Interfaces:**
- Consumes: `QuotaWindow.pace`, `withPace`, `ProviderSnapshot.paced` (Task 2).
- Produces:
  - `QuotaWindow.isAtRisk(now: Date) -> Bool`, the at-risk rule from Global Constraints.
  - `ProviderSnapshot.isAtRisk(_ metric: MenuBarMetricID, now: Date) -> Bool` drops its `schedule:` parameter.
  - `exhaustion(for:now:schedule:)` keeps its signature and returns `nil` unless `isAtRisk`.
  - `QuotaTimingPresentation.zone: PaceReading.Zone?`: the window's zone when at risk, else `nil`. Its risk branch needs both `window.isAtRisk(now:)` and a non-nil `projectedExhaustion`.
  - `UsagePalette.zoneTint(_ zone: PaceReading.Zone?) -> Color`: `.farAhead` gives `critical`, `.ahead` gives `warning`, `.onTrack` and `nil` give `normalUsage`.
  - `MenuBarReading.isAtRisk` comes from `snapshot.isAtRisk`, and `exhaustsAt` from `snapshot.exhaustion(...)`.

- [ ] **Step 1: Update the existing tests and write the failing ones** in `PaceForecastTests`.
  - Existing tests that build windows or snapshots by hand and expect risk now pace them first. Use `.withPace(at: measuredAt, previous: nil, schedule: <same schedule as the assertion>)`, or `snapshot.paced(previous: nil, schedule:)`. That covers `testAtRiskTimingShowsFullBeforeReset`, `testPastProjectionReadsFullSoon`, `testTimingDropsForecastOnceResetHasPassed`, `testSnapshotRiskEndsOnceResetHasPassed` and `testTimingFollowsTheWorkSchedule`. The last one paces once without a schedule and once with `.standard`. Their expected values do not change.
  - New tests (`m70 = t0.addingTimeInterval(70 * 60)`):

```swift
func testOnTrackWindowIsNotAtRiskEvenWithAForecast() {
    let window = session(used: 24).withPace(at: t0.addingTimeInterval(hour), previous: nil, schedule: nil)
    XCTAssertNotNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(hour)))
    let p = QuotaTimingPresentation(window: window, measuredAt: t0.addingTimeInterval(hour), now: m70)
    XCTAssertFalse(p.isAtRisk)
    XCTAssertEqual(p.text, "Reset 3h 50m")
    XCTAssertNil(p.zone)
}

func testFullWindowIsNotAtRisk() {
    let window = session(used: 100).withPace(at: t0.addingTimeInterval(hour), previous: nil, schedule: nil)
    XCTAssertEqual(window.pace?.zone, .farAhead)
    XCTAssertFalse(window.isAtRisk(now: m70))
    XCTAssertFalse(QuotaTimingPresentation(window: window, measuredAt: t0.addingTimeInterval(hour), now: m70).isAtRisk)
}

func testTimingCarriesTheZoneForTheHourglass() {
    // used 27 at 1 h → .ahead; used 40 at 1 h → .farAhead (QuotaTimingPresentation.zone)
}

func testZoneTint() {
    XCTAssertEqual(UsagePalette.zoneTint(.farAhead), UsagePalette.critical)
    XCTAssertEqual(UsagePalette.zoneTint(.ahead), UsagePalette.warning)
    XCTAssertEqual(UsagePalette.zoneTint(.onTrack), UsagePalette.normalUsage)
    XCTAssertEqual(UsagePalette.zoneTint(nil), UsagePalette.normalUsage)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' -only-testing:AIUsageTests/PaceForecastTests`
Expected: build failure (no `isAtRisk(now:)`, `zone`, `zoneTint`).

- [ ] **Step 3: Implement** the Interfaces.
  - In `QuotaTile`, the pace tick fills with `UsagePalette.zoneTint(window.pace?.zone)`. The hourglass uses `UsagePalette.zoneTint(timing.zone)` in place of `UsagePalette.warning`.
  - The bar fill and the number keep `progressTint` / `valueTint` for now; Task 4 changes them.

- [ ] **Step 4: Run the whole suite to verify it passes**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`. `testMenuBarReadingCarriesRiskFromSnapshot` still passes unchanged: 40% at 1 h is far ahead, 10% is on track.

- [ ] **Step 5: Commit**

```bash
git add AIUsage AIUsageTests
git commit -m "Mark risk from the pace zone and colour the tick and hourglass by zone"
```

### Task 4: Pace-aware level colours

**Files:**
- Modify: `AIUsage/Views/UsagePalette.swift`
- Modify: `AIUsage/Views/ProviderSectionView.swift` (`QuotaTile.valueTint` / `progressTint`, ~lines 537-552)
- Modify: `AIUsage/Store/UsageStore.swift` (`MenuBarReading`, readings)
- Modify: `AIUsage/Views/MenuBarLabelView.swift` (`MenuBarTooltip.lines`, icon ~line 94)
- Test: `AIUsageTests/PaceForecastTests.swift`, `AIUsageTests/MenuBarPresentationTests.swift`, `AIUsageTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `QuotaWindow.pace` (Task 2).
- Produces:
  - `UsagePalette.levelTint(usedPercent: Double, weight: Double, base: Color) -> Color`. At 100% and above it returns `critical`. From 85% it returns `base.mix(with: critical, by: weight)`, from 60% `base.mix(with: warning, by: weight)`. Below 60% it returns `base` unchanged.
  - `MenuBarReading.levelWeight: Double`, an init parameter defaulting to `1`. The store sets it from `window.pace?.levelWeight ?? 1`.

- [ ] **Step 1: Write the failing tests.** Compare colours with `resolve(in: EnvironmentValues())`, components to an accuracy of 0.01.

```swift
// PaceForecastTests
func testLevelTintMutesOnACalmPace() {
    XCTAssertEqual(UsagePalette.levelTint(usedPercent: 50, weight: 1, base: UsagePalette.normalUsage), UsagePalette.normalUsage)
    XCTAssertEqual(UsagePalette.levelTint(usedPercent: 100, weight: 0, base: UsagePalette.normalUsage), UsagePalette.critical)
    // resolved: (90, weight 1) ≈ critical; (70, weight 1) ≈ warning; (70, weight 0) ≈ normalUsage
}

// MenuBarPresentationTests — four used-mode readings, no resetsAt, en_GB, UTC
func testTooltipMutesLevelIconsOnACalmPace() {
    // session 76% weight 0.4, weekly 76% weight 0.6, sonnet 90% weight 0.4, fable 100% weight 0
    XCTAssertEqual(text, """
    Claude Code
    🟢 Session — 76% used
    🟠 Weekly — 76% used
    🟢 Sonnet — 90% used
    🔴 Fable — 100% used
    """)
}

// UsageStoreTests
// in testMenuBarReadingCarriesRiskFromSnapshot: fast (40% at 1 h) levelWeight == 1, slow (10%) == 0
func testWindowWithoutStartKeepsFullLevelColour() async {
    // .sonnet 76%, resetsAt nil, no startsAt
    XCTAssertNil(store.states[.claude]?.snapshot?.windows.first?.pace)
    XCTAssertEqual(store.menuBarReading(for: MenuBarItemID(provider: .claude, metric: .sonnet))?.levelWeight, 1)
}
```

Use the `MenuBarMetricID` cases that exist for these titles; check `MenuBarMetricID.title` for the exact strings.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' -only-testing:AIUsageTests/PaceForecastTests -only-testing:AIUsageTests/MenuBarPresentationTests -only-testing:AIUsageTests/UsageStoreTests`
Expected: build failure (no `levelTint`, no `levelWeight`).

- [ ] **Step 3: Implement.**
  - `QuotaTile.progressTint` becomes `levelTint(usedPercent: window.usedPercent, weight: window.pace?.levelWeight ?? 1, base: UsagePalette.normalUsage)`.
  - `valueTint` is the same with `base: Color(nsColor: .labelColor)`.
  - The tooltip icon follows Global Constraints, reading `reading.levelWeight`. Keep the existing comment about matching the dashboard, updated.

- [ ] **Step 4: Run the whole suite to verify it passes**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add AIUsage AIUsageTests
git commit -m "Mute usage-level colours when the pace is calm"
```

### Task 5: Cooling date in the tooltip; stale readings keep their forecast

**Files:**
- Modify: `AIUsage/Store/UsageStore.swift` (`MenuBarReading`, readings)
- Modify: `AIUsage/Views/MenuBarLabelView.swift` (`MenuBarTooltip.lines`, details ~lines 112-120)
- Test: `AIUsageTests/MenuBarPresentationTests.swift`, `AIUsageTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `PaceReading.coolsAt` (Task 1), `snapshot.isAtRisk` (Task 3).
- Produces: `MenuBarReading.coolsAt: Date?`, an init parameter defaulting to `nil`. The store sets it from `window.pace?.coolsAt`, only when the reading is at risk.

- [ ] **Step 1: Write the failing tests.**
  - In `testTooltipListsEachLimitWithItsTimesAndStatus`, give the session reading `coolsAt: t0.addingTimeInterval(2 * 3_600)`. Its detail line becomes `      Full by 09:20 at this pace · Back on pace by 10:00 if you pause · Resets 11:00`.
  - Add `testStaleReadingStillShowsItsForecast`. It uses one Claude session reading with `isStale: true`, `isAtRisk: true`, `exhaustsAt: t0 + 80 min`, `coolsAt: t0 + 2 h` and `resetsAt: t0 + 3 h`, and expects:
    ```
    Claude Code
    ⚠️ Session — 66% used
          Not updated · Full by 09:20 at this pace · Back on pace by 10:00 if you pause · Resets 11:00
    ```
  - In `testMenuBarReadingCarriesRiskFromSnapshot`, add two assertions: `fast` (40% at 1 h) has `coolsAt == t0.addingTimeInterval(2 * 3_600)`, and `slow` has `coolsAt == nil`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' -only-testing:AIUsageTests/MenuBarPresentationTests -only-testing:AIUsageTests/UsageStoreTests`
Expected: FAIL. `coolsAt` does not exist yet, and the stale line reads `Not updated · Resets 11:00`.

- [ ] **Step 3: Implement.** The details are built in this order, each part only when present: `Not updated` (stale), `Full by <time> at this pace` (`exhaustsAt`), `Back on pace by <time> if you pause` (`coolsAt`), `Resets <time>` (reset still ahead). They are joined with ` · `, using the existing `time(_:now:calendar:locale:)`.

- [ ] **Step 4: Run the whole suite to verify it passes**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add AIUsage AIUsageTests
git commit -m "Show when a window is back on pace, and keep the forecast on stale readings"
```

### Task 6: Claude's severity, as information only

**Files:**
- Modify: `AIUsage/Models/ProviderModels.swift` (`QuotaWindow`)
- Modify: `AIUsage/Providers/Claude/ClaudeUsageMapper.swift` (`map`, ~line 74)
- Modify: `AIUsage/Store/UsageStore.swift` (`MenuBarReading`, readings)
- Modify: `AIUsage/Views/MenuBarLabelView.swift` (`MenuBarTooltip.lines`)
- Modify: `AIUsage/Views/ProviderSectionView.swift` (`QuotaTile` title row and `accessibilityValue`)
- Modify: `docs/provider-contracts.md` (Claude "Mapped fields", ~line 48)
- Test: `AIUsageTests/MapperTests.swift`, `AIUsageTests/MenuBarPresentationTests.swift`, `AIUsageTests/PaceForecastTests.swift`, `AIUsageTests/VisualSnapshotTests.swift`

**Interfaces:**
- Produces:
  - `QuotaWindow.providerHighUsage: Bool`, a `var` defaulting to `false`, declared after `pace`. Doc comment: "Claude's own `limits[].severity` flags this window, as of the reading. Information only: never drives risk, zones or colours."
  - `MenuBarReading.providerHighUsage: Bool`, an init parameter defaulting to `false`, set from the window.

- [ ] **Step 1: Write the failing tests.**
  - `MapperTests`: carry over `testClaudeReadsServerSeverity` and `testClaudeWithoutSeverityHasNoWarning` as written in the deleted #21 plan, asserting `providerHighUsage`:

```swift
func testClaudeReadsServerSeverity() throws {
    // five_hour / seven_day / seven_day_sonnet at 10%; limits rows: session "normal",
    // weekly_all "warning", weekly_scoped Sonnet "normal", weekly_scoped Fable "critical"
    // (percent 10, resets_at 1800518400). Map as testClaudeMapsAllSupportedWindowsAndPlan does.
    XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .sonnet, .fable])
    XCTAssertEqual(snapshot.windows.map(\.providerHighUsage), [false, true, false, true])
}

func testClaudeWithoutSeverityHasNoWarning() throws {
    // five_hour 10% and seven_day 10%; limits: session row without severity, weekly_all with
    // "severity": 3, an unknown "kind": "daily" row with "warning". Also a body with no "limits".
    XCTAssertEqual(snapshot.windows.map(\.providerHighUsage), [false, false])
}
```

  - `PaceForecastTests`, `testHighUsageNeverChangesRisk`: session 10% with `providerHighUsage = true`, paced at 1 h. `isAtRisk(now: m70)` is false, and the zone is `.onTrack`.
  - `MenuBarPresentationTests`, `testTooltipShowsClaudeHighUsage`: a weekly reading at 76% used, `providerHighUsage: true`, `resetsAt: t0 + 4 days`. It expects:
    ```
    Claude Code
    🟠 Weekly — 76% used
          Resets Tue 08:00
          Claude: high usage
    ```
  - `VisualSnapshotTests.testAtRiskTileStaysCompact`: set `providerHighUsage = true` on the Sonnet window. The size assertions are unchanged.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' -only-testing:AIUsageTests/MapperTests -only-testing:AIUsageTests/MenuBarPresentationTests -only-testing:AIUsageTests/PaceForecastTests`
Expected: build failure, `no member 'providerHighUsage'`.

- [ ] **Step 3: Implement.**
  - **Mapper.** Add `private static func highUsageKinds(_ limits: Any?) -> Set<QuotaKind>`, and set the flag on `windows` after they are built. Rows map to windows as follows:
    - `kind == "session"` → `.session`
    - `"weekly_all"` → `.weekly`
    - `"weekly_scoped"` with `scope.model.display_name` lowercased starting with `"sonnet"` / `"fable"` → `.sonnet` / `.fable`

    A row counts when `severity` is a string other than `"normal"`.
  - **Tooltip.** Add an extra line `      Claude: high usage` after the window's detail line, or right after its title line when there is no detail line.
  - **Tile.** After the title `Text`, show `Image(systemName: "exclamationmark.circle")` in `.secondary`, `.font(.caption2)`, with `.help("Claude: high usage")`. Append `Claude: high usage` to `accessibilityValue`.
  - **Docs.** In `docs/provider-contracts.md`, add a short paragraph under Claude's Mapped fields covering `limits[].severity`, the row → window mapping, and that it is information only. Note that `pace` and `indicator` are present but not read.

- [ ] **Step 4: Run the whole suite to verify it passes**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add AIUsage AIUsageTests docs/provider-contracts.md
git commit -m "Show Claude's own high-usage flag as information"
```

### Task 7: Product docs and README

**Files:**
- Modify: `PRODUCT.md` (~lines 62-80)
- Modify: `README.md` (~lines 47-51 and 112-125)
- Check: `AIUsageTests/ReadmeShowcaseTests.swift`

- [ ] **Step 1: Update the prose** to match the spec:
  - The pace is still the average since the window started, now confidence-weighted from the first minute, with no 10% wait.
  - The ⏳ and "Full …" appear from 5 points ahead of pace, with a 5-point hysteresis. The zone is remembered between refreshes while the app runs. Remove "nothing is stored between refreshes".
  - The on-pace mark takes the zone colour (orange ahead, red far ahead), no longer the bar's colour.
  - Orange/red level colours fade when the pace is calm, and 100% is always red.
  - The tooltip adds "Back on pace by … if you pause". A stale reading keeps its forecast after "Not updated".
  - Claude's own high-usage flag is shown as information.

  Keep each file's existing tone and line wrapping.
- [ ] **Step 2: Check the showcase still builds and keeps its at-risk hero.** The hero's Claude session (78% used, 1 h 52 m left of 5 h) is far ahead, so it keeps a red ⏳. No fixture change is expected.

Run: `xcodebuild build-for-testing -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`
Expected: `** TEST BUILD SUCCEEDED **`.

Do not re-render `docs/images/`. That needs Screen Recording and a screen, so the PR asks the user to run `scripts/render_readme_images.sh`.

- [ ] **Step 3: Commit**

```bash
git add PRODUCT.md README.md
git commit -m "Describe the pace-aware signals in the product docs and README"
```
