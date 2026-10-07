import Foundation
import Testing

@Suite struct RunOnlySweepTests {
    private static let lockTokens = [
        "runOnly", "isRunOnly", "editable", "locked(", "canComment", "onChange != nil",
    ]

    private static let affordances = [".contextMenu", ".dropDestination(", ".onDrop(", "DatePicker("]

    private static let reach = 14
    private static let above = 6

    private func presentSurfaces(_ sweep: SourceSweep) -> [SourceSweep.File] {
        let named: Set<String> = [
            "AppShell.swift", "ServicePlannerView.swift", "ServiceContinuousView.swift",
            "PresentGridView.swift", "LivePanel.swift", "ServiceControlsPanel.swift", "MediaCueMenu.swift",
        ]
        return sweep.files.filter { file in
            !Self.notShownInRunOnly.contains(file.name) && (
                named.contains(file.name)
                    || file.url.deletingLastPathComponent().lastPathComponent == "Modules"
                    || file.text.contains("@Environment(\\.runOnly)"))
        }
    }

    private static let notShownInRunOnly: Set<String> = ["LibraryView.swift"]

    private func neighborhood(_ file: SourceSweep.File, at index: Int) -> String {
        let end = min(index + Self.reach, file.codeLines.count - 1)
        let start = max(0, index - Self.above)
        let near = file.codeLines[start ... end].joined(separator: "\n")
        let closure = file.codeLines[index ... min(index + 3, end)].joined(separator: "\n")
        let calls = Set(closure.matches(of: /([a-z][A-Za-z0-9_]*)\(/).map { String($0.1) })
        let helpers = file.codeLines.indices.compactMap { line -> String? in
            let code = file.code(line)
            let called = calls.first { code.contains("func \($0)(") }
            return called.map { _ in
                file.codeLines[file.block(from: line)].joined(separator: "\n")
            }
        }
        return ([near] + helpers).joined(separator: "\n")
    }

    private static let allowed: [String: String] = [
        "AppShell.swift serviceHeader": "date popover binding asks isRunOnly",
    ]

    @Test func everyPresentAffordanceAsksTheLock() throws {
        let sweep = try SourceSweep.app()
        var misses: [String] = []
        for file in presentSurfaces(sweep) {
            for index in file.codeLines.indices {
                let line = file.code(index)
                if Self.affordances.contains(where: line.contains) {
                    let asks = Self.lockTokens.contains(where: neighborhood(file, at: index).contains)
                    let key = "\(file.name) \(file.enclosingMember(of: index) ?? "?")"
                    if !asks && Self.allowed[key] == nil {
                        misses.append("\(file.name):\(index + 1) [\(key)] \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        let shell = try #require(sweep.file("AppShell.swift")).text
        #expect(shell.contains("get: { editingServiceDateID != nil && !isRunOnly }"))
        #expect(misses.isEmpty, "a run-only volunteer can reach these — gate them on \\.runOnly or allow-list them with a reason:\n\(misses.joined(separator: "\n"))")
    }

    @Test func presentDragsGoThroughTheGatedPayload() throws {
        let sweep = try SourceSweep.app()
        var misses: [String] = []
        for file in presentSurfaces(sweep) where file.name != "ServiceControlsModule.swift" {
            for index in file.codeLines.indices {
                let line = file.code(index)
                if line.contains(".draggable(") {
                    misses.append("\(file.name):\(index + 1) plain .draggable — use .draggablePayload(runOnly ? nil : …)")
                }
                if line.contains(".draggablePayload("), !Self.lockTokens.contains(where: line.contains) {
                    misses.append("\(file.name):\(index + 1) .draggablePayload without the lock")
                }
            }
        }
        #expect(misses.isEmpty, "\(misses.joined(separator: "\n"))")
    }

    @Test func menusReadTheLock() throws {
        let sweep = try SourceSweep.app()
        let stale = sweep.files.filter { $0.text.contains("@AppStorage(\"present.runOnly\")") }.map(\.name)
        #expect(stale.isEmpty, "read PresentLayoutController.lockedKey: \(stale)")
        for name in ["AppShell.swift", "LibraryView.swift", "OnboardingView.swift", "SlideEditorView.swift"] {
            #expect(sweep.file(name)?.text.contains("@AppStorage(PresentLayoutController.lockedKey)") == true, "\(name)")
        }
        let controller = try #require(sweep.file("PresentLayoutController.swift")).text
        #expect(controller.contains("UserDefaults.standard.set(true, forKey: Self.lockedKey)"))
        #expect(controller.contains("UserDefaults.standard.set(false, forKey: Self.lockedKey)"))
    }

    @Test func keysAndUndoAskTheLock() throws {
        let sweep = try SourceSweep.app()
        let keys = try #require(sweep.file("KeyboardShortcuts.swift")).text
        #expect(keys.contains("forKey: PresentLayoutController.lockedKey"))
        #expect(keys.contains("case let locked where runOnly && !locked.runsInRunOnly:"))
        let editor = try #require(sweep.file("SlideEditorView.swift")).text
        #expect(editor.contains("journalCan: !runOnly && journal?.canUndo == true"))
        #expect(editor.contains("journalCan: !runOnly && journal?.canRedo == true"))
    }

    @Test func runOnlyShowsOnlyThePickedTabs() throws {
        let sweep = try SourceSweep.app()
        let panel = try #require(sweep.file("ServiceControlsPanel.swift")).text
        #expect(panel.contains("if let allowed = volunteerModules {\n            orderedModules.filter(allowed.contains)"))
        #expect(panel.contains(".filter { volunteerModules == nil && hiddenModules.contains($0)"))
        let menu = try #require(panel.range(of: "private func moduleTabMenu("))
        let menuBody = panel[menu.upperBound...].prefix(1400)
        let gate = try #require(menuBody.range(of: "if !runOnly {"))
        #expect(menuBody[gate.upperBound...].contains("Section(\"Modules\")"), "the Modules toggles sit inside the run-only gate")
        #expect(try #require(sweep.file("ModuleWindow.swift")).text.contains("if let allowed = layout?.volunteerModules, !allowed.contains(module)"))
        #expect(try #require(sweep.file("PresentLayout.swift")).text.contains("var runOnlyModules: [String]?"))
        #expect(try #require(sweep.file("PresentLayoutController.swift")).text.contains("fresh.runOnlyModules = layouts[index].runOnlyModules"))
    }

    @Test func entrySnapshotsBeforeApplyingAndClosesSettings() throws {
        let sweep = try SourceSweep.app()
        let controller = try #require(sweep.file("PresentLayoutController.swift")).text
        let entry = try #require(controller.range(of: "func enterRunOnly(applying apply: (() -> Void)? = nil) {"))
        let body = controller[entry.upperBound...].prefix(600)
        let snapshot = try #require(body.range(of: "forKey: Self.preRunOnlyKey)"))
        let apply = try #require(body.range(of: "apply?()"))
        #expect(snapshot.upperBound <= apply.lowerBound, "exit restores the operator's arrangement, not the run-only layout")
        let settings = try #require(sweep.file("SettingsView.swift")).text
        #expect(settings.contains("RunOnlyEntrySheet("))
        #expect(settings.contains("settingsWindow?.close()"))
        #expect(settings.contains("Button(\"Change Passcode…\") { pinFlow = .change }"))
    }

    @Test func everyWindowSceneIsPlaced() throws {
        let sweep = try SourceSweep.app()
        let app = try #require(sweep.file("MxUSlidesApp.swift"))
        let placed: Set<String> = [
            "\"main\"", "\"module\"", "\"serviceControls\"", "\"preview\"", "\"outputs\"", "\"engine\"",
        ]
        let scenePattern = /(?:Window|WindowGroup)\((?:"[^"]*",\s*)?id:\s*("[^"]+")/
        var unplaced: [String] = []
        for index in app.lines.indices {
            if let match = app.lines[index].firstMatch(of: scenePattern), !placed.contains(String(match.1)) {
                unplaced.append("MxUSlidesApp.swift:\(index + 1) \(match.1)")
            }
        }
        #expect(unplaced.isEmpty, "decide what run-only shows in: \(unplaced)")
        #expect(app.text.contains("RunOnlyLockedPlaceholder(surface: \"Settings\")"))
    }
}
