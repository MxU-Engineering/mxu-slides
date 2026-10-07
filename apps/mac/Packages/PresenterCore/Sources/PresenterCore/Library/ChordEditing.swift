import Foundation

public enum ChordEditing {
    public static func revealed(_ objects: [SlideObject]) -> [SlideObject] {
        objects.map { object in
            if object.textLink == nil, !(object.chords ?? []).isEmpty {
                var revealed = object
                var style = revealed.textStyle ?? TextStyle()
                style.showChords = true
                style.chordNotation = .chords
                revealed.textStyle = style
                return revealed
            } else {
                return object
            }
        }
    }

    public static func clamped(line: Int, column: Int, in text: String) -> (line: Int, column: Int) {
        let lines = text.components(separatedBy: "\n")
        let clampedLine = min(max(line, 0), max(lines.count - 1, 0))
        let length = lines.indices.contains(clampedLine) ? lines[clampedLine].count : 0
        return (clampedLine, min(max(column, 0), length))
    }

    public static func adding(
        _ symbol: String, line: Int, column: Int, to chords: [ChordPlacement], text: String
    ) -> (chords: [ChordPlacement], index: Int?) {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return (chords, nil)
        } else {
            let anchor = clamped(line: line, column: column, in: text)
            return sortedTracking(chords + [ChordPlacement(line: anchor.line, column: anchor.column, symbol: trimmed)],
                                  index: chords.count)
        }
    }

    public static func setting(
        _ symbol: String, at index: Int, in chords: [ChordPlacement]
    ) -> (chords: [ChordPlacement], index: Int?) {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        if !chords.indices.contains(index) {
            return (chords, nil)
        } else if trimmed.isEmpty {
            return (removing(at: index, from: chords), nil)
        } else {
            var edited = chords
            edited[index].symbol = trimmed
            return (edited, index)
        }
    }

    public static func removing(at index: Int, from chords: [ChordPlacement]) -> [ChordPlacement] {
        var edited = chords
        if edited.indices.contains(index) { edited.remove(at: index) }
        return edited
    }

    public static func moving(
        at index: Int, toLine line: Int, column: Int, in chords: [ChordPlacement], text: String
    ) -> (chords: [ChordPlacement], index: Int?) {
        if chords.indices.contains(index) {
            let anchor = clamped(line: line, column: column, in: text)
            var edited = chords
            edited[index].line = anchor.line
            edited[index].column = anchor.column
            return sortedTracking(edited, index: index)
        } else {
            return (chords, nil)
        }
    }

    static func sortedTracking(_ chords: [ChordPlacement], index: Int) -> (chords: [ChordPlacement], index: Int?) {
        let order = chords.indices.sorted { a, b in
            (chords[a].line, chords[a].column, a) < (chords[b].line, chords[b].column, b)
        }
        return (order.map { chords[$0] }, order.firstIndex(of: index))
    }
}
