import Foundation
import Testing

@testable import PresenterCore

@Suite struct MainThreadDecodeSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func swiftFiles() throws -> [URL] {
        let all = FileManager.default.enumerator(
            at: appSources, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []
        let files = all.filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "app sources not found at \(appSources.path)")
        return files
    }

    private let forbidden = [".mediaItem(", ".audioItem(", "library.open("]

    private let forbiddenInMenus = [
        "odel.theme(entry", "odel.theme($0", "odel.theme(theme.id", "compactMap { appModel.theme(", "compactMap { model.theme(",
        "odel.presentation(entry", "odel.presentation($0",
    ]

    private let listingsInMenus = [
        "model.folders(in:", "model.entries(in:", "model.teamDrives(", "model.playlists(in:", "library.index.",
    ]

    private func menuViolations(_ lines: [String], fileName: String) -> (blocks: Int, violations: [String]) {
        var blocks = 0
        var violations: [String] = []
        for (index, line) in lines.enumerated() where line.contains(".contextMenu") || line.contains("Menu {") || line.contains("Menu(") {
            let isMenu = !line.contains(".contextMenu")
            blocks += 1

            var depth = 0
            var started = false
            var cursor = index
            while cursor < lines.count {
                for character in lines[cursor] {
                    if character == "{" { depth += 1; started = true }
                    if character == "}" { depth -= 1 }
                }
                for token in forbidden + listingsInMenus + (isMenu ? forbiddenInMenus : []) where lines[cursor].contains(token) {
                    violations.append(
                        "\(fileName):\(cursor + 1) uses \(token)) inside \(isMenu ? "a Menu" : ".contextMenu")"
                    )
                }
                if started, depth <= 0 { break }
                cursor += 1
            }
        }
        return (blocks, violations)
    }

    @Test func contextMenusNeverOpenDocuments() throws {
        var blocks = 0
        var violations: [String] = []
        for file in try swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let found = menuViolations(lines, fileName: file.lastPathComponent)
            blocks += found.blocks
            violations += found.violations
        }
        #expect(blocks >= 30, "sweep should see the app's context menus (\(blocks))")
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test func menusListOncePerPassNotPerRow() {
        let perRow = [
            "private func singleEntryMenu(_ entry: LibraryIndex.Entry) -> some View {",
            "    Menu(\"Move to Folder\") {",
            "        let folders = model.folders(in: model.selectedSection)",
            "        ForEach(folders, id: \\.self) { Button($0) {} }",
            "    }",
            "}",
            "row.contextMenu {",
            "    ForEach(model.entries(in: .themes), id: \\.id) { Button($0.name) {} }",
            "}",
        ]
        let found = menuViolations(perRow, fileName: "Fixture.swift")
        #expect(found.violations.contains { $0.hasPrefix("Fixture.swift:3 uses model.folders(in:") })
        #expect(found.violations.contains { $0.hasPrefix("Fixture.swift:8 uses model.entries(in:") })
        let perPass = [
            "let lists = RowMenuLists(folders: model.folders(in: section))",
            "private func singleEntryMenu(_ entry: LibraryIndex.Entry, menus: RowMenuLists) -> some View {",
            "    Menu(\"Move to Folder\") {",
            "        ForEach(menus.folders, id: \\.self) { Button($0) {} }",
            "    }",
            "}",
        ]
        #expect(menuViolations(perPass, fileName: "Fixture.swift").violations.isEmpty)
    }

    private let indexReadExceptions: [(file: String, token: String)] = []

    @Test func viewsReadTheIndexThroughTheReadModel() throws {
        var scanned = 0
        var violations: [String] = []
        var matched: Set<String> = []
        for file in try swiftFiles() {
            let folder = file.deletingLastPathComponent().lastPathComponent
            let isView = (folder == "Sources" && file.lastPathComponent.contains("View")) || folder == "Modules"
            if isView {
                scanned += 1
                let lines = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                for (index, line) in lines.enumerated() {
                    let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if code.contains("library.index.") {
                        let excepted = indexReadExceptions.first { $0.file == file.lastPathComponent && code.contains($0.token) }
                        if let excepted {
                            matched.insert("\(excepted.file) \(excepted.token)")
                        } else {
                            violations.append("\(file.lastPathComponent):\(index + 1)")
                        }
                    }
                }
            }
        }
        let stale = indexReadExceptions.map { "\($0.file) \($0.token)" }.filter { !matched.contains($0) }
        #expect(scanned >= 25, "sweep should see the app's views and modules (\(scanned))")
        #expect(violations.isEmpty, "read the index through AppModel's read model: \(violations)")
        #expect(stale.isEmpty, "exceptions that match nothing any more — delete them: \(stale)")
    }

    @Test func thumbnailContentRendersOffMain() throws {
        let file = appSources.appendingPathComponent("ThumbnailStore.swift")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = 0
        for (index, line) in lines.enumerated() where line.contains("renderFrame(") {
            found += 1
            let preceding = lines[max(0, index - 3)..<index].joined(separator: "\n")
            #expect(
                preceding.contains("renderQueue.async"),
                "ThumbnailStore.swift:\(index + 1) renderFrame outside the render queue"
            )
        }
        #expect(found >= 1, "slideContent's render call expected")
    }

    @Test func posterDecodesRunDetached() throws {
        let store = try String(contentsOf: appSources.appendingPathComponent("ThumbnailStore.swift"), encoding: .utf8)
        let start = try #require(store.range(of: "func poster("))
        let tail = store[start.upperBound...]
        let body = String(tail[..<(try #require(tail.range(of: "\n    }\n"))).lowerBound])
        #expect(!body.contains("Task {") && !body.contains("Task<"), "poster(for:) starts no main-actor-inheriting Task")
        #expect(body.contains("Task.detached(priority: priority)"))
        #expect(body.contains("imageDecodes.withPermit"))
    }

}

@Suite struct MainThreadOpenTrapTests {
    @Test func aDebugLaunchArmsItUnlessTheOptOutIsSet() {
        #expect(MainThreadOpenTrap.armsAtLaunch(isDebug: true, envValue: nil), "on by default")
        #expect(MainThreadOpenTrap.armsAtLaunch(isDebug: true, envValue: "0"))
        #expect(!MainThreadOpenTrap.armsAtLaunch(isDebug: true, envValue: "1"), "MXU_ALLOW_MAIN_OPENS=1 opts out")
        #expect(!MainThreadOpenTrap.armsAtLaunch(isDebug: false, envValue: nil), "release builds never arm it")
        #expect(!MainThreadOpenTrap.armsAtLaunch(isDebug: false, envValue: "1"))
    }

    @Test func theOptOutIsTheDocumentedName() {
        #expect(MainThreadOpenTrap.environmentKey == "MXU_ALLOW_MAIN_OPENS")
    }

    @Test func trapsOnMainWhenArmedWithNoEscape() {
        #expect(MainThreadOpenTrap.shouldTrap(isMain: true, armed: true), "no site is allowed to decode on main")
        #expect(!MainThreadOpenTrap.shouldTrap(isMain: false, armed: true), "background decodes are the goal")
        #expect(!MainThreadOpenTrap.shouldTrap(isMain: true, armed: false), "a test run or an opted-out launch")
    }

    @MainActor @Test func onlyTheAppsLaunchArmsIt() throws {
        #expect(!MainThreadOpenTrap.isArmed)
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let app = try String(contentsOf: sources.appendingPathComponent("MxUSlidesApp.swift"), encoding: .utf8)
        let arm = try #require(app.range(of: "MainThreadOpenTrap.armAtLaunch()"))
        let model = try #require(app.range(of: "AppModel("), "the app builds its model")
        #expect(arm.lowerBound < model.lowerBound, "armed before the library opens")
    }
}
