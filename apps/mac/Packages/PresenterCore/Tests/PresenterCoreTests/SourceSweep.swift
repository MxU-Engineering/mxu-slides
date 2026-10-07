import Foundation

struct SourceSweep {
    struct File {
        let url: URL
        let lines: [String]

        let codeLines: [String]

        let typeDeclarations: [(lines: ClosedRange<Int>, name: String)]

        init(url: URL, lines: [String]) {
            self.url = url
            self.lines = lines
            codeLines = lines.map(SourceSweep.code)
            var declarations: [(lines: ClosedRange<Int>, name: String)] = []
            for index in lines.indices {
                let trimmed = lines[index].drop { $0 == " " }
                guard let first = trimmed.first, first.isLetter || first == "@",
                      ["struct ", "class ", "enum ", "extension ", "actor "].contains(where: trimmed.contains),
                      let name = SourceSweep.typeName(declaredBy: String(trimmed))
                else { continue }
                declarations.append((index...index, name))
            }
            let code = codeLines
            typeDeclarations = declarations.map { declaration in
                (declaration.lines.lowerBound...SourceSweep.block(in: code, from: declaration.lines.lowerBound).upperBound,
                 declaration.name)
            }
        }

        var name: String { url.lastPathComponent }
        var text: String { lines.joined(separator: "\n") }

        func code(_ index: Int) -> String {
            codeLines[index]
        }

        func block(from start: Int) -> ClosedRange<Int> {
            SourceSweep.block(in: codeLines, from: start)
        }

        func opener(line: Int, column: Int) -> (line: Int, column: Int)? {
            var depth = 0
            var cursor = line
            var limit = column
            while cursor >= 0 {
                let characters = Array(code(cursor))
                var position = min(limit, characters.count) - 1
                while position >= 0 {
                    if characters[position] == "}" { depth += 1 }
                    if characters[position] == "{" {
                        if depth == 0 { return (cursor, position) }
                        depth -= 1
                    }
                    position -= 1
                }
                cursor -= 1
                limit = Int.max
            }
            return nil
        }

        func enclosingType(of index: Int) -> String? {
            typeDeclarations.last { $0.lines.contains(index) }?.name
        }

        func enclosingMember(of index: Int) -> String? {
            let pattern = /(?:(?:func|var)\s+([A-Za-z_][A-Za-z0-9_]*)|\b(init)\s*[(<])/
            var cursor = index
            while cursor >= 0 {
                let line = code(cursor)
                if line.hasPrefix("    "), !line.hasPrefix("        "),
                   let match = line.firstMatch(of: pattern) {
                    return String(match.1 ?? match.2 ?? "")
                }
                cursor -= 1
            }
            return nil
        }
    }

    let root: URL
    let files: [File]

    init(root: URL) throws {
        self.root = root
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        files = try all.filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
            .map { url in
                File(url: url, lines: try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            }
    }

    static func app() throws -> SourceSweep {
        let sweep = try appSources.get()
        guard !sweep.files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        return sweep
    }

    private static let appSources = Result {
        try SourceSweep(root: macRoot().appendingPathComponent("Sources", isDirectory: true))
    }

    static func macRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
    }

    func file(_ name: String) -> File? {
        files.first { $0.name == name }
    }

    var viewTypes: Set<String> {
        let pattern = /^\s*(?:private |fileprivate |public )?struct\s+([A-Za-z_][A-Za-z0-9_]*)(?:<[^>]*>)?\s*:\s*[^{]*\bView\b/
        return Set(files.flatMap { file in
            file.lines.compactMap { line in line.firstMatch(of: pattern).map { String($0.1) } }
        })
    }

    static func block(in code: [String], from start: Int) -> ClosedRange<Int> {
        var depth = 0
        var opened = false
        var cursor = start
        while cursor < code.count {
            for character in code[cursor] {
                if character == "{" { depth += 1; opened = true }
                if character == "}" { depth -= 1 }
            }
            if opened, depth <= 0 { break }
            cursor += 1
        }
        return start...min(cursor, code.count - 1)
    }

    static func typeName(declaredBy line: String) -> String? {
        let pattern = /^(?:@\w+\s+)*(?:private |fileprivate |public |final )*(?:struct|class|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_.]*)/
        return line.firstMatch(of: pattern).map { String($0.1) }
    }

    static func code(_ line: String) -> String {
        var result = ""
        var inString = false

        var interpolation: [Int] = []
        var previous: Character = " "
        for character in line {
            if let depth = interpolation.last {

                if character == "(" { interpolation[interpolation.count - 1] = depth + 1 }
                if character == ")" {
                    if depth == 0 {
                        interpolation.removeLast()
                        inString = true
                    } else {
                        interpolation[interpolation.count - 1] = depth - 1
                    }
                }
                result.append(character)
            } else if inString {
                if character == "(", previous == "\\" {
                    interpolation.append(0)
                    inString = false
                    result.append(character)
                } else if character == "\"", previous != "\\" {
                    inString = false
                    result.append(character)
                } else {
                    result.append(" ")
                }
            } else {
                if character == "/", previous == "/" {
                    result.removeLast()
                    break
                }
                if character == "\"" { inString = true }
                result.append(character)
            }
            previous = character
        }
        return result
    }
}
