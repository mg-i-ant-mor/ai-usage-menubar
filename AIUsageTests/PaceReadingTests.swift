import XCTest
@testable import AIUsage

final class PaceReadingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600

    private func pace(
        _ used: Double,
        at hours: Double,
        previous: PaceReading.Zone? = nil
    ) -> PaceReading? {
        let window = QuotaWindow(
            kind: .session, usedPercent: used,
            resetsAt: t0.addingTimeInterval(5 * hour), startsAt: t0
        )
        return PaceReading(
            window: window, at: t0.addingTimeInterval(hours * hour),
            previous: previous, schedule: nil
        )
    }

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
        let reset = t0.addingTimeInterval(5 * hour)
        let noStart = QuotaWindow(kind: .session, usedPercent: 30, resetsAt: reset, startsAt: nil)
        let noReset = QuotaWindow(kind: .session, usedPercent: 30, resetsAt: nil, startsAt: t0)
        let now = t0.addingTimeInterval(hour)
        XCTAssertNil(PaceReading(window: noStart, at: now, previous: nil, schedule: nil))
        XCTAssertNil(PaceReading(window: noReset, at: now, previous: nil, schedule: nil))
        XCTAssertNil(pace(30, at: 5 + 600 / hour))
    }
}
