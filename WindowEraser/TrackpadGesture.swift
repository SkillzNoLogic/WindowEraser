import Foundation

/// The gestures that can be assigned to a hidden app. Only multi-finger taps and holds
/// are offered: they don't clash with clicking, scrolling, or the system swipes/pinches.
nonisolated enum TrackpadGesture: String, CaseIterable, Identifiable, Sendable {
    case threeFingerDoubleTap
    case threeFingerTripleTap
    case fourFingerDoubleTap
    case fourFingerTripleTap
    case fiveFingerDoubleTap
    case fiveFingerTripleTap
    case threeFingerHold
    case fourFingerHold
    case fiveFingerHold

    var id: String { rawValue }

    var fingers: Int {
        switch self {
        case .threeFingerDoubleTap, .threeFingerTripleTap, .threeFingerHold: 3
        case .fourFingerDoubleTap, .fourFingerTripleTap, .fourFingerHold: 4
        case .fiveFingerDoubleTap, .fiveFingerTripleTap, .fiveFingerHold: 5
        }
    }

    /// Number of taps, or 0 for a press-and-hold.
    var taps: Int {
        switch self {
        case .threeFingerDoubleTap, .fourFingerDoubleTap, .fiveFingerDoubleTap: 2
        case .threeFingerTripleTap, .fourFingerTripleTap, .fiveFingerTripleTap: 3
        case .threeFingerHold, .fourFingerHold, .fiveFingerHold: 0
        }
    }

    var title: String {
        switch taps {
        case 2: "\(fingers)-finger double tap"
        case 3: "\(fingers)-finger triple tap"
        default: "\(fingers)-finger hold"
        }
    }

    static func tap(fingers: Int, taps: Int) -> TrackpadGesture? {
        allCases.first { $0.fingers == fingers && $0.taps == taps }
    }

    static func hold(fingers: Int) -> TrackpadGesture? {
        allCases.first { $0.fingers == fingers && $0.taps == 0 }
    }
}
