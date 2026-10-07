import Foundation
import Testing

@Suite struct AdvanceVerbSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func everyAdvanceShapedEntryPointGoesThroughTheOneVerb() throws {

        let entryPoints = ["func fireStep(", "func advance(steps"]

        let sanctioned: Set<String> = ["ServiceControls.swift"]
        var violations: [String] = []
        var found = 0
        guard let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) else {
            Issue.record("app sources not found at \(appSources.path)")
            return
        }
        for case let file as URL in files where file.pathExtension == "swift" {
            guard !sanctioned.contains(file.lastPathComponent) else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                guard entryPoints.contains(where: { line.contains($0) }) else { continue }
                found += 1

                var body: [String] = []
                for later in lines[(index + 1)...] {
                    if later.hasPrefix("    }") || later.hasPrefix("}") { break }
                    body.append(later)
                }
                let text = body.joined(separator: "\n")
                let firesSlide = text.contains("fire(") || text.contains("advanceSlide(")
                if firesSlide, !text.contains(".advance(steps:") {
                    violations.append("\(file.lastPathComponent):\(index + 1) fires without the advance verb")
                }
            }
        }
        #expect(found >= 3, "grid keys, run-order keys and the API bridge must be found (\(found))")
        #expect(violations.isEmpty, "\(violations)")
    }
}
