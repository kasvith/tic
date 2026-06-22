import Foundation

/// How a note's background is rendered. `.solid` is the universal baseline; `.glass` is an
/// opt-in Liquid Glass style that only renders on macOS 26+ and falls back to `.solid` below.
enum NoteMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid
    case glass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solid: return "Solid"
        case .glass: return "Glass"
        }
    }
}
