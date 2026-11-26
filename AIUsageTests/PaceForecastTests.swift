import SwiftUI
import XCTest
@testable import AIUsage

final class PaceForecastTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600

    private func session(
        used: Double,
        startsAt: Date? = nil,
        resetsAt: Date? = nil,
        noStart: Bool = false,
        noReset: Bool = false
    ) -> QuotaWindow {
        QuotaWindow(
            kind: .session,
            usedPercent: used,
            resetsAt: noReset ? nil : (resetsAt ?? t0.addingTimeInterval(5 * hour)),
            startsAt: noStart ? nil : (startsAt ?? t0)
        )
    }

    func testProjectsExhaustionBeforeReset() {
        let window = session(used: 40)
        XCTAssertEqual(
            window.projectedExhaustion(measuredAt: t0.addingTimeInterval(hour)),
            t0.addingTimeInterval(2.5 * hour)
        )
    }

    func testNoProjectionWhenPaceReachesResetFirst() {
        let window = session(used: 10)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(hour)))
    }

    func testProjectsFromTheStartOfTheWindow() {
        XCTAssertEqual(session(used: 30).projectedExhaustion(measuredAt: t0.addingTimeInterval(20 * 60)),
                       t0.addingTimeInterval(4_000))
    }

    func testNoProjectionAtZeroUsage() {
        let window = session(used: 0)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(2 * hour)))
    }

    func testNoProjectionAtOrAbove100Percent() {
        let window = session(used: 100)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(hour)))
    }

    func testNoProjectionWithoutStartOrReset() {
        let measured = t0.addingTimeInterval(hour)
        XCTAssertNil(session(used: 40, noStart: true).projectedExhaustion(measuredAt: measured))
        XCTAssertNil(session(used: 40, noReset: true).projectedExhaustion(measuredAt: measured))
    }

    func testNoProjectionAfterReset() {
        let window = session(used: 50)
        XCTAssertNil(window.projectedExhaustion(measuredAt: t0.addingTimeInterval(5 * hour)))
    }

    func testProjectionUsesMeasurementTimeNotRenderTime() {
        let window = session(used: 40)
        let measured = t0.addingTimeInterval(hour)
        let first = window.projectedExhaustion(measuredAt: measured)
        let second = window.projectedExhaustion(measuredAt: measured)
        XCTAssertEqual(first, t0.addingTimeInterval(2.5 * hour))
        XCTAssertEqual(first, second)
    }

    func testMonthlyStartIsOneCalendarMonthBeforeReset() {
        XCTAssertEqual(
            ProviderParsing.monthStart(endingAt: ProviderParsing.date("2027-03-01T00:00:00Z")),
            ProviderParsing.date("2027-02-01T00:00:00Z")
        )
        XCTAssertEqual(
            ProviderParsing.monthStart(endingAt: ProviderParsing.date("2027-03-31T00:00:00Z")),
            ProviderParsing.date("2027-02-28T00:00:00Z")
        )
        XCTAssertNil(ProviderParsing.monthStart(endingAt: nil))
    }

    // MARK: - Tile timing

    private func timing(used: Double, nowAfter minutes: Double) -> QuotaTimingPresentation {
        QuotaTimingPresentation(
            window: session(used: used).withPace(at: t0.addingTimeInterval(hour), previous: nil, schedule: nil),
            measuredAt: t0.addingTimeInterval(hour),
            now: t0.addingTimeInterval(minutes * 60)
        )
    }

    func testAtRiskTimingShowsFullBeforeReset() {
        let presentation = timing(used: 40, nowAfter: 70)
        XCTAssertTrue(presentation.isAtRisk)
        XCTAssertEqual(presentation.text, "Full 1h 20m · Reset 3h 50m")
        XCTAssertEqual(presentation.compactText, "Full 1h 20m")
        XCTAssertEqual(
            presentation.accessibilityText,
            "full in 1h 20m at this pace, Reset 3h 50m"
        )
    }

    func testSafeTimingKeepsResetOnly() {
        let presentation = timing(used: 10, nowAfter: 70)
        XCTAssertFalse(presentation.isAtRisk)
        XCTAssertEqual(presentation.text, "Reset 3h 50m")
        XCTAssertEqual(presentation.compactText, "Reset 3h 50m")
        XCTAssertEqual(presentation.accessibilityText, "Reset 3h 50m")
    }

    func testPastProjectionReadsFullSoon() {
        let presentation = timing(used: 40, nowAfter: 190)
        XCTAssertTrue(presentation.isAtRisk)
        XCTAssertEqual(presentation.text, "Full soon · Reset 1h 50m")
        XCTAssertEqual(presentation.compactText, "Full soon")
    }

    func testTimingDropsForecastOnceResetHasPassed() {
        let presentation = QuotaTimingPresentation(
            window: session(used: 90).withPace(at: t0.addingTimeInterval(4 * hour), previous: nil, schedule: nil),
            measuredAt: t0.addingTimeInterval(4 * hour),
            now: t0.addingTimeInterval(5 * hour + 600)
        )
        XCTAssertFalse(presentation.isAtRisk)
        XCTAssertEqual(presentation.text, "Resetting")
        XCTAssertEqual(presentation.compactText, "Resetting")
    }

    func testSnapshotRiskEndsOnceResetHasPassed() {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planName: nil,
            windows: [session(used: 90)],
            fetchedAt: t0.addingTimeInterval(4 * hour)
        ).paced(previous: nil, schedule: nil)
        XCTAssertTrue(snapshot.isAtRisk(.session, now: t0.addingTimeInterval(4 * hour + 60)))
        XCTAssertFalse(snapshot.isAtRisk(.session, now: t0.addingTimeInterval(5 * hour + 600)))
    }

    func testTimingFollowsTheWorkSchedule() {
        let saturday = ProviderParsing.date("2027-01-23T12:00:00Z")!
        let window = QuotaWindow(
            kind: .weekly,
            usedPercent: 85,
            resetsAt: ProviderParsing.date("2027-01-25T08:00:00Z"),
            startsAt: ProviderParsing.date("2027-01-18T08:00:00Z")
        )
        let calendar = window.withPace(at: saturday, previous: nil, schedule: nil)
        let working = window.withPace(at: saturday, previous: nil, schedule: .standard)
        XCTAssertTrue(QuotaTimingPresentation(
            window: calendar, measuredAt: saturday, now: saturday
        ).isAtRisk)
        XCTAssertFalse(QuotaTimingPresentation(
            window: working, measuredAt: saturday, now: saturday, schedule: .standard
        ).isAtRisk)

        let snapshot = ProviderSnapshot(
            provider: .claude, planName: nil, windows: [window], fetchedAt: saturday
        )
        XCTAssertNotNil(snapshot.paced(previous: nil, schedule: nil)
            .exhaustion(for: .weekly, now: saturday))
        XCTAssertNil(snapshot.paced(previous: nil, schedule: .standard)
            .exhaustion(for: .weekly, now: saturday, schedule: .standard))
    }

    func testTimingWithoutResetHasNoText() {
        let presentation = QuotaTimingPresentation(
            window: session(used: 40, noReset: true),
            measuredAt: t0.addingTimeInterval(hour),
            now: t0.addingTimeInterval(hour)
        )
        XCTAssertFalse(presentation.isAtRisk)
        XCTAssertNil(presentation.text)
        XCTAssertNil(presentation.accessibilityText)
    }

    // MARK: - Risk follows the zone

    private var m70: Date { t0.addingTimeInterval(70 * 60) }

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
        func zone(used: Double) -> PaceReading.Zone? {
            let window = session(used: used).withPace(at: t0.addingTimeInterval(hour), previous: nil, schedule: nil)
            return QuotaTimingPresentation(window: window, measuredAt: t0.addingTimeInterval(hour), now: m70).zone
        }
        XCTAssertEqual(zone(used: 27), .ahead)
        XCTAssertEqual(zone(used: 40), .farAhead)
    }

    func testZoneTint() {
        XCTAssertEqual(UsagePalette.zoneTint(.farAhead), UsagePalette.critical)
        XCTAssertEqual(UsagePalette.zoneTint(.ahead), UsagePalette.warning)
        XCTAssertEqual(UsagePalette.zoneTint(.onTrack), UsagePalette.normalUsage)
        XCTAssertEqual(UsagePalette.zoneTint(nil), UsagePalette.normalUsage)
    }

    func testLevelTintMutesOnACalmPace() {
        let base = UsagePalette.normalUsage
        XCTAssertEqual(UsagePalette.levelTint(usedPercent: 50, weight: 1, base: base), base)
        XCTAssertEqual(UsagePalette.levelTint(usedPercent: 100, weight: 0, base: base), UsagePalette.critical)
        assertColour(UsagePalette.levelTint(usedPercent: 90, weight: 1, base: base), UsagePalette.critical)
        assertColour(UsagePalette.levelTint(usedPercent: 70, weight: 1, base: base), UsagePalette.warning)
        assertColour(UsagePalette.levelTint(usedPercent: 70, weight: 0, base: base), base)
        assertColour(UsagePalette.levelTint(usedPercent: 90, weight: 0, base: base), base)
    }

    private func assertColour(_ a: Color, _ b: Color, file: StaticString = #filePath, line: UInt = #line) {
        let x = a.resolve(in: EnvironmentValues()), y = b.resolve(in: EnvironmentValues())
        XCTAssertEqual(x.red, y.red, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(x.green, y.green, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(x.blue, y.blue, accuracy: 0.01, file: file, line: line)
    }
}
