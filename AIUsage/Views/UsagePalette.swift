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
}
