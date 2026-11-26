# Claude Native Usage Warnings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mark a Claude window "at risk" when Anthropic's own `severity` or Claude Code's early-warning thresholds say so, alongside the local forecast.

**Architecture:** `ClaudeUsageMapper` computes one `providerWarning: Bool` per `QuotaWindow` at read time, from the `limits[].severity` field and Claude Code's fixed thresholds. The existing risk path (`ProviderSnapshot.isAtRisk`, `QuotaTimingPresentation`, menu bar reading and tooltip) ORs that flag with the local `projectedExhaustion`. When only the flag fires there is no exhaustion time, so the copy reads "Ahead of pace".

**Tech Stack:** Swift, SwiftUI/AppKit, XCTest. No new dependencies.

**Spec:** GitHub issue mg-i-ant-mor/ai-usage-menubar#21 (https://github.com/mg-i-ant-mor/ai-usage-menubar/issues/21)

## Global Constraints

- Base branch `develop`, the PR targets `develop` on `mg-i-ant-mor/ai-usage-menubar`.
- Thresholds are Claude Code 2.1.332's, in calendar time (no work schedule): Session ≥ 90% while elapsed ≤ 72%. Weekly ≥ 75% while elapsed ≤ 60%, ≥ 50% while elapsed ≤ 35%, ≥ 25% while elapsed ≤ 15%. Elapsed = `(now − (resets_at − length)) / length`, clamped to 0…1. Session length 5 h, weekly length 7 d.
- Thresholds apply only to Session (`five_hour`) and Weekly (`seven_day`). Severity applies to every window it matches.
- Severity: a row counts as a warning when `severity` is a string other than `"normal"`. A missing or non-string `severity` is no warning.
- Row → window: `kind == "session"` → Session. `kind == "weekly_all"` → Weekly. `kind == "weekly_scoped"` with `scope.model.display_name` starting with "fable" (case-insensitive) → Fable, starting with "sonnet" → Sonnet.
- Copy: tile `Ahead of pace · <reset>`, compact `Ahead of pace`, VoiceOver `ahead of pace, <budget><reset>`. Tooltip detail `Ahead of pace`. Menu bar accessibility suffix `, ahead of pace`.
- When the local forecast also has an exhaustion time, the existing "Full …" copy wins.
- Pace tick (the vertical mark on the tile's bar at `onPacePercent`): its position is unchanged. Its colour follows the risk: critical from 85% used, warning from 60%, and below 60% warning when the tile is at risk, otherwise normal. Today below 60% it is always normal (teal), even next to the orange hourglass.
- Other providers never set `providerWarning`. `pace` and `indicator` fields are not read.
- Test command: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'` (add `-only-testing:AIUsageTests/<Class>/<method>` for one test).
- No Claude attribution in commits or the PR body (user rule).

## Review Focus

- **Older responses without `limits` or without `severity`.** Expect no warning and no crash. Pinned by `testClaudeWithoutSeverityHasNoWarning` (Task 1).
- **Window with no `resets_at`.** Thresholds cannot place the window in time, so expect no threshold warning. Severity still applies. Pinned by `testClaudeEarlyWarningNeedsAReset` (Task 1).
- **Reading taken before the reset, looked at after it.** The flag is stale once the reset passes, so expect no risk. Pinned by `testProviderWarningEndsOnceResetHasPassed` (Task 2).
- **Unknown severity values** (`"critical"`, `"exhausted"`). Expect a warning, not silence. Pinned by the `"critical"` Fable row in `testClaudeReadsServerSeverity` (Task 1).
- **Stale data with a warning.** The menu bar already shows stale over risk (`MenuBarController.swift:75`). No change and no new test: the existing stale tests cover it.

---

### Task 1: Claude mapper sets `providerWarning`

**Files:**
- Modify: `AIUsage/Models/ProviderModels.swift` (`struct QuotaWindow`, ~line 361)
- Modify: `AIUsage/Providers/Claude/ClaudeUsageMapper.swift` (`map`, `appendWindow`, `appendFable`)
- Modify: `docs/provider-contracts.md` (Claude "Mapped fields", ~line 48)
- Test: `AIUsageTests/MapperTests.swift`

**Interfaces:**
- Produces: `QuotaWindow.providerWarning: Bool`, a `var` defaulting to `false`, declared after `startsAt` so the memberwise init keeps every existing call site compiling. Doc comment: "The provider itself flags this window as used too fast, as of the reading."

- [ ] **Step 1: Write the failing tests** in `MapperTests`. Use `now = Date(timeIntervalSince1970: 1_800_000_000)`, the `oauth` value from `testClaudeMapsAllSupportedWindowsAndPlan`, and `resets_at` as epoch seconds.

```swift
func testClaudeReadsServerSeverity() throws {
    // Low usage, early in each window: only severity can fire.
    let json = """
    {
      "five_hour": {"utilization": 10, "resets_at": 1800014400},
      "seven_day": {"utilization": 10, "resets_at": 1800518400},
      "seven_day_sonnet": {"utilization": 10, "resets_at": 1800518400},
      "limits": [
        {"kind": "session", "group": "session", "percent": 10, "severity": "normal"},
        {"kind": "weekly_all", "group": "weekly", "percent": 10, "severity": "warning"},
        {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Sonnet"}}, "percent": 10, "severity": "normal"},
        {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Fable"}}, "percent": 10,
         "severity": "critical", "resets_at": 1800518400}
      ]
    }
    """
    // map(...) as in the existing test
    XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .sonnet, .fable])
    XCTAssertEqual(snapshot.windows.map(\.providerWarning), [false, true, false, true])
}

func testClaudeEarlyWarningThresholds() throws {
    // (kind JSON key, used, seconds until reset, expected)
    let cases: [(String, Double, Int, Bool)] = [
        ("five_hour", 90, 5_040, true),     // elapsed 0.72
        ("five_hour", 90, 4_860, false),    // elapsed 0.73
        ("five_hour", 89.9, 9_000, false),  // elapsed 0.50
        ("seven_day", 25, 514_080, true),   // elapsed 0.15
        ("seven_day", 25, 508_032, false),  // elapsed 0.16
        ("seven_day", 50, 393_120, true),   // elapsed 0.35
        ("seven_day", 75, 241_920, true),   // elapsed 0.60
        ("seven_day", 74, 241_920, false),  // elapsed 0.60
        ("seven_day_sonnet", 90, 544_320, false) // elapsed 0.10, no thresholds
    ]
    for (key, used, untilReset, expected) in cases {
        // {"<key>": {"utilization": used, "resets_at": 1_800_000_000 + untilReset}}, no limits
        XCTAssertEqual(snapshot.windows.first?.providerWarning, expected, "\(key) \(used)% \(untilReset)s")
    }
}

func testClaudeEarlyWarningNeedsAReset() throws {
    // {"five_hour": {"utilization": 99}, "seven_day": {"utilization": 99, "resets_at": null}}
    XCTAssertEqual(snapshot.windows.map(\.providerWarning), [false, false])
}

func testClaudeWithoutSeverityHasNoWarning() throws {
    // five_hour 10% resetting in 4 h; limits rows: session without severity,
    // weekly_all with "severity": 3, an unknown "kind": "daily" row with "warning".
    // A seven_day window at 10% resetting in 6 d. Also map a body with no "limits" key.
    XCTAssertEqual(snapshot.windows.map(\.providerWarning), [false, false])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' -only-testing:AIUsageTests/MapperTests`
Expected: build failure, `value of type 'QuotaWindow' has no member 'providerWarning'`.

- [ ] **Step 3: Add `providerWarning` to `QuotaWindow`** as specified in Interfaces.

- [ ] **Step 4: Set it in `ClaudeUsageMapper.map(response:credentials:resets:now:)`.**
  - Add `private static func warnedKinds(_ limits: Any?) -> Set<QuotaKind>`, which applies the severity and row → window rules from Global Constraints.
  - Add `private static let earlyWarnings: [QuotaKind: [(used: Double, elapsed: Double)]]`, holding the thresholds from Global Constraints. Add `private static func isAheadOfEarlyWarning(_ window: QuotaWindow, length: TimeInterval, now: Date) -> Bool`, which is false without `resetsAt`.
  - Pass `now` and the warned set into `appendWindow` / `appendFable` (or set the flag on `windows` after they are built). `providerWarning = warned.contains(kind) || isAheadOfEarlyWarning(...)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: the same command as Step 2.
Expected: `** TEST SUCCEEDED **`. The existing `testClaudeMapsAllSupportedWindowsAndPlan` still passes.

- [ ] **Step 6: Document the contract.** Under the Claude "Mapped fields" table in `docs/provider-contracts.md`, add a short paragraph. It covers `limits[].severity` and the row → window mapping. It lists the early-warning thresholds, citing Claude Code 2.1.332. It notes that `pace` and `indicator` are present but not read.

- [ ] **Step 7: Commit**

```bash
git add AIUsage/Models/ProviderModels.swift AIUsage/Providers/Claude/ClaudeUsageMapper.swift AIUsageTests/MapperTests.swift docs/provider-contracts.md
git commit -m "Read Claude's own usage warnings into each window"
```

### Task 2: Show the warning as risk

**Files:**
- Modify: `AIUsage/Models/ProviderModels.swift` (`ProviderSnapshot.isAtRisk`, ~line 569)
- Modify: `AIUsage/Store/UsageStore.swift` (`readings(for:in:displayMode:workSchedule:)`, ~line 290)
- Modify: `AIUsage/Views/ProviderSectionView.swift` (`QuotaTimingPresentation.init`, ~line 255; pace tick in `QuotaTile.body`, ~line 489)
- Modify: `AIUsage/Views/UsagePalette.swift`
- Modify: `AIUsage/Views/MenuBarLabelView.swift` (accessibility label ~line 44, tooltip details ~line 116)
- Test: `AIUsageTests/PaceForecastTests.swift`, `AIUsageTests/UsageStoreTests.swift`, `AIUsageTests/MenuBarPresentationTests.swift`; visual check with `VisualSnapshotTests/testAtRiskTileStaysCompact`

**Interfaces:**
- Consumes: `QuotaWindow.providerWarning: Bool` (Task 1).
- Produces: `ProviderSnapshot.isAtRisk(_:now:schedule:)`, which keeps its signature and is now true when `exhaustion(...) != nil`, or when the window has `providerWarning` and `now < resetsAt`. `exhaustion(for:now:schedule:)` is unchanged and stays `nil` for a warning-only window. `MenuBarReading.isAtRisk` is set from `snapshot.isAtRisk`, not from `exhaustion != nil`. `UsagePalette.paceTick(usedPercent: Double, isAtRisk: Bool) -> Color`.

- [ ] **Step 1: Write the failing tests**

In `PaceForecastTests` (reuse `session(used:)`, `t0`, `hour`; build a warned window with `var w = session(used: 10); w.providerWarning = true`):

```swift
func testProviderWarningMarksRiskWithoutForecast() {
    let p = QuotaTimingPresentation(window: warned(10), measuredAt: t0.addingTimeInterval(hour), now: t0.addingTimeInterval(70 * 60))
    XCTAssertTrue(p.isAtRisk)
    XCTAssertEqual(p.text, "Ahead of pace · Reset 3h 50m")
    XCTAssertEqual(p.compactText, "Ahead of pace")
    XCTAssertEqual(p.accessibilityText, "ahead of pace, Reset 3h 50m")
}

func testLocalForecastWinsOverProviderWarning() {
    // warned(40): same values as testAtRiskTimingShowsFullBeforeReset
    XCTAssertEqual(p.text, "Full 1h 20m · Reset 3h 50m")
}

func testProviderWarningEndsOnceResetHasPassed() {
    let snapshot = ProviderSnapshot(provider: .claude, planName: nil, windows: [warned(10)], fetchedAt: t0.addingTimeInterval(hour))
    XCTAssertTrue(snapshot.isAtRisk(.session, now: t0.addingTimeInterval(2 * hour)))
    XCTAssertNil(snapshot.exhaustion(for: .session, now: t0.addingTimeInterval(2 * hour)))
    XCTAssertFalse(snapshot.isAtRisk(.session, now: t0.addingTimeInterval(5 * hour + 600)))
    // QuotaTimingPresentation at now = 5 h + 600 s: isAtRisk false, text "Resetting"
}
```

Also in `PaceForecastTests`:

```swift
func testPaceTickTurnsWarningWhenAtRisk() {
    XCTAssertEqual(UsagePalette.paceTick(usedPercent: 30, isAtRisk: false), UsagePalette.normalUsage)
    XCTAssertEqual(UsagePalette.paceTick(usedPercent: 30, isAtRisk: true), UsagePalette.warning)
    XCTAssertEqual(UsagePalette.paceTick(usedPercent: 70, isAtRisk: false), UsagePalette.warning)
    XCTAssertEqual(UsagePalette.paceTick(usedPercent: 90, isAtRisk: true), UsagePalette.critical)
}
```

In `UsageStoreTests`, add `testMenuBarReadingCarriesProviderWarning`. It is modelled on `testMenuBarReadingCarriesRiskFromSnapshot`, with the session at 10% and `providerWarning = true`. Assertions: `isAtRisk == true`, `exhaustsAt == nil`.

In `MenuBarPresentationTests`:
- `testTooltipShowsAheadOfPaceWithoutExhaustion`: one Claude session reading with `isAtRisk: true`, `exhaustsAt: nil`, `resetsAt: t0 + 3 h`, en_GB in UTC. It expects:
  ```
  Claude Code
  ⏳ Session — 66% used
        Ahead of pace · Resets 11:00
  ```
  Match the indentation the existing tooltip test uses.
- In `testAtRiskPercentageAddsRiskToAccessibility` (~line 23), the `atRisk` and `staleAndAtRisk` readings get `exhaustsAt: Date(timeIntervalSince1970: 1_800_000_000)`. They model a local forecast and keep expecting "runs out before reset at this pace". Then add an assertion that the same reading without `exhaustsAt` gives `"Claude Code Session 40 percent used, ahead of pace"`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS' -only-testing:AIUsageTests/PaceForecastTests -only-testing:AIUsageTests/UsageStoreTests -only-testing:AIUsageTests/MenuBarPresentationTests`
Expected: the new tests FAIL (`isAtRisk` false, or the text has no "Ahead of pace").

- [ ] **Step 3: Implement**
  - `ProviderSnapshot.isAtRisk`: OR in `window.providerWarning`, with the reset still ahead of `now` (Interfaces).
  - `UsageStore.readings`: `isAtRisk: state.snapshot?.isAtRisk(item.metric, now: now, schedule: workSchedule) ?? false`, keeping `exhaustsAt: exhaustion`.
  - `QuotaTimingPresentation.init`: when `now < reset` and there is no exhaustion, but `window.providerWarning` is set, use the Global Constraints copy with `isAtRisk = true`. Otherwise behaviour is unchanged.
  - `UsagePalette.paceTick`: the rule from Global Constraints. In `QuotaTile.body`, fill the pace tick with `UsagePalette.paceTick(usedPercent: window.usedPercent, isAtRisk: timing.isAtRisk)` instead of `progressTint`. The bar keeps `progressTint`.
  - `MenuBarLabelView`: the accessibility suffix is `", runs out before reset at this pace"` when `exhaustsAt != nil`, and `", ahead of pace"` when only `isAtRisk` holds. In the tooltip, after the `exhaustsAt` branch, add `else if reading.isAtRisk { details.append("Ahead of pace") }`.

- [ ] **Step 4: Run the full suite**

Run: `xcodebuild test -project AIUsage.xcodeproj -scheme AIUsage -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`. Check that `testAtRiskTileStaysCompact` still passes, since the tick colour changes on the at-risk tile. `VisualSnapshotTests` / `ReadmeShowcaseTests` do not change, because their fixtures set no `providerWarning`.

- [ ] **Step 5: Commit**

```bash
git add AIUsage AIUsageTests
git commit -m "Show Claude's own usage warnings as at-risk"
```
