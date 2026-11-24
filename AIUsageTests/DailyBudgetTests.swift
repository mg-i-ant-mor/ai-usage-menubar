import XCTest
@testable import AIUsage

final class DailyBudgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // Fri 15 Jan 2027 08:00 UTC
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private func weekly(
        used: Double,
        resetIn: TimeInterval?,
        startsBeforeReset: TimeInterval? = nil
    ) -> QuotaWindow {
        let reset = resetIn.map { now.addingTimeInterval($0) }
        return QuotaWindow(
            kind: .weekly,
            usedPercent: used,
            resetsAt: reset,
            startsAt: startsBeforeReset.flatMap { length in reset?.addingTimeInterval(-length) }
        )
    }

    private func budgetText(used: Double, resetIn: TimeInterval) -> String? {
        weekly(used: used, resetIn: resetIn).dailyBudget(now: now).map(QuotaWindow.budgetText)
    }

    // MARK: Arithmetic

    func testExamples() {
        // 12 / 1.958 = 6.13; one decimal under 10%.
        XCTAssertEqual(budgetText(used: 88, resetIn: day + 23 * hour), "6.1")
        XCTAssertEqual(budgetText(used: 43, resetIn: 3 * day + 17 * hour), "15")
        XCTAssertEqual(budgetText(used: 63, resetIn: 19 * day + 6 * hour), "1.9")
    }

    func testRoundingSwitchesToWholeNumbersAtTen() {
        XCTAssertEqual(QuotaWindow.budgetText(9.94), "9.9")
        XCTAssertEqual(QuotaWindow.budgetText(9.96), "10")
        XCTAssertEqual(QuotaWindow.budgetText(10.4), "10")
    }

    func testOverusedReadingCountsAsNothingLeftButStillBelow100() {
        // Never below zero, and a window over 100% is exhausted.
        XCTAssertNil(weekly(used: 120, resetIn: 3 * day).dailyBudget(now: now))
        XCTAssertEqual(weekly(used: 0, resetIn: 4 * day).dailyBudget(now: now), 25)
    }

    // MARK: When it is not shown

    func testNoBudgetForWindowsShorterThanADay() {
        let session = weekly(used: 10, resetIn: 30 * hour, startsBeforeReset: 5 * hour)
        XCTAssertNil(session.dailyBudget(now: now))
        let fullDay = weekly(used: 10, resetIn: 30 * hour, startsBeforeReset: day)
        XCTAssertNotNil(fullDay.dailyBudget(now: now))
    }

    func testNoBudgetWithinADayOfTheReset() {
        XCTAssertNil(weekly(used: 40, resetIn: 23 * hour).dailyBudget(now: now))
        XCTAssertNotNil(weekly(used: 40, resetIn: day).dailyBudget(now: now))
    }

    func testNoBudgetWithoutAFutureReset() {
        XCTAssertNil(weekly(used: 40, resetIn: nil).dailyBudget(now: now))
        XCTAssertNil(weekly(used: 40, resetIn: -hour).dailyBudget(now: now))
    }

    func testNoBudgetWhenExhausted() {
        XCTAssertNil(weekly(used: 100, resetIn: 3 * day).dailyBudget(now: now))
    }

    // MARK: Tile and VoiceOver

    func testTileShowsBudgetBeforeTheReset() {
        let timing = QuotaTimingPresentation(
            window: weekly(used: 88, resetIn: day + 23 * hour),
            measuredAt: now,
            now: now
        )
        XCTAssertFalse(timing.isAtRisk)
        XCTAssertEqual(timing.text, "6.1%/day · Reset 1d 23h")
        XCTAssertEqual(timing.compactText, "Reset 1d 23h")
        XCTAssertEqual(
            timing.accessibilityText,
            "about 6.1 percent a day until reset, Reset 1d 23h"
        )
    }

    func testTileWithoutBudgetKeepsTheResetLine() {
        let timing = QuotaTimingPresentation(
            window: weekly(used: 40, resetIn: 5 * hour),
            measuredAt: now,
            now: now
        )
        XCTAssertEqual(timing.text, "Reset 5h 1m")
        XCTAssertEqual(timing.accessibilityText, "Reset 5h 1m")
    }

    func testAtRiskTileLeavesBudgetToVoiceOver() {
        // 60% in the first 79h of a week: the other 40% takes ~53h, before the
        // reset 89h away. Budget 40 / 3.71 days ≈ 11.
        let window = weekly(used: 60, resetIn: 3 * day + 17 * hour, startsBeforeReset: 7 * day)
        let timing = QuotaTimingPresentation(window: window, measuredAt: now, now: now)
        XCTAssertTrue(timing.isAtRisk)
        XCTAssertEqual(timing.text, "Full 2d 4h · Reset 3d 17h")
        XCTAssertEqual(
            timing.accessibilityText,
            "full in 2d 4h at this pace, about 11 percent a day until reset, Reset 3d 17h"
        )
    }

    // MARK: Tooltip

    func testTooltipAddsBudgetToTheDetailLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let groups = [MenuBarProviderReadings(
            provider: .claude,
            selectedMetrics: [.weekly, .sonnet],
            readings: [
                MenuBarReading(
                    provider: .claude, metric: .weekly, value: .percentage(88),
                    displayMode: .used, isStale: false,
                    resetsAt: now.addingTimeInterval(day + 23 * hour),
                    dailyBudget: 12 / (47.0 / 24)
                ),
                MenuBarReading(
                    provider: .claude, metric: .sonnet, value: .percentage(60),
                    displayMode: .used, isStale: false, isAtRisk: true,
                    resetsAt: now.addingTimeInterval(3 * day + 17 * hour),
                    exhaustsAt: now.addingTimeInterval(2 * day + 4 * hour),
                    dailyBudget: 40 / (89.0 / 24)
                )
            ]
        )]

        XCTAssertEqual(MenuBarTooltip.text(
            for: groups,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_GB")
        ), """
        Claude Code
        🔴 Weekly — 88% used
              About 6.1% a day · Resets Sun 07:00
        ⏳ Sonnet — 60% used
              Full by Sun 12:00 at this pace · About 11% a day · Resets Tue 01:00
        """)
    }

    // MARK: Store

    @MainActor
    func testReadingsCarryTheSameBudgetInLeftAndUsedModes() async {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planName: "Pro",
            windows: [QuotaWindow(
                kind: .weekly,
                usedPercent: 40,
                resetsAt: Date().addingTimeInterval(10 * day)
            )],
            fetchedAt: Date()
        )
        let store = UsageStore(
            providers: [SequencedProvider(id: .claude, results: [.success(snapshot)])],
            availabilityChecker: FixedProviderAvailabilityChecker(installed: [.claude])
        )
        await store.refresh()
        let configuration = MenuBarProviderConfiguration(provider: .claude, metrics: [.weekly])

        let budgets = [UsageDisplayMode.used, .remaining].map {
            store.menuBarProviderReadings(for: [configuration], displayMode: $0)
                .first?.readings.first?.dailyBudget
        }
        // Each read takes its own `now`, so allow for the moments between them.
        XCTAssertEqual(budgets[0] ?? 0, 6, accuracy: 0.01)
        XCTAssertEqual(budgets[1] ?? 0, budgets[0] ?? -1, accuracy: 0.0001)
    }
}
