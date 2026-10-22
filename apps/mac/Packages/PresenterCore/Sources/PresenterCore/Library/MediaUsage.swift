import Foundation

public enum MediaUsage {
    public struct Use: Hashable, Sendable {
        public let kind: DocumentKind
        public let id: String
        public let name: String

        public let via: String?

        public init(kind: DocumentKind, id: String, name: String, via: String? = nil) {
            self.kind = kind
            self.id = id
            self.name = name
            self.via = via
        }
    }

    public struct Document: Sendable {
        public let use: Use
        public let mediaIDs: Set<String>
        public let themeIDs: Set<String>

        public init(use: Use, mediaIDs: Set<String>, themeIDs: Set<String> = []) {
            self.use = use
            self.mediaIDs = mediaIDs
            self.themeIDs = themeIDs
        }
    }

    public static func themeIDs(in presentation: Presentation) -> Set<String> {
        var out: Set<String> = [presentation.themeId]
        for slide in presentation.slides {
            if let id = slide.themeId { out.insert(id) }
            for design in slide.overrideDesigns ?? [] { out.insert(design.themeId) }
        }
        out.remove("")
        return out
    }

    public static func uses(of id: String, in documents: [Document]) -> [Use] {
        let direct = documents.filter { $0.mediaIDs.contains(id) }
        let themes = Dictionary(
            direct.filter { $0.use.kind == .theme }.map { ($0.use.id, $0.use.name) },
            uniquingKeysWith: { first, _ in first })
        let directIDs = Set(direct.map(\.use.id))
        let viaTheme = documents.compactMap { document -> Use? in
            let theme = document.themeIDs.sorted().first { themes[$0] != nil }
            return if let theme, !directIDs.contains(document.use.id) {
                Use(kind: document.use.kind, id: document.use.id, name: document.use.name, via: themes[theme])
            } else {
                nil
            }
        }
        return direct.map(\.use) + viaTheme
    }

    public struct Group: Hashable, Sendable {
        public let kind: DocumentKind
        public let title: String
        public let symbol: String
        public let uses: [Use]
    }

    public static let order: [DocumentKind] = [
        .theme, .presentation, .overlay, .service, .playlist,
        .confidenceLayout, .actionCombo, .scheduleTrigger,
    ]

    public static func groups(_ uses: [Use]) -> [Group] {
        order.compactMap { kind in
            let named = uses.filter { $0.kind == kind }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return named.isEmpty ? nil : Group(kind: kind, title: title(kind), symbol: symbol(kind), uses: named)
        }
    }

    static func title(_ kind: DocumentKind) -> String {
        switch kind {
        case .theme: "Themes"
        case .presentation: "Presentations"
        case .overlay: "Overlays"
        case .service: "Services"
        case .playlist: "Playlists"
        case .confidenceLayout: "Stage Layouts"
        case .actionCombo: "Action Combos"
        case .scheduleTrigger: "Schedules"
        default: kind.rawValue.capitalized
        }
    }

    static func symbol(_ kind: DocumentKind) -> String {
        switch kind {
        case .theme: "paintpalette"
        case .presentation: "rectangle.on.rectangle"
        case .overlay: "square.stack"
        case .service: "list.bullet.rectangle"
        case .playlist: "music.note.list"
        case .confidenceLayout: "display"
        case .actionCombo: "square.grid.2x2"
        case .scheduleTrigger: "clock"
        default: "doc"
        }
    }

    public static func fileChanged(from old: MediaItem?, to new: MediaItem?) -> Bool {
        if let old, let new {
            old.fileHash != new.fileHash || old.inPoint != new.inPoint
        } else {
            false
        }
    }
}

public enum MediaPickCardLogic {
    public static func detail(
        kind: MediaKind, width: Int?, height: Int?, duration: Double?, missing: Bool
    ) -> String {
        if missing {
            return "Missing — the file isn't on this Mac"
        } else {
            let size = width.flatMap { w in height.map { h in "\(w) × \(h)" } }
            let length: String? = kind == .video ? duration.map(clock) : nil
            return ([kind == .video ? "Video" : "Image"] + [length, size].compactMap { $0 })
                .joined(separator: " · ")
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
