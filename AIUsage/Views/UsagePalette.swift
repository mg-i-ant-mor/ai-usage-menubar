import AppKit
import SwiftUI

enum UsagePalette {
    static let accent = Color(nsColor: .systemBlue)
    static let normalUsage = Color(nsColor: .systemTeal)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let critical = Color(nsColor: .systemRed)

    /// The colour of a pace zone: red far ahead, orange ahead, otherwise the usage colour.
    static func zoneTint(_ zone: PaceReading.Zone?) -> Color {
        switch zone {
        case .farAhead: critical
        case .ahead: warning
        case .onTrack, nil: normalUsage
        }
    }

    /// The colour of a usage level: `warning` from 60%, `critical` from 85%,
    /// mixed from `base` by `weight` (the pace's level weight), so a calm pace
    /// mutes it. 100% is always `critical`.
    static func levelTint(usedPercent: Double, weight: Double, base: Color) -> Color {
        switch usedPercent {
        case 100...: critical
        case 85...: base.mix(with: critical, by: weight)
        case 60...: base.mix(with: warning, by: weight)
        default: base
        }
    }
}
