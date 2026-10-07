import Foundation
import Testing

@Suite struct AnimationVocabularySweepTests {

    private var macRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
    }

    @Test func productionCodeNeverSpeaksBuildVocabulary() throws {

        let bannedTypes = [
            "BuildStep", "BuildKind", "BuildTrigger", "BuildAnimation",
            "BuildRamp", "BuildEdge", "BuildRange", "BuildPreset",
            "BuildSequence", "BuildEvaluator", "BuildTimeline", "BuildContext",
            "BuildVisibility", "BuildMotion", "PlaceholderBuilds", "BuildsInspector",
        ]

        let bannedMembers = [
            ".builds", "buildOrder", "includeBuilds", "builds-drive",
        ]
        let sanctioned = [
            "SlideObjectNormalization.swift", "AnimationVocabularyMigration.swift",
            "Models.swift",
        ]

        var roots = [macRoot.appendingPathComponent("Sources", isDirectory: true)]
        let packages = macRoot.appendingPathComponent("Packages", isDirectory: true)
        for package in try FileManager.default.contentsOfDirectory(
            at: packages, includingPropertiesForKeys: nil
        ) {
            roots.append(package.appendingPathComponent("Sources", isDirectory: true))
        }

        var violations: [String] = []
        var scanned = 0
        for root in roots {
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                guard !sanctioned.contains(file.lastPathComponent),
                      !file.pathComponents.contains("Generated"),
                      !file.pathComponents.contains(".build")
                else { continue }
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in text.split(
                    separator: "\n", omittingEmptySubsequences: false
                ).enumerated() {
                    for pattern in bannedTypes + bannedMembers where line.contains(pattern) {
                        violations.append(
                            "\(file.lastPathComponent):\(index + 1) — \(pattern)")
                    }
                }
            }
        }
        #expect(scanned > 100, "the sweep must actually find the sources")
        #expect(violations.isEmpty, "\(violations)")
    }
}
