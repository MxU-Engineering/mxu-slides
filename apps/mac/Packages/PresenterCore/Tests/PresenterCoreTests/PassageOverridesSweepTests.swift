import Foundation
import Testing
@testable import PresenterCore

@Suite struct PassageOverridesSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    @Test func theLabelMenuOffersWordOverrides() throws {
        let sheet = try source("MakeSlidesSheet.swift")
        let start = try #require(sheet.range(of: "private func kindMenuExtras("))
        let extras = String(sheet[start.upperBound...].prefix(6000))
        #expect(extras.contains("set { $0.ownTypes[index].split = split }"), "an own type's Split, this passage only")
        #expect(extras.contains("set { $0.ownTypes[index].reveal.toggle() }"))
        #expect(extras.contains("set { $0.scriptureSplit = split }"))
        #expect(extras.contains("set { $0.verseNumbers.toggle() }"))
        #expect(extras.contains("set { $0.revealPoints.toggle() }"))
        #expect(extras.contains("items.append(linesPerSlideItem(group: group))"))
        #expect(extras.contains("items.append(designItem(group: group, kind: kind))"))
        #expect(sheet.contains("choices[group, default: RowChoice()].lines = lines"))
        #expect(sheet.contains("choices[group, default: RowChoice()].design = design"))

        #expect(sheet.contains("options: choice.options ?? map.options"))
        #expect(sheet.contains("SlideRowOverride(kind: choice.kind, themeSlideName: design, linesPerSlide: choice.lines)"))
    }

    @Test func designPicksOpenTheExplorer() throws {
        let sheet = try source("MakeSlidesSheet.swift")
        #expect(!sheet.contains("ThemeFace"), "no list of theme names")
        #expect(sheet.contains("photoSpotsOnly: type == SlideKind.picture.rawValue"))
        #expect(sheet.contains("photoSpotsOnly: kind == .picture"))
        #expect(sheet.contains("}) { pick in\n            DesignPickSheet("))
        #expect(sheet.contains(".sheet(item: $designPick, onDismiss: {"))
        let menu = try source("ApplyThemeMenu.swift")
        let start = try #require(menu.range(of: "struct DesignPickSheet"))
        let pick = String(menu[start.upperBound...])
        #expect(pick.contains("ThemeExplorerView("))
        #expect(pick.contains("looks = photoSpotsOnly ? all.compactMap(\\.photoSpotsOnly) : all"))
        #expect(pick.contains("theme.slides = theme.slides?.filter { !$0.photoSpots.isEmpty }"))
    }

    @Test func aSlideTileRightClickPopsTheSameMenu() throws {
        let sheet = try source("MakeSlidesSheet.swift")
        #expect(sheet.contains(".overlay(TileMenuBacking { tile.preview ? nil : scroller.kindMenu(for: tile.group) })"))
        #expect(sheet.contains("NSMenu.popUpContextMenu(menu, with: event, for: self)"))
        let marks = try source("NoteMarginMarks.swift")
        #expect(marks.contains("func kindMenu(group: String) -> NSMenu? {\n        guard isEditable else { return nil }"))
        #expect(marks.contains("kindMenu(group: group)?.popUp(positioning: nil, at: point, in: self)"))
    }

    @Test func aPassagesOwnLinesAndOptionsPlan() throws {
        let group = MarkedGroup(id: "g", type: "points", text: "Point one\nPoint two\nPoint three\nPoint four")
        let auto = try #require(DeterministicSlidePlanner().plan([group], theme: nil, overrides: [:]).rows.first)
        let two = try #require(DeterministicSlidePlanner().plan([group], theme: nil, overrides: ["g": SlideRowOverride(linesPerSlide: 2)]).rows.first)
        #expect(two.parts.count > auto.parts.count, "fewer lines per slide make more slides")
        var reveal = SlideOptions()
        reveal.revealPoints = true
        let revealed = try #require(DeterministicSlidePlanner(options: reveal).plan([group], theme: nil, overrides: [:]).rows.first)
        #expect(revealed.parts.contains { $0.contains { $0.revealLines != nil } })
    }
}
