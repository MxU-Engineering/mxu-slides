import Foundation

public enum ChordMath {

    public struct Symbol: Equatable, Sendable {
        public var root: String
        public var suffix: String
        public var bass: String?

        public init(root: String, suffix: String = "", bass: String? = nil) {
            self.root = root
            self.suffix = suffix
            self.bass = bass
        }

        public var formatted: String {
            root + suffix + (bass.map { "/" + $0 } ?? "")
        }
    }

    public static func parseSymbol(_ text: String) -> Symbol? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = symbolRegex.firstMatch(
            in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)
        ) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: trimmed),
                  !trimmed[range].isEmpty else { return nil }
            return String(trimmed[range])
        }
        guard let root = group(1) else { return nil }
        return Symbol(root: root, suffix: group(2) ?? "", bass: group(3))
    }

    public static func isChordToken(_ text: String) -> Bool {
        parseSymbol(text) != nil
    }

    public static func parseKey(_ key: String) -> (pitchClass: Int, isMinor: Bool)? {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first,
              let base = naturalPitchClasses[Character(first.uppercased())]
        else { return nil }
        var rest = String(trimmed.dropFirst())
        var pitch = base
        if rest.hasPrefix("#") { pitch += 1; rest.removeFirst() }
        else if rest.hasPrefix("b") { pitch -= 1; rest.removeFirst() }
        let mode = rest.lowercased()
        guard mode.isEmpty || mode == "m" || mode == "min" || mode == "minor"
        else { return nil }
        return ((pitch + 12) % 12, !mode.isEmpty)
    }

    public static func keyChoices(matching musicKey: String) -> [String] {
        let minor = parseKey(musicKey)?.isMinor ?? false
        let names = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return minor ? names.map { $0 + "m" } : names
    }

    public static func hasChords(in presentation: Presentation) -> Bool {
        presentation.slides.contains { slide in
            slide.objects.contains { !($0.chords ?? []).isEmpty }
        }
    }

    public static func displayKey(playing playedKey: String, musicKey: String) -> String? {
        guard let played = parseKey(playedKey), let written = parseKey(musicKey) else { return nil }
        var pitch = played.pitchClass
        if played.isMinor != written.isMinor {
            pitch = (pitch + (played.isMinor ? 3 : 9)) % 12
        }
        return keyChoices(matching: musicKey).first { parseKey($0)?.pitchClass == pitch }
    }

    public static func transposeInterval(musicKey: String?, displayKey: String?) -> Int? {
        guard let source = musicKey.flatMap(parseKey),
              let target = displayKey.flatMap(parseKey)
        else { return nil }
        return (target.pitchClass - source.pitchClass + 12) % 12
    }

    public static func display(
        _ symbol: String,
        musicKey: String?,
        displayKey: String?,
        notation: ChordNotation
    ) -> String {
        guard let parsed = parseSymbol(symbol) else { return symbol }
        let interval = transposeInterval(musicKey: musicKey, displayKey: displayKey) ?? 0
        let keyName = displayKey ?? musicKey
        switch notation {
        case .chords:
            guard interval != 0, let keyName else { return parsed.formatted }
            return transpose(parsed, by: interval, spelledFor: keyName).formatted
        case .numbers, .numerals, .doReMi:

            guard let musicKey, let tonic = parseKey(musicKey) else {
                return display(symbol, musicKey: nil, displayKey: displayKey, notation: .chords)
            }
            return degreeNotation(parsed, tonic: tonic.pitchClass, notation: notation)
        }
    }

    public static func displayPlacements(
        _ chords: [ChordPlacement],
        musicKey: String?,
        displayKey: String?,
        notation: ChordNotation
    ) -> [ChordPlacement] {
        chords.map { placement in
            var out = placement
            out.symbol = display(
                placement.symbol,
                musicKey: musicKey, displayKey: displayKey, notation: notation
            )
            return out
        }
    }

    static func transpose(_ symbol: Symbol, by interval: Int, spelledFor keyName: String) -> Symbol {
        let sharps = prefersSharps(keyName)
        var out = symbol
        if let root = parseKey(symbol.root) {
            out.root = spell((root.pitchClass + interval) % 12, sharps: sharps)
        }
        if let bassText = symbol.bass, let bass = parseKey(bassText) {
            out.bass = spell((bass.pitchClass + interval) % 12, sharps: sharps)
        }
        return out
    }

    static func prefersSharps(_ keyName: String) -> Bool {
        if keyName.dropFirst().hasPrefix("#") { return true }
        if keyName.dropFirst().hasPrefix("b") { return false }
        guard let key = parseKey(keyName) else { return true }
        let majorTonic = key.isMinor ? (key.pitchClass + 3) % 12 : key.pitchClass
        return ![5, 10, 3, 8, 1, 6].contains(majorTonic) 
    }

    static func spell(_ pitchClass: Int, sharps: Bool) -> String {
        let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
        return (sharps ? sharpNames : flatNames)[(pitchClass + 12) % 12]
    }

    static func degreeNotation(_ symbol: Symbol, tonic: Int, notation: ChordNotation) -> String {
        guard let root = parseKey(symbol.root) else { return symbol.formatted }
        let rootDegree = degree(of: root.pitchClass, tonic: tonic)
        let bassDegree = symbol.bass.flatMap(parseKey).map {
            degree(of: $0.pitchClass, tonic: tonic)
        }
        switch notation {
        case .numbers:
            var out = rootDegree.accidental + String(rootDegree.number) + symbol.suffix
            if let bassDegree { out += "/" + bassDegree.accidental + String(bassDegree.number) }
            return out
        case .numerals:
            let numerals = ["I", "II", "III", "IV", "V", "VI", "VII"]
            let minor = isMinorQuality(symbol.suffix)
            var numeral = numerals[rootDegree.number - 1]
            if minor { numeral = numeral.lowercased() }

            var out = rootDegree.accidental + numeral + strippingMinorMark(symbol.suffix)
            if let bassDegree {
                out += "/" + bassDegree.accidental + numerals[bassDegree.number - 1]
            }
            return out
        case .doReMi:
            var out = solfege(rootDegree) + symbol.suffix
            if let bassDegree { out += "/" + solfege(bassDegree) }
            return out
        case .chords:
            return symbol.formatted
        }
    }

    static func degree(of pitchClass: Int, tonic: Int) -> (number: Int, accidental: String) {
        let interval = (pitchClass - tonic + 12) % 12
        let majorScale = [0, 2, 4, 5, 7, 9, 11]
        if let index = majorScale.firstIndex(of: interval) {
            return (index + 1, "")
        }
        if interval == 6 { return (4, "#") }

        let upper = majorScale.firstIndex(where: { $0 > interval })! + 1
        return (upper, "b")
    }

    static func solfege(_ degree: (number: Int, accidental: String)) -> String {
        let natural = ["Do", "Re", "Mi", "Fa", "Sol", "La", "Ti"]
        let lowered = ["Do", "Ra", "Me", "Fa", "Se", "Le", "Te"]
        let raised = ["Di", "Ri", "Fi", "Fi", "Si", "Li", "Ti"]
        switch degree.accidental {
        case "b": return lowered[degree.number - 1]
        case "#": return raised[degree.number - 1]
        default: return natural[degree.number - 1]
        }
    }

    static func isMinorQuality(_ suffix: String) -> Bool {
        if suffix.hasPrefix("maj") { return false }
        return suffix.hasPrefix("m") || suffix.hasPrefix("min")
            || suffix.hasPrefix("dim") || suffix.hasPrefix("°")
    }

    static func strippingMinorMark(_ suffix: String) -> String {
        if suffix.hasPrefix("maj") { return suffix }
        if suffix.hasPrefix("min") { return String(suffix.dropFirst(3)) }
        if suffix.hasPrefix("m") { return String(suffix.dropFirst(1)) }
        return suffix
    }

    public static func extractLine(_ line: String) -> (text: String, chords: [(column: Int, symbol: String)]) {
        var text = ""
        var chords: [(column: Int, symbol: String)] = []
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "[") {
            text += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "]") else {
                text += rest[open...]
                rest = Substring("")
                break
            }
            let token = String(rest[afterOpen..<close])
            if isChordToken(token) {
                chords.append((column: text.count, symbol: token.trimmingCharacters(in: .whitespaces)))
            } else {
                text += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        text += rest
        return (text, chords)
    }

    public static func extract(_ text: String) -> (text: String, chords: [ChordPlacement]) {
        var cleanLines: [String] = []
        var placements: [ChordPlacement] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let extracted = extractLine(line)
            cleanLines.append(extracted.text)
            placements.append(contentsOf: extracted.chords.map {
                ChordPlacement(line: index, column: $0.column, symbol: $0.symbol)
            })
        }
        return (cleanLines.joined(separator: "\n"), placements)
    }

    public static func bracketed(_ text: String, chords: [ChordPlacement]) -> String {
        var lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        let byLine = Dictionary(grouping: chords, by: \.line)
        for (lineIndex, placements) in byLine {
            while lines.count <= lineIndex { lines.append("") }
            var line = lines[lineIndex]

            for placement in placements.sorted(by: { ($0.column, $0.symbol) > ($1.column, $1.symbol) }) {
                let column = min(max(0, placement.column), line.count)
                let at = line.index(line.startIndex, offsetBy: column)
                line.insert(contentsOf: "[\(placement.symbol)]", at: at)
            }
            lines[lineIndex] = line
        }
        return lines.joined(separator: "\n")
    }

    static let naturalPitchClasses: [Character: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11,
    ]

    static let symbolRegex = try! NSRegularExpression(
        pattern: "^([A-G][#b]?)((?:maj|min|dim|aug|sus|add|[mM0-9()#b+°ø*Δ-])*)(?:/([A-G][#b]?))?$"
    )
}
