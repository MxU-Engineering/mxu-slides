import Foundation
import Testing

@Suite struct LibraryPresentSweepTests {
    @Test func onlyADeckTakesTheCenter() throws {
        let shell = try #require(SourceSweep.app().file("AppShell.swift")).text
        #expect(shell.contains("LibraryPresentLogic.takesCenter(entry.kind) {\n                PresentGridView("))
        #expect(!shell.contains("MediaFireView(model: model, controls: controls, mediaID: entry.id)"))
        #expect(shell.contains("!LibraryPresentLogic.takesCenter(entry.kind) {\n                return"),
                "a non-deck pick keeps the run-order selection")
    }

    @Test func rowsAndCardsFireInPresentOnly() throws {
        let library = try #require(SourceSweep.app().file("LibraryView.swift")).text
        #expect(library.contains("guard appModeRaw == AppMode.present.rawValue, LibraryPresentLogic.editsFromRow(entry.kind) else { return nil }"))
        #expect(library.contains("LibraryRowFireControls(actions: fire, hovering: hovering)"))
        #expect(library.contains(".modifier(LibraryCardFireOverlay(actions: fireActions(entry)))"))
        #expect(library.contains(".modifier(LibraryRowFireTrailing(actions: fireActions(hit.entry)))"), "search hits play too")
    }

    @Test func libraryPopsOutAndHidesFromTheSidebar() throws {
        let sweep = try SourceSweep.app()
        let shell = try #require(sweep.file("AppShell.swift")).text
        #expect(shell.contains("!(layout?.libraryWindowOpen ?? false) && layout?.volunteerLibraryKinds?.isEmpty != true"))
        #expect(shell.contains("if layout.libraryWindowOpen {\n                openWindow(id: \"library\")"))
        let window = try #require(sweep.file("ModuleWindow.swift")).text
        #expect(window.contains("layout?.libraryWindowClosed()"))
        #expect(window.contains("layout?.libraryWindowOpened()"))
    }

    @Test func volunteersPlayButNeverEditTheLibrary() throws {
        let sweep = try SourceSweep.app()
        let library = try #require(sweep.file("LibraryView.swift")).text
        #expect(library.contains("if let allowed = layout?.volunteerLibraryKinds {\n            return orderedTabs.filter { allowed.contains($0.kind) }"))
        #expect(library.contains("if !runOnly {\n            entryMenuItems(entry, menus: menus)"))
        #expect(library.contains("private func folderMenu(_ path: [String]) -> some View {\n        if !isUnfiled(path), !runOnly {"))
        #expect(library.contains("guard !runOnly, let moved = LibrarySection(rawValue: movedID) else { return }"))
        #expect(library.contains("if !runOnly {\n                Divider()\n                footer"))
        #expect(library.contains("guard !runOnly else { return false }"), "folder drops")
        let controls = try #require(sweep.file("LibraryFireControls.swift")).text
        #expect(controls.components(separatedBy: "if hovering, !runOnly {").count == 3, "the pencil hides on rows and deck cards")
        #expect(try #require(sweep.file("SettingsView.swift")).text.contains("VolunteerLibrariesControl(layout: layout)"))
    }

    @Test func overlaysLeftServiceControls() throws {
        let sweep = try SourceSweep.app()
        let modules = try #require(sweep.file("ServiceControlsModule.swift")).text
        #expect(!modules.contains("    case overlays\n"))

        #expect(try #require(sweep.file("LibraryView.swift")).text.contains("if entry.kind == .overlay, !runOnly, let overlay = model.overlay(entry.id) {"))
    }
}
