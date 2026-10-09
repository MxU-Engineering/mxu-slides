import Foundation

public extension PresentationOrigin {
    init(_ source: PresentationOriginSource, detail: String? = nil, at date: Date? = Date()) {
        self.init(
            source: source,
            detail: detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? detail : nil,
            createdAt: date.map { ISO8601DateFormatter().string(from: $0) })
    }

    var label: String {
        let source = switch self.source {
        case .madeHere: "Made in MxU Slides"
        case .proPresenter: "ProPresenter import"
        case .planningCenterChart: "Planning Center chart"
        case .planningCenterLyrics: "Planning Center lyrics"
        case .songSelect: "SongSelect"
        case .lyricsFile: "Lyrics file"
        case .chartFile: "Chord chart file"
        case .pastedLyrics: "Pasted lyrics"
        case .slidesFile: "MxU Slides file"
        case .duplicate: "Copy"
        }
        return ([source] + [detail].compactMap { $0 }).joined(separator: " · ")
    }
}

public extension Presentation {

    var originLabel: String? {
        if let origin {
            origin.label
        } else if chordProSource != nil {
            "Chord chart import"
        } else if ccli != nil, reflowSource != nil {
            "Lyrics import"
        } else {
            nil
        }
    }
}
