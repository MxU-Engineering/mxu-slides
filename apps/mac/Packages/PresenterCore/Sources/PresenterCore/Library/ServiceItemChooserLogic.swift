import Foundation
import UniformTypeIdentifiers

@MainActor
public enum ServiceItemChooserLogic {
    public enum Tab: String, CaseIterable, Sendable {
        case library, importFile, new

        public var title: String {
            switch self {
            case .library: "Search Library"
            case .importFile: "Import File"
            case .new: "New"
            }
        }

        public var symbol: String {
            switch self {
            case .library: "magnifyingglass"
            case .importFile: "square.and.arrow.down"
            case .new: "plus"
            }
        }
    }

    public enum KindFilter: String, CaseIterable, Sendable {
        case all, slides, media

        public var title: String {
            switch self {
            case .all: "All"
            case .slides: "Slides"
            case .media: "Media"
            }
        }

        public func includes(_ kind: DocumentKind) -> Bool {
            switch self {
            case .all: [.presentation, .media, .audio].contains(kind)
            case .slides: kind == .presentation
            case .media: kind == .media || kind == .audio
            }
        }
    }

    public static func results(
        query: String, hits: [LibraryIndex.Hit], idle: [LibraryIndex.Entry], filter: KindFilter
    ) -> [LibraryIndex.Hit] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            idle.filter { filter.includes($0.kind) }
                .sorted { a, b in
                    switch (a.lastUsedAt, b.lastUsedAt) {
                    case let (usedA?, usedB?): usedA > usedB
                    case (.some, nil): true
                    case (nil, .some): false
                    case (nil, nil): a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }
                }
                .map { LibraryIndex.Hit(entry: $0, snippet: nil) }
        } else {
            hits.filter { filter.includes($0.entry.kind) }
        }
    }

    public static func steady(_ hits: [LibraryIndex.Hit], order: [String]) -> [LibraryIndex.Hit] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return hits.enumerated()
            .sorted { a, b in
                (rank[a.element.entry.id] ?? order.count + a.offset) < (rank[b.element.entry.id] ?? order.count + b.offset)
            }
            .map(\.element)
    }

    public enum ImportRoute: CaseIterable, Sendable {
        case slidesFile, proPresenter, powerPoint, lyrics, media
    }

    static let slidesFileExtensions: Set<String> = ["mxuslides"]
    static let proPresenterExtensions: Set<String> = ["pro", "probundle"]
    static let powerPointExtensions: Set<String> = ["pptx", "ppt"]

    static let lyricsExtensions: Set<String> = ["txt", "text", "cho", "chopro", "crd", "chordpro", "pdf"]

    public static func route(_ url: URL) -> ImportRoute? {
        let ext = url.pathExtension.lowercased()
        return if slidesFileExtensions.contains(ext) {
            .slidesFile
        } else if proPresenterExtensions.contains(ext) {
            .proPresenter
        } else if powerPointExtensions.contains(ext) {
            .powerPoint
        } else if lyricsExtensions.contains(ext) {
            .lyrics
        } else if MediaImporter.libraryKind(of: url) == .media {
            .media
        } else {
            nil
        }
    }

    public static func refusal(_ urls: [URL]) -> String? {
        urls.contains(where: { route($0) != nil })
            ? nil
            : "MxU Slides can't import " + urls.map(\.lastPathComponent).joined(separator: ", ")
    }

    public static var importTypes: [UTType] {
        [.image, .movie, .video]
            + (slidesFileExtensions.union(proPresenterExtensions).union(powerPointExtensions).union(lyricsExtensions))
                .sorted()
                .compactMap { UTType(filenameExtension: $0) }
    }
}
