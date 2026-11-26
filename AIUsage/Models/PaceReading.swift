import Foundation

/// How far a window's usage runs ahead of its pace, weighted by how much of
/// the window has passed, so an early lead counts for less than a late one.
struct PaceReading: Equatable, Sendable {
    enum Zone: Int, Comparable, Sendable {
        case onTrack, ahead, farAhead

        static func < (lhs: Zone, rhs: Zone) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Steepness `k` of the confidence curve.
    static let confidenceRate = 8.0
    /// Weighted points ahead of pace that leave "on track" (`m`); twice it is "far ahead".
    static let margin = 5.0
    /// Weighted points a zone is held past its entry threshold (`h`).
    static let hysteresis = 5.0
    /// Seconds a window's reset may drift between fetches and still count as the same window.
    static let resetJitter: TimeInterval = 60

    let zone: Zone
    /// `f`: 0 at 70% of the pace or less, 1 at the pace or more.
    let levelWeight: Double
    /// When the pace catches up with the usage; `nil` unless used% > elapsed%.
    let coolsAt: Date?

    /// `nil` without a known start and reset, or when `date` is outside the window.
    init?(
        window: QuotaWindow,
        at date: Date,
        previous: Zone?,
        schedule: WorkSchedule?,
        calendar: Calendar = .current
    ) {
        guard let elapsed = window.onPacePercent(now: date, schedule: schedule, calendar: calendar),
              let start = window.startsAt, let reset = window.resetsAt else { return nil }
        let delta = window.usedPercent - elapsed
        let weighted = delta * Self.confidence(elapsed: elapsed / 100)

        let m = Self.margin, h = Self.hysteresis
        if weighted > 2 * m || (previous == .farAhead && weighted > 2 * m - h) { zone = .farAhead }
        else if weighted > m || ((previous ?? .onTrack) >= .ahead && weighted > m - h) { zone = .ahead }
        else { zone = .onTrack }

        levelWeight = elapsed > 0 ? Self.smoothstep(0.7, 1.0, window.usedPercent / elapsed) : 1

        if delta > 0 {
            let cools: Date
            if let schedule, reset.timeIntervalSince(start) > 86_400 {
                let needed = delta / 100 * schedule.workingTime(from: start, to: reset, calendar: calendar)
                cools = schedule.date(byAddingWorkingTime: needed, to: date, calendar: calendar) ?? reset
            } else {
                cools = date.addingTimeInterval(delta / 100 * reset.timeIntervalSince(start))
            }
            coolsAt = min(cools, reset)
        } else {
            coolsAt = nil
        }
    }

    /// `1 − e^(−k·elapsed)`; `elapsed` is a 0…1 fraction of the window.
    static func confidence(elapsed: Double) -> Double {
        1 - exp(-confidenceRate * elapsed)
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

extension QuotaWindow {
    func withPace(
        at date: Date,
        previous: PaceReading.Zone?,
        schedule: WorkSchedule?,
        calendar: Calendar = .current
    ) -> QuotaWindow {
        var window = self
        window.pace = PaceReading(
            window: self, at: date, previous: previous, schedule: schedule, calendar: calendar
        )
        return window
    }

    /// Running ahead of its pace, not yet full, with the reset still ahead of `now`.
    func isAtRisk(now: Date) -> Bool {
        guard let zone = pace?.zone, zone >= .ahead, usedPercent < 100,
              let reset = resetsAt else { return false }
        return now < reset
    }
}

extension ProviderSnapshot {
    /// Each window paced at `fetchedAt`, holding its zone from `previous`'s window of the
    /// same kind and reset (within `PaceReading.resetJitter`); a rolled-over window starts fresh.
    func paced(
        previous: ProviderSnapshot?,
        schedule: WorkSchedule?,
        calendar: Calendar = .current
    ) -> ProviderSnapshot {
        var snapshot = self
        snapshot.windows = windows.map { window in
            window.withPace(
                at: fetchedAt,
                previous: previous?.windows.first { old in
                    guard old.kind == window.kind, let oldReset = old.resetsAt,
                          let reset = window.resetsAt else { return false }
                    return abs(oldReset.timeIntervalSince(reset)) < PaceReading.resetJitter
                }?.pace?.zone,
                schedule: schedule,
                calendar: calendar
            )
        }
        for index in snapshot.otherAccounts.indices {
            let previousAccount = previous?.otherAccounts.first { $0.id == snapshot.otherAccounts[index].id }
            snapshot.otherAccounts[index].snapshot = snapshot.otherAccounts[index].snapshot?.paced(
                previous: previousAccount?.snapshot, schedule: schedule, calendar: calendar
            )
        }
        return snapshot
    }
}
