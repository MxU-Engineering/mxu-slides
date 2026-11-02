import Foundation

public enum LibraryPresentLogic {
    public static func fires(_ kind: DocumentKind) -> Bool {
        kind == .media || kind == .audio || kind == .overlay
    }

    public static func editsFromRow(_ kind: DocumentKind) -> Bool {
        fires(kind) || kind == .presentation || kind == .theme
    }

    public static let volunteerDefaultKinds: [DocumentKind] = [.presentation, .overlay, .media, .audio]

    public static func volunteerKinds(stored: String?) -> [DocumentKind] {
        guard let stored else { return volunteerDefaultKinds }
        let picked = Set(stored.split(separator: ",").compactMap { DocumentKind(rawValue: String($0)) })
        return volunteerDefaultKinds.filter(picked.contains)
    }

    public static func takesCenter(_ kind: DocumentKind) -> Bool {
        kind == .presentation
    }

    public static func fireLabel(_ kind: DocumentKind, live: Bool) -> String {
        switch (kind, live) {
        case (.overlay, false): "Go Live"
        case (.overlay, true): "Take Down"
        case (_, false): "Play"
        case (_, true): "Stop"
        }
    }

    public static func showsThumbnail(_ kind: DocumentKind) -> Bool {
        switch kind {
        case .presentation, .media, .audio, .overlay, .theme, .confidenceLayout: true
        default: false
        }
    }

    public static func showsLastUsed(_ kind: DocumentKind) -> Bool {
        fires(kind) || kind == .presentation
    }

    public static func lastUsedText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Not used yet" }
        if calendar.isDate(date, inSameDayAs: now) { return "Used today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Used yesterday"
        }
        var style: Date.FormatStyle = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? .dateTime.month(.abbreviated).day()
            : .dateTime.month(.abbreviated).day().year()
        style.timeZone = calendar.timeZone
        return "Used " + date.formatted(style.locale(calendar.locale ?? .current))
    }
}
