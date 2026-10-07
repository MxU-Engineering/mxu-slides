import Foundation
import Testing

@Suite struct KindScopedEpochSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func lines(of file: String) throws -> [String] {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private let listVersionReads = [
        "listVersion", "odel.scheduleTriggers", "odel.schedulerBoard", "odel.scheduleTrigger(",
    ]

    @Test func controllersObserveKindEpochsNotTheListEpoch() throws {
        let all = FileManager.default.enumerator(
            at: appSources, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []
        let files = all.filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "app sources not found at \(appSources.path)")
        var blocks = 0
        var violations: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where line.contains("withObservationTracking {") {
                blocks += 1

                var depth = 0
                var cursor = index
                while cursor < lines.count {
                    for character in lines[cursor] {
                        if character == "{" { depth += 1 }
                        if character == "}" { depth -= 1 }
                    }
                    let code = lines[cursor].split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
                    for token in listVersionReads where code.contains(token) {
                        violations.append("\(file.lastPathComponent):\(cursor + 1) observes \(token)")
                    }
                    if depth <= 0 { break }
                    cursor += 1
                }
            }
        }
        #expect(blocks >= 8, "sweep should see the app's observation sites (\(blocks))")
        #expect(violations.isEmpty, "observe model.version(of:) for the kinds read, not the list epoch: \(violations)")
    }

    @Test func schedulerWatchesItsOwnKinds() throws {
        let source = try lines(of: "SchedulerController.swift").joined(separator: "\n")
        #expect(source.contains("_ = model.version(of: .scheduleTrigger)"))
        #expect(source.contains("_ = model.version(of: .schedulerBoard)"))
    }

    @Test func editorSavesBumpTheirOwnKinds() throws {
        let lines = try lines(of: "SlideEditorModel.swift")
        let wide = lines.enumerated().filter { $0.element.contains("noteExternalMutation()") }.map { $0.offset + 1 }
        #expect(wide.isEmpty, "SlideEditorModel.swift \(wide): the library-wide bump drops every read cache and wakes every kind's observer per edit — use noteEditorSave(of:)")
        let source = lines.joined(separator: "\n")

        for kind in [".presentation", ".theme", ".overlay", ".confidenceLayout"] {
            #expect(source.contains("appModel.noteEditorSave(of: \(kind),"), "the \(kind) host's save must bump its own kind")
        }
    }

    private let kindWideBumps: Set<String> = [

        "LocalAPIBridgeAdapter.swift deleteDocument",
        "LocalAPIBridgeAdapter.swift create",
        "LocalAPIBridgeAdapter.swift update",
        "WorkspaceImport.swift run",
        "BackupTransfer.swift run",
        "ServiceControls.swift init",  

        "AppModel.swift noteEditorSave",
        "AppModel.swift noteDecksRestyled",
        "AppModel.swift land",
        "AppModel.swift optimisticWriteFailed",
        "AppModel.swift noteExternalMutation",
        "AppModel.swift libraryOpened",
        "AppModel.swift locateMissingMedia",
        "AppModel.swift importFiles",
        "AppModel.swift importProPresenter",
        "AppModel.swift importProPresenterThemes",
        "AppModel.swift importProPresenterPlaylists",
        "AppModel.swift importPowerPoint",
        "AppModel.swift transcodeFlagged",
    ]

    @Test func kindWideBumpsAreAllowListed() throws {
        let sweep = try SourceSweep.app()
        var found: Set<String> = []
        for file in sweep.files {
            for index in file.lines.indices {
                let code = file.code(index)
                guard code.contains("noteExternalMutation(") || code.contains("noteLibraryWideMutation()")
                    || code.contains("noteMutation("),
                    !code.contains("func note")
                else { continue }
                found.insert("\(file.name) \(file.enclosingMember(of: index) ?? "?")")
            }
        }
        #expect(
            found == kindWideBumps,
            "a one-document write lands through the one-change funnel (land / noteEditorSave), never a kind-wide bump: new \(found.subtracting(kindWideBumps).sorted()), gone \(kindWideBumps.subtracting(found).sorted())"
        )
    }

    @Test func recordingAdoptionBumpsMediaOnly() throws {
        let lines = try lines(of: "ServiceControls.swift")
        let adopt = try #require(lines.firstIndex { $0.contains("RecordingLibrary.adopt(") })
        let body = lines[adopt..<min(lines.count, adopt + 20)].joined(separator: "\n")
        #expect(body.contains("appModel.noteExternalMutation(of: .media)"))
        #expect(!body.contains("noteExternalMutation()"))
    }

    @Test func connectivityPollThrottlesTheGrantCheck() throws {
        let lines = try lines(of: "VideoInputInventory.swift")
        var polls = 0
        for (index, line) in lines.enumerated() where line.contains("private func pollConnectivity()") {
            polls += 1
            let body = lines[index..<min(lines.count, index + 40)].joined(separator: "\n")
            let grantCall = body.range(of: "authorizationStatus(for: .video)")
            let gate = body.range(of: "cameraGrantCheckInterval")
            #expect(grantCall != nil && gate != nil && gate!.lowerBound < grantCall!.lowerBound,
                    "pollConnectivity's authorizationStatus read must sit behind the cameraGrantCheckInterval gate")
        }
        #expect(polls == 1)
    }
}
