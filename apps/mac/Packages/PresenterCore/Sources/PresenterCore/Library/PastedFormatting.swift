import Foundation

public enum PastedFormatting {

    public struct Span: Equatable, Sendable {
        public var location: Int
        public var length: Int
        public var fontName: String?
        public var underline: Bool?
        public var strikethrough: Bool?

        public init(location: Int, length: Int, fontName: String? = nil, underline: Bool? = nil, strikethrough: Bool? = nil) {
            self.location = location
            self.length = length
            self.fontName = fontName
            self.underline = underline
            self.strikethrough = strikethrough
        }

        var isPlain: Bool { fontName == nil && underline == nil && strikethrough == nil }
    }

    public static func apply(
        _ spans: [Span], pastedAtUTF16 pasteUTF16Location: Int,
        to runs: [TextStyleRun], in text: String
    ) -> [TextStyleRun] {
        spans.reduce(runs) { current, span in
            guard !span.isPlain, span.length > 0 else { return current }
            let range = TextStyleRuns.characterRange(
                fromUTF16: pasteUTF16Location + span.location, length: span.length, in: text)
            guard !range.isEmpty else { return current }
            return TextStyleRuns.applying({ run in
                if let fontName = span.fontName { run.fontName = fontName }
                if let underline = span.underline { run.underline = underline }
                if let strikethrough = span.strikethrough { run.strikethrough = strikethrough }
            }, to: current, in: text, selection: range)
        }
    }
}
