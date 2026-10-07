import Foundation
import Testing

@testable import PresenterCore

@Suite struct IsolationEnforcementSweepTests {

    private var macRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
    }

    private var appSources: URL { macRoot.appendingPathComponent("Sources", isDirectory: true) }

    private func swiftFiles(under root: URL) throws -> [URL] {
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let files = all.filter { $0.pathExtension == "swift" && !$0.path.contains("automerge-swift") }
        try #require(!files.isEmpty, "sources not found at \(root.path)")
        return files
    }

    private func packageSources() throws -> [URL] {
        let packages = macRoot.appendingPathComponent("Packages", isDirectory: true)
        let roots = try FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "automerge-swift" }
            .map { $0.appendingPathComponent("Sources", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        try #require(roots.count >= 10, "package sources not found at \(packages.path)")
        return try roots.flatMap { try swiftFiles(under: $0) }
    }

    private func code(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .map { $0.components(separatedBy: " // ")[0] }
    }

    private func code(_ file: URL) throws -> [String] {
        code(try String(contentsOf: file, encoding: .utf8))
    }

    private func site(_ file: URL, _ index: Int) -> String {
        "\(file.path.replacingOccurrences(of: macRoot.path + "/", with: "")):\(index + 1)"
    }

    private let actorEscape = #/LibraryActor(\.shared)?\.assumeIsolated/#

    private let automergeImport = #/^\s*(@\w+\s+)*import\s+((typealias|struct|class|enum|protocol|let|var|func)\s+)?Automerge(?![A-Za-z0-9_])/#
    private let preconcurrencyImport = #/@preconcurrency\s+(@\w+\s+)*import(?![A-Za-z0-9_])/#

    private let documentDecode = #/AutomergeDecoder\(|(^|[^A-Za-z0-9_])Document\(data/#

    private let engineReach = #/(^|[^A-Za-z0-9_])(client|library)\.engine(?![A-Za-z0-9_])/#
    private let viewStoreReach = [".index.", "store.load(", "store.save("]

    private let actorEscapeExceptions: Set<String> = []

    @Test func nothingAssumesTheLibraryActor() throws {
        var violations: [String] = []
        var excused: Set<String> = []
        for file in try swiftFiles(under: appSources) + packageSources() {
            for (index, line) in try code(file).enumerated() where line.contains(actorEscape) {
                if actorEscapeExceptions.contains(file.lastPathComponent) {
                    excused.insert(file.lastPathComponent)
                } else {
                    violations.append(site(file, index))
                }
            }
        }
        let stale = actorEscapeExceptions.subtracting(excused)
        #expect(violations.isEmpty, "await the library actor: \(violations)")
        #expect(stale.isEmpty, "exceptions that match nothing any more — delete them: \(stale)")
    }

    private let importExceptions: Set<String> = []

    @Test func theAppImportsNoCRDTAndSilencesNoChecks() throws {
        var violations: [String] = []
        var excused: Set<String> = []
        for file in try swiftFiles(under: appSources) {
            for (index, line) in try code(file).enumerated()
            where line.contains(automergeImport) || line.contains(preconcurrencyImport) {
                if importExceptions.contains(file.lastPathComponent) {
                    excused.insert(file.lastPathComponent)
                } else {
                    violations.append(site(file, index))
                }
            }
        }
        let stale = importExceptions.subtracting(excused)
        #expect(violations.isEmpty, "values cross the boundary, documents do not: \(violations)")
        #expect(stale.isEmpty, "exceptions that match nothing any more — delete them: \(stale)")
    }

    private let decodingFiles: Set<String> = ["TypedDocument.swift", "DocumentStore.swift"]

    @Test func documentsDecodeInTwoFilesOnly() throws {
        var violations: [String] = []
        var decoders = 0
        for file in try swiftFiles(under: appSources) + packageSources() {
            for (index, line) in try code(file).enumerated() where line.contains(documentDecode) {
                if decodingFiles.contains(file.lastPathComponent) {
                    decoders += 1
                } else {
                    violations.append(site(file, index))
                }
            }
        }
        #expect(decoders > 0, "the sweep should see TypedDocument's decode")
        #expect(violations.isEmpty, "decode in TypedDocument.swift or DocumentStore.swift: \(violations)")
    }

    private let engineExceptions: Set<String> = []

    @Test func theAppDoesNotReachIntoTheEngine() throws {
        var violations: [String] = []
        var excused: Set<String> = []
        for file in try swiftFiles(under: appSources) {
            for (index, line) in try code(file).enumerated() where line.contains(engineReach) {
                if engineExceptions.contains(file.lastPathComponent) {
                    excused.insert(file.lastPathComponent)
                } else {
                    violations.append(site(file, index))
                }
            }
        }
        let stale = engineExceptions.subtracting(excused)
        #expect(violations.isEmpty, "go through the client: \(violations)")
        #expect(stale.isEmpty, "exceptions that match nothing any more — delete them: \(stale)")
    }

    private let viewStoreExceptions: Set<String> = []

    @Test func viewsAndModulesTouchNoIndexOrStore() throws {
        var scanned = 0
        var violations: [String] = []
        var excused: Set<String> = []
        for file in try swiftFiles(under: appSources) {
            let folder = file.deletingLastPathComponent().lastPathComponent
            if (folder == "Sources" && file.lastPathComponent.contains("View")) || folder == "Modules" {
                scanned += 1
                for (index, line) in try code(file).enumerated() where viewStoreReach.contains(where: { line.contains($0) }) {
                    if viewStoreExceptions.contains(file.lastPathComponent) {
                        excused.insert(file.lastPathComponent)
                    } else {
                        violations.append(site(file, index))
                    }
                }
            }
        }
        let stale = viewStoreExceptions.subtracting(excused)
        #expect(scanned >= 25, "sweep should see the app's views and modules (\(scanned))")
        #expect(violations.isEmpty, "read the snapshot and tables, write through the client: \(violations)")
        #expect(stale.isEmpty, "exceptions that match nothing any more — delete them: \(stale)")
    }

    @Test func theMatchersReadTheSpellings() {
        let text = """
            @preconcurrency import PresenterCore
            import Automerge
            @_exported import Automerge
            import struct Automerge.Document
            let decoder = AutomergeDecoder(doc: document)
            let document = try Document(data: bytes)
            LibraryActor.assumeIsolated { }
            let engine = model.client.engine
            // @preconcurrency import PresenterCore
            // import Automerge
            /// AutomergeDecoder(doc: document), try Document(data: bytes)
            let xml = try XMLDocument(data: data)
            import AutomergeKit
            """
        let lines = code(text)
        #expect(lines.filter { $0.contains(preconcurrencyImport) }.count == 1)
        #expect(lines.filter { $0.contains(automergeImport) }.count == 3, "not AutomergeKit")
        #expect(lines.filter { $0.contains(documentDecode) } == [
            "let decoder = AutomergeDecoder(doc: document)", "let document = try Document(data: bytes)",
        ])
        #expect(lines.filter { $0.contains(actorEscape) }.count == 1)
        #expect(lines.filter { $0.contains(engineReach) }.count == 1)
        #expect(!"player.engine.setMetering(true)".contains(engineReach), "an audio player's engine is not the library's")
    }
}
