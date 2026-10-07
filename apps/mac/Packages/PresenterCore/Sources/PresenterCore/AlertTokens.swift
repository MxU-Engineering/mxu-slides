import Foundation

public enum AlertTokens {

    public static func tokenNames(in template: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for raw in rawTokens(in: template) {
            let name = String(raw)
            if seen.insert(name.lowercased()).inserted {
                names.append(name)
            }
        }
        return names
    }

    public static func compose(template: String, values: [String: String]) -> String {
        let lookup = Dictionary(
            values.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{",
               let close = template[index...].firstIndex(of: "}"),
               close > template.index(after: index) {
                let name = String(template[template.index(after: index) ..< close])
                if !name.contains("{") {
                    result += lookup[name.lowercased()] ?? ""
                    index = template.index(after: close)
                    continue
                }
            }
            result.append(template[index])
            index = template.index(after: index)
        }
        return result
    }

    private static func rawTokens(in template: String) -> [Substring] {
        var tokens: [Substring] = []
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{",
               let close = template[index...].firstIndex(of: "}"),
               close > template.index(after: index) {
                let name = template[template.index(after: index) ..< close]
                if !name.contains("{") {
                    tokens.append(name)
                    index = template.index(after: close)
                    continue
                }
            }
            index = template.index(after: index)
        }
        return tokens
    }
}
