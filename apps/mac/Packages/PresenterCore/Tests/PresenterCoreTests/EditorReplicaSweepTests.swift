import Foundation
import Testing

@testable import PresenterCore

@Suite struct EditorReplicaSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private var coreSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let files = all.filter { $0.pathExtension == "swift" && !$0.path.contains("automerge-swift") }
        try #require(!files.isEmpty, "sources not found at \(root.path)")
        return files
    }

    private func code(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .map { $0.components(separatedBy: " // ")[0] }
    }

    private func editorFiles() throws -> [URL] {
        let files = try swiftFiles(under: appSources).filter { $0.lastPathComponent.hasPrefix("SlideEditorModel") }
        try #require(files.contains { $0.lastPathComponent == "SlideEditorModel.swift" })
        return files
    }

    private func calls(of callee: String, in text: String) -> [String] {
        var found: [String] = []
        var from = text.startIndex
        while let start = text.range(of: callee, range: from..<text.endIndex) {
            var depth = 1
            var cursor = start.upperBound
            while depth > 0, cursor < text.endIndex {
                if text[cursor] == "(" { depth += 1 }
                if text[cursor] == ")" { depth -= 1 }
                cursor = text.index(after: cursor)
            }
            found.append(String(text[start.lowerBound..<cursor]))
            from = cursor
        }
        return found
    }

    @Test func theEditorHoldsReplicasNotDocuments() throws {
        var editor = ""
        for file in try editorFiles() {
            let lines = try code(file)
            for (index, line) in lines.enumerated() where line.contains("TypedDocument<") {
                Issue.record("\(file.lastPathComponent):\(index + 1) holds a TypedDocument")
            }
            editor += lines.joined(separator: "\n")
        }
        for host in ["Presentation", "Theme", "Overlay", "ConfidenceLayout"] {
            #expect(editor.contains("EditorReplica<\(host)>"), "the \(host) host is an EditorReplica")
        }
    }

    private let goneFromTheApp = [
        "liveEditor", "mergeIntoLiveEditor", "mergeFile(", "cloudLanded", "mergeLanded", ".loadDocument(",
        "presentationDocuments", "takePrewarmedPresentationDocument", "prewarmDocument", "keepPresentationDocument",
    ]

    @Test func theOldEditorPathIsGone() throws {
        var found: [String] = []
        for file in try swiftFiles(under: appSources) {
            for (index, line) in try code(file).enumerated() {
                for spelling in goneFromTheApp where line.contains(spelling) {
                    found.append("\(file.lastPathComponent):\(index + 1) \(spelling)")
                }
            }
        }
        #expect(found.isEmpty, "the editor checks out, hears bundles and warms on the actor: \(found)")

        var core: [String] = []
        for file in try swiftFiles(under: coreSources) {
            let lines = try code(file)
            let client = ["LibraryClient.swift", "LibraryReader.swift"].contains(file.lastPathComponent)
            for (index, line) in lines.enumerated() where line.contains("mergeLanded") || (client && line.contains("loadDocument")) {
                core.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(core.isEmpty, "no whole-document merge and no private copy for the editor in Core: \(core)")
    }

    private let escapeExceptions: [String: String] = [:]

    @Test func nothingBesideAReplicaCrossesUnchecked() throws {
        let escapes = ["@unchecked Sendable", "nonisolated(unsafe)", "assumeIsolated"]
        var scanned = 0
        var violations: [String] = []
        var excused: Set<String> = []
        for file in try swiftFiles(under: appSources) + swiftFiles(under: coreSources) {
            let lines = try code(file)
            if lines.contains(where: { $0.contains("EditorReplica") || $0.contains("TypedDocument") }) {
                scanned += 1
                for (index, line) in lines.enumerated() {
                    for escape in escapes where line.contains(escape) {
                        if escapeExceptions[file.lastPathComponent] != nil {
                            excused.insert(file.lastPathComponent)
                        } else {
                            violations.append("\(file.lastPathComponent):\(index + 1) \(escape)")
                        }
                    }
                }
            }
        }
        let stale = escapeExceptions.keys.filter { !excused.contains($0) }
        #expect(scanned >= 10, "sweep should see the files that hold replicas (\(scanned))")
        #expect(violations.isEmpty, "\(violations)")
        #expect(stale.isEmpty, "exceptions that match nothing any more — delete them: \(stale)")
    }

    @Test func commitsNameTheSessionAndReleaseParksTheHistory() throws {
        let editor = try editorFiles().map { try code($0).joined(separator: "\n") }.joined(separator: "\n")
        let commits = calls(of: "client.commit(", in: editor)
        #expect(!commits.isEmpty, "the editor commits through the library client")
        for commit in commits {
            #expect(commit.contains("token:"), "a commit without its session: \(commit)")
        }
        let releases = calls(of: "client.release(", in: editor)
        #expect(!releases.isEmpty, "the editor releases its session")
        for release in releases {
            #expect(release.contains("token:"), "a release names its session: \(release)")
        }

        #expect(releases.contains { $0.contains("token: token, history: history") }, "endSession parks the history")
    }

    @Test func theDeckHostNeverWritesTheWholeValue() throws {
        let editor = try editorFiles().map { try code($0).joined(separator: "\n") }.joined(separator: "\n")
        let marker = "case .presentation(let document):"
        let cases = editor.components(separatedBy: marker).dropFirst().map { body in
            String(body.components(separatedBy: "\n            case .")[0].components(separatedBy: "\n        case .")[0])
        }
        #expect(cases.count >= 6, "the deck cases were found (\(cases.count))")
        for body in cases {
            let flat = body.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
            for whole in [".update(mutate)", ".update {", ".update{"] {
                #expect(!flat.contains(whole), "a deck case writes the whole value: \(body.prefix(160))")
            }
        }
        #expect(cases.contains { $0.contains("document.updateDeck(mutate)") && $0.contains("noteWholeWrite(document)") }, "structural edits go through updateDeck")
        #expect(cases.filter { $0.contains("document.undo()") || $0.contains("document.redo()") }.allSatisfy { $0.contains("noteWholeWrite(document)") })
        #expect(editor.contains("\"editor.wholeWrite\""), "the fallback is a breadcrumb")
    }

    @Test func theCallScanReadsAWrappedCallWhole() {
        let text = """
            appModel.client.commit(
                E.self, id: replica.value.id, changes: changes(since: SyncLedger.heads(lastCommitted)),
                token: token
            )
            appModel.client.commit(Theme.self, id: themeID, changes: scaffold)
            """
        let found = calls(of: "client.commit(", in: text)
        #expect(found.count == 2)
        #expect(found.first?.hasSuffix("token: token\n)") == true)
        #expect(found.last == "client.commit(Theme.self, id: themeID, changes: scaffold)")
    }
}
