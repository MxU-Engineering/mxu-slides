import Foundation
import PresenterCore

public enum PPTXNoteText {
    public static func body(ofFile url: URL) throws -> NoteBody {
        let root = try PPTXArchive.extract(url)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = PPTXPackage(root: root)
        var warnings: [String] = []
        let parsed = try PPTXPresentationParser.parse(in: package, warnings: &warnings)
        let slides = try parsed.slidePartPaths.map {
            try PPTXSlideParser.parse(partPath: $0, presentationPart: parsed.partPath, in: package, warnings: &warnings)
        }
        return NoteFileReader.body(lines: lines(of: slides))
    }

    static func lines(of slides: [PPTXSlide]) -> [NoteFileReader.Line] {
        slides.flatMap { slide in
            slide.shapes
                .filter { $0.textBody != nil }
                .sorted { ($0.transform.offYEMU, $0.transform.offXEMU) < ($1.transform.offYEMU, $1.transform.offXEMU) }
                .flatMap { shape -> [NoteFileReader.Line] in
                    let heading: Int? = switch shape.placeholderType {
                    case "ctrTitle": 1
                    case "title": 2
                    default: nil
                    }
                    return (shape.textBody?.lines ?? []).map { line in
                        NoteFileReader.Line(runs: line.runs.map { run in
                            NoteRun(text: run.text, bold: run.bold ? true : nil, italic: run.italic ? true : nil,
                                    underline: run.underline ? true : nil, strike: run.strike ? true : nil)
                        }, heading: heading)
                    }
                }
        }
    }
}
