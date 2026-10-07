import Foundation
import Testing

@testable import PresenterCore

@Suite struct ValueDecodeDoorSweepTests {
    private var macRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
    }

    private var sourceRoots: [URL] {
        [
            macRoot.appendingPathComponent("Sources", isDirectory: true),
            macRoot.appendingPathComponent("Packages/PresenterCore/Sources", isDirectory: true),
        ]
    }

    private func swiftFiles() throws -> [URL] {
        let files = sourceRoots.flatMap { root in
            (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension == "swift" }
        }
        try #require(files.count > 100, "sources not found under \(macRoot.path)")
        return files
    }

    private func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func code(_ line: String) -> String {
        line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    private let taskDecodeAllowlist: [(file: String, token: String)] = []

    private let taskStart = #/\bTask(\.detached)?\s*[({]/#

    private func taskDecodes(_ lines: [String], fileName: String) -> (tasks: Int, violations: [(site: String, line: String)]) {
        var tasks = 0
        var violations: [(site: String, line: String)] = []
        for (index, line) in lines.enumerated() where code(line).contains(taskStart) {
            tasks += 1

            var depth = 0
            var started = false
            var cursor = index
            while cursor < lines.count {
                let text = code(lines[cursor])
                for character in text {
                    if character == "{" { depth += 1; started = true }
                    if character == "}" { depth -= 1 }
                }
                if text.contains("store.load(") {
                    violations.append(("\(fileName):\(cursor + 1)", text))
                }
                if started, depth <= 0 { break }
                cursor += 1
            }
        }
        return (tasks, violations)
    }

    @Test func tasksDecodeThroughTheValueDoor() throws {
        var tasks = 0
        var violations: [String] = []
        var matched: Set<String> = []
        for file in try swiftFiles() {
            let found = taskDecodes(try lines(of: file), fileName: file.lastPathComponent)
            tasks += found.tasks
            for violation in found.violations {
                let allowed = taskDecodeAllowlist.first {
                    violation.site.hasPrefix("\($0.file):") && violation.line.contains($0.token)
                }
                if let allowed {
                    matched.insert("\(allowed.file) \(allowed.token)")
                } else {
                    violations.append(violation.site)
                }
            }
        }
        let stale = taskDecodeAllowlist.map { "\($0.file) \($0.token)" }.filter { !matched.contains($0) }
        #expect(tasks >= 100, "sweep should see the app's tasks (\(tasks))")
        #expect(violations.isEmpty, "decode through store.loadValue/loadReplicaParts/loadValues: \(violations)")
        #expect(stale.isEmpty, "allowlist entries that match nothing any more — delete them: \(stale)")
    }

    @Test func theScanCatchesALoadInATaskAndPassesTheDoor() {
        let spellings = [
            "func fill() {",
            "    Task.detached(priority: .userInitiated) {",
            "        let document = try? store.load(Presentation.self, id: id)",
            "    }",
            "    Task { @MainActor [weak self] in",
            "        _ = try? model.library.store.load(Theme.self, id: id)",
            "    }",
            "    Task(priority: .utility) { [weak self] in",
            "        let value = try? await store.loadValue(Theme.self, id: id)",
            "        let values = await store.loadValues(Theme.self, ids: ids).values",
            "        let parts = try? await store.loadReplicaParts(Presentation.self, id: id)",
            "    }",
            "    group.addTask { (id, decode(type, id: id)) }",
            "    let direct = try? store.load(Theme.self, id: id)",
            "}",
        ]
        let found = taskDecodes(spellings, fileName: "Fixture.swift")
        #expect(found.tasks == 3)
        #expect(found.violations.map(\.site) == ["Fixture.swift:3", "Fixture.swift:6"])
    }

    @Test func noChangeMessageHookRemains() throws {
        var found: [String] = []
        for file in try swiftFiles() {
            for (index, line) in try lines(of: file).enumerated() where line.contains("changeMessage") {
                found.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(found.isEmpty, "an open stamps Library.author (ChangeAuthor), never a hook: \(found)")
    }

    @Test func theDoorAndItsWorkersAreConcurrent() throws {
        let declarations: [(file: String, signature: String, count: Int)] = [
            ("DocumentStore.swift", "func loadValue<", 1),
            ("DocumentStore.swift", "func loadReplicaParts<", 2),
            ("DocumentStore.swift", "func loadValues<", 2),
            ("ResidentTable.swift", "func fillResidentTable<", 2),
            ("LibraryReader.swift", "func fillResidentTable<", 1),
            ("LibraryClient.swift", "func fillResidentTable<", 1),
            ("AppModel.swift", "static func mediaReferenceSets(", 1),
        ]
        let files = try swiftFiles()
        for declaration in declarations {
            let file = try #require(files.first { $0.lastPathComponent == declaration.file })
            let source = try lines(of: file)
            let sites = source.indices.filter { source[$0].contains(declaration.signature) }
            #expect(sites.count == declaration.count, "\(declaration.file) \(declaration.signature)")
            for site in sites {
                let attributes = source[..<site].last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                #expect(
                    attributes.contains("@concurrent"),
                    "\(declaration.file):\(site + 1) \(declaration.signature) is not @concurrent"
                )
            }
        }
    }
}
