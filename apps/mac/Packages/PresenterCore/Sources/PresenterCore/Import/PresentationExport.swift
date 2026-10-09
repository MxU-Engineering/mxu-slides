import CoreGraphics
import Foundation

public enum PresentationExport {
    public enum Format: String, CaseIterable, Sendable {
        case slidesFile
        case pdf
        case images
        case plainText
        case chordPro

        public var label: String {
            switch self {
            case .slidesFile: "MxU Slides Presentation (.\(SlidesPresentationFile.fileExtension))"
            case .pdf: "PDF (.pdf)"
            case .images: "Slide Images (PNG)"
            case .plainText: ChordProExport.FileFormat.plainText.label
            case .chordPro: ChordProExport.FileFormat.chordPro.label
            }
        }

        public var fileExtension: String? {
            switch self {
            case .slidesFile: SlidesPresentationFile.fileExtension
            case .pdf: "pdf"
            case .images: nil
            case .plainText: ChordProExport.FileFormat.plainText.rawValue
            case .chordPro: ChordProExport.FileFormat.chordPro.rawValue
            }
        }

        public var chordProFormat: ChordProExport.FileFormat? {
            switch self {
            case .plainText: .plainText
            case .chordPro: .chordPro
            default: nil
            }
        }

        public var rendersSlides: Bool { self == .pdf || self == .images }
    }

    public static func formats(for presentation: Presentation) -> [Format] {
        ChordProExport.isSong(presentation) ? Format.allCases : [.slidesFile, .pdf, .images]
    }

    public static func baseName(for presentation: Presentation) -> String {
        let name = sanitized(presentation.name)
        return name.isEmpty ? "Presentation" : name
    }

    public static func fileName(for presentation: Presentation, format: Format) -> String {
        if let chordPro = format.chordProFormat {
            ChordProExport.fileName(for: presentation, format: chordPro)
        } else {
            baseName(for: presentation) + (format.fileExtension.map { "." + $0 } ?? "")
        }
    }

    public static func fileName(
        for presentation: Presentation, format: Format, typed: String?
    ) -> String {
        if let typed, !typed.isEmpty {
            let known = Format.allCases.compactMap(\.fileExtension).map { "." + $0 }
            let base = known.first { typed.lowercased().hasSuffix($0) }.map { String(typed.dropLast($0.count)) } ?? typed
            return base + (format.fileExtension.map { "." + $0 } ?? "")
        } else {
            return fileName(for: presentation, format: format)
        }
    }

    public static func imageFileNames(labels: [String?]) -> [String] {
        let digits = max(2, String(labels.count).count)
        return labels.enumerated().map { index, label in
            let number = String(repeating: "0", count: max(0, digits - String(index + 1).count)) + String(index + 1)
            let name = label.map(sanitized) ?? ""
            return (name.isEmpty ? number : "\(number) \(name)") + ".png"
        }
    }

    private static func sanitized(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public struct Sheet: Equatable, Sendable {
        public static let margin: CGFloat = 36
        public static let titleHeight: CGFloat = 28
        public static let captionHeight: CGFloat = 14
        public static let columnRange = 1...6

        public var pageSize: CGSize
        public var columns: Int
        public var spacing: CGFloat

        public var aspect: CGFloat

        public init(pageSize: CGSize, columns: Int, spacing: CGFloat = 12, aspect: CGFloat) {
            self.pageSize = pageSize
            self.columns = min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
            self.spacing = spacing
            self.aspect = max(aspect, 0.01)
        }

        public var tileSize: CGSize {
            let usable = pageSize.width - 2 * Self.margin - CGFloat(columns - 1) * spacing
            let width = max(1, usable / CGFloat(columns))
            return CGSize(width: width, height: width / aspect)
        }

        public var cornerRadius: CGFloat {
            min(8, max(3, 8 * tileSize.width / 200))
        }

        private var rowHeight: CGFloat { tileSize.height + Self.captionHeight }

        private func rows(onFirstPage first: Bool) -> Int {
            let top = first ? Self.titleHeight : 0
            let usable = pageSize.height - 2 * Self.margin - top
            return max(1, Int((usable + spacing) / (rowHeight + spacing)))
        }

        public func pages(count: Int) -> [[CGRect]] {
            var pages: [[CGRect]] = []
            var placed = 0
            while placed < count {
                let first = pages.isEmpty
                let perPage = rows(onFirstPage: first) * columns
                let top = pageSize.height - Self.margin - (first ? Self.titleHeight : 0)
                let rects = (0..<min(perPage, count - placed)).map { slot in
                    let row = CGFloat(slot / columns)
                    let column = CGFloat(slot % columns)
                    return CGRect(
                        x: Self.margin + column * (tileSize.width + spacing),
                        y: top - row * (rowHeight + spacing) - tileSize.height,
                        width: tileSize.width, height: tileSize.height)
                }
                pages.append(rects)
                placed += rects.count
            }
            return pages
        }
    }
}
