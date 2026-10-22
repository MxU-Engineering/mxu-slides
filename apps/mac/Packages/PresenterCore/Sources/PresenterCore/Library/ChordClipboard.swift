import Foundation

public enum ChordClipboard {
    public static let type = "io.prodcontrol.mxupresenter.text-chords"

    public struct Payload: Codable, Equatable, Sendable {

        public var text: String

        public var chords: [ChordPlacement]

        public init(text: String, chords: [ChordPlacement]) {
            self.text = text
            self.chords = chords
        }
    }

    public static func copying(_ selection: Range<Int>, of text: String, chords: [ChordPlacement]) -> Payload? {
        let characters = Array(text)
        let lower = min(max(0, selection.lowerBound), characters.count)
        let upper = min(max(lower, selection.upperBound), characters.count)
        let copied = String(characters[lower..<upper])
        let starts = lineStarts(of: text)
        let lines = text.components(separatedBy: "\n")
        let inside: [ChordPlacement] = chords.compactMap { chord in
            if lines.indices.contains(chord.line) {
                let position = starts[chord.line] + min(max(0, chord.column), lines[chord.line].count)
                if position >= lower, position < upper {
                    let anchor = anchor(at: position - lower, in: copied)
                    return ChordPlacement(line: anchor.line, column: anchor.column, symbol: chord.symbol)
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return inside.isEmpty ? nil : Payload(text: copied, chords: inside)
    }

    public static func pasting(
        _ payload: Payload, at position: Int, into text: String, chords existing: [ChordPlacement]
    ) -> [ChordPlacement] {
        let starts = lineStarts(of: payload.text)
        let lines = payload.text.components(separatedBy: "\n")
        let pasted: [ChordPlacement] = payload.chords.compactMap { chord in
            if lines.indices.contains(chord.line) {
                let offset = starts[chord.line] + min(max(0, chord.column), lines[chord.line].count)
                let anchor = anchor(at: position + offset, in: text)
                return ChordPlacement(line: anchor.line, column: anchor.column, symbol: chord.symbol)
            } else {
                return nil
            }
        }
        return ChordEditing.sortedTracking(existing + pasted, index: 0).chords
    }

    private static func lineStarts(of text: String) -> [Int] {
        var starts: [Int] = []
        var running = 0
        for line in text.components(separatedBy: "\n") {
            starts.append(running)
            running += line.count + 1
        }
        return starts
    }

    private static func anchor(at position: Int, in text: String) -> (line: Int, column: Int) {
        let starts = lineStarts(of: text)
        let line = starts.lastIndex(where: { $0 <= max(0, position) }) ?? 0
        return ChordEditing.clamped(line: line, column: position - starts[line], in: text)
    }
}
