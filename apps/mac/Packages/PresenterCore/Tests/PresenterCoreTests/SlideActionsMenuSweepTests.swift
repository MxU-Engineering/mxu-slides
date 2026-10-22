import Foundation
import Testing

@Suite struct SlideActionsMenuSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func addActionLeadsAndEachActionEditsOrRemoves() throws {
        let editors = try source("ActionEditors.swift")
        let start = try #require(editors.range(of: "struct ActionsMenu: View {"))
        let end = try #require(editors.range(of: "struct AddActionMenuItems: View {", range: start.upperBound..<editors.endIndex))
        let menu = String(editors[start.lowerBound..<end.lowerBound])
        let add = try #require(menu.range(of: "Menu(\"Add Action\")"))
        let list = try #require(menu.range(of: "Section(\"On This Slide\")"))
        #expect(add.lowerBound < list.lowerBound, "Add Action ▸ sits above the current actions")
        #expect(menu.contains("Button(\"Edit…\") { edit(action) }"))
        #expect(menu.contains("Button(\"Remove\", role: .destructive) { remove(action) }"))
        #expect(menu.contains("GlyphKind(action: action, model: model).menuImage"))
    }

    @Test func slideAndMediaCueShareTheMenu() throws {
        #expect(try source("PresentGridView.swift").contains("ActionsMenu("))
        #expect(try source("MediaCueMenu.swift").contains("ActionsMenu("))
    }

    @Test func badgesAndRowsShareTheGlyphRuleAndCombosShowTheirIcon() throws {
        let grid = try source("PresentGridView.swift")
        #expect(grid.contains("Glyph(kind: GlyphKind(action: action, model: model)"))
        #expect(!grid.contains("badgeGlyph("), "one glyph rule, in Glyphs.swift")
        let glyphs = try source("Glyphs.swift")
        #expect(glyphs.contains("model.actionCombo($0).iconName"))
    }

    @Test func combosCanUseTheLightIcon() throws {
        #expect(try source("Modules/ActionCombosModule.swift").contains("(.light, \"Light\")"))
    }
}
