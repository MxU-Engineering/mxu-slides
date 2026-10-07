import SwiftUI

enum ServiceControlsModule: String, Codable, CaseIterable, Sendable {
    case audio
    case mixer
    case media
    case timers

    case tracking
    case alerts
    case overlays
    case combos
    case confidence

    case outputs

    static let defaultOrder: [ServiceControlsModule] = [
        .combos, .timers, .tracking, .overlays, .audio, .alerts,
        .mixer, .media, .confidence, .outputs,
    ]

    var title: String {
        switch self {
        case .audio: "Music"
        case .mixer: "Mixer"

        case .media: "Signage"
        case .timers: "Timers"
        case .tracking: "Service Tracking"
        case .alerts: "Alerts"
        case .overlays: "Overlays"
        case .combos: "Combos"
        case .confidence: "Confidence Monitor"
        case .outputs: "Outputs"
        }
    }

    var glyph: GlyphKind {
        switch self {
        case .audio: .audio
        case .mixer: .mixer
        case .media: .media
        case .timers: .timers
        case .tracking: .timers
        case .alerts: .alerts
        case .overlays: .overlays
        case .combos: .combos
        case .confidence: .confidence
        case .outputs: .screens
        }
    }
}

extension View {

    @ViewBuilder
    func draggablePayload(_ payload: String?) -> some View {
        if let payload {
            draggable(payload)
        } else {
            self
        }
    }
}

extension EnvironmentValues {

    @Entry var moduleCompact: Bool = true

    @Entry var runOnly: Bool = false
}
