import Foundation

public enum PPTXNotesExtractor {

    public static func extractText(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let root = try PPTXArchive.extract(url)
        defer { try? FileManager.default.removeItem(at: root) }

        let package = PPTXPackage(root: root)
        var warnings: [String] = []
        let presentation = try PPTXPresentationParser.parse(in: package, warnings: &warnings)
        let slides = try presentation.slidePartPaths.map { part in
            try PPTXSlideParser.parse(
                partPath: part, presentationPart: presentation.partPath,
                in: package, warnings: &warnings)
        }
        let text = slides.map { slide in
            slide.shapes.compactMap { shape -> String? in
                guard let body = shape.textBody else { return nil }
                let text = body.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        guard !text.isEmpty else {
            throw PPTXImportError.invalidPackage("the presentation did not contain readable slide text")
        }
        return text
    }
}
