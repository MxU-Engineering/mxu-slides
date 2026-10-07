import Foundation

public enum TimerPattern {

    public static func text(_ seconds: TimeInterval, pattern: String) -> String {
        let magnitude = abs(seconds)
        let whole = Int(magnitude.rounded(.towardZero))
        let body = pieces(in: pattern).map { piece -> String in
            switch piece {
            case .literal(let text): text
            case .token(let letter, let width): field(letter, width: width, whole: whole, magnitude: magnitude)
            }
        }.joined()

        let negative = seconds < 0 && (whole > 0 || hasFraction(pattern))
        return negative ? "-" + body : body
    }

    public static func hasFraction(_ pattern: String) -> Bool {
        pieces(in: pattern).contains {
            if case .token("f", _) = $0 { return true } else { return false }
        }
    }

    private enum Piece: Equatable {
        case literal(String)
        case token(Character, Int)
    }

    private static let tokenLetters: Set<Character> = ["d", "h", "m", "s", "H", "M", "S", "f"]

    private static func pieces(in pattern: String) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        var quoted = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let char = pattern[index]
            let next = pattern.index(after: index)
            if char == "'" {
                if next < pattern.endIndex, pattern[next] == "'" {
                    literal.append("'")
                    index = pattern.index(after: next)
                } else {
                    quoted.toggle()
                    index = next
                }
            } else if quoted || !tokenLetters.contains(char) {
                literal.append(char)
                index = next
            } else {
                if !literal.isEmpty {
                    pieces.append(.literal(literal))
                    literal = ""
                }
                var end = index
                while end < pattern.endIndex, pattern[end] == char {
                    end = pattern.index(after: end)
                }
                pieces.append(.token(char, pattern.distance(from: index, to: end)))
                index = end
            }
        }
        if !literal.isEmpty {
            pieces.append(.literal(literal))
        }
        return pieces
    }

    private static func field(_ letter: Character, width: Int, whole: Int, magnitude: TimeInterval) -> String {
        switch letter {
        case "d": return padded(whole / 86400, width)
        case "h": return padded((whole / 3600) % 24, width)
        case "m": return padded((whole / 60) % 60, width)
        case "s": return padded(whole % 60, width)
        case "H": return padded(whole / 3600, width)
        case "M": return padded(whole / 60, width)
        case "S": return padded(whole, width)
        case "f": return fraction(magnitude - Double(whole), digits: min(width, 3))
        default: return ""
        }
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        width > 1 ? String(format: "%0\(width)d", value) : String(value)
    }

    private static func fraction(_ part: Double, digits: Int) -> String {
        let scale = Int(pow(10.0, Double(digits)))
        let value = min(scale - 1, Int((part * Double(scale) + 1e-6).rounded(.towardZero)))
        return String(format: "%0\(digits)d", value)
    }
}
