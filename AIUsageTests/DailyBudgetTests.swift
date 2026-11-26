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
            .withPace(at: now, previous: nil, schedule: nil)
        let timing = QuotaTimingPresentation(window: window, measuredAt: now, now: now)
        XCTAssertTrue(timing.isAtRisk)
        XCTAssertEqual(timing.text, "Full 2d 4h · Reset 3d 17h")
        XCTAssertEqual(
            timing.accessibilityText,
            "full in 2d 4h at this pace, about 11 percent a day until reset, Reset 3d 17h"
        )
    }

    // MARK: On-pace mark

    func testSessionMarkIsTheShareOfTheWindowPassed() {
        let session = QuotaWindow(
            kind: .session, usedPercent: 15,
            resetsAt: now.addingTimeInterval(3 * hour),
            startsAt: now.addingTimeInterval(-2 * hour)
        )
        XCTAssertEqual(session.onPacePercent(now: now) ?? -1, 40, accuracy: 0.001)
        // Sessions ignore working hours.
        XCTAssertEqual(session.onPacePercent(now: now, schedule: .standard) ?? -1, 40, accuracy: 0.001)
    }

    func testWeeklyMarkCountsWorkingTimeWithASchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Mon 18 Jan 08:00 to Mon 25 Jan 08:00; Wednesday 18:00 is 3 of 5
        // working days, but 58 of 168 hours.
        let week = QuotaWindow(
            kind: .weekly, usedPercent: 30,
            resetsAt: ProviderParsing.date("2027-01-25T08:00:00Z"),
            startsAt: ProviderParsing.date("2027-01-18T08:00:00Z")
        )
        let wednesday = ProviderParsing.date("2027-01-20T18:00:00Z")!
        XCTAssertEqual(
            week.onPacePercent(now: wednesday, schedule: .standard, calendar: calendar) ?? -1,
            60, accuracy: 0.001
        )
        XCTAssertEqual(week.onPacePercent(now: wednesday) ?? -1, 58.0 / 168 * 100, accuracy: 0.001)
    }

    func testNoMarkWithoutAKnownWindow() {
        XCTAssertNil(weekly(used: 30, resetIn: 3 * day).onPacePercent(now: now))
        let past = weekly(used: 30, resetIn: -hour, startsBeforeReset: 7 * day)
        XCTAssertNil(past.onPacePercent(now: now))
    }

    func testMarkIsReadInTheTilesMode() {
        XCTAssertEqual(
            QuotaTimingPresentation.onPaceText(40, displayMode: .used),
            "on pace at 40 percent used"
        )
        XCTAssertEqual(
            QuotaTimingPresentation.onPaceText(40, displayMode: .remaining),
            "on pace at 60 percent left"
        )
    }
}
