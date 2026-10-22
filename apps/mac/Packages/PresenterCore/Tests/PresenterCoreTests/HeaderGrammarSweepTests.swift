import Foundation
import Testing

@Suite struct HeaderGrammarSweepTests {
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

    private func slice(_ text: String, from start: String, to end: String) throws -> Substring {
        let lower = try #require(text.range(of: start))
        let upper = try #require(text.range(of: end, range: lower.upperBound..<text.endIndex))
        return text[lower.lowerBound..<upper.lowerBound]
    }

    @Test func editorHeaderKeepsOnlyTheRepeatedTools() throws {
        let editor = try source("SlideEditorView.swift")
        let header = try slice(editor, from: "private func editorToolbar(", to: "// MARK: - Canvas")
        for gone in ["ArrangementPopover", "exportPresentation", "toggleThemeContent", "setTheme(", "setBackgroundFill", ".pickerStyle(.segmented)"] {
            #expect(!header.contains(gone), "\(gone) left the editor header")
        }
        #expect(header.contains("Label(\"Reflow\", systemImage: \"point.bottomleft.forward.to.point.topright.scurvepath\")"), "Reflow is an icon")
        #expect(!header.contains(".labelStyle(.titleAndIcon)"), "the header's tools are icons")
        #expect(header.contains("ToolbarSegments("), "Design / Animate is a tool group, not the stock segmented control")
    }

    @Test func everyToolGroupStandsTheHeaderHeight() throws {
        let design = try source("DesignSystem.swift")
        let cluster = try slice(design, from: "struct ToolbarCluster<", to: "enum HeaderMetrics")
        #expect(cluster.contains(".frame(height: HeaderMetrics.controlHeight)"))
        #expect(cluster.contains(".buttonStyle(ToolbarCellStyle())") && cluster.contains(".toggleStyle(ToolbarCellToggleStyle())"))
        #expect(design.contains("static let controlHeight: CGFloat = 26"))

        let shell = try source("AppShell.swift")
        let switcher = try slice(shell, from: "struct ModeSwitcher: View {", to: "struct ViewCommands")
        #expect(switcher.contains(".frame(height: HeaderMetrics.controlHeight)"))
        #expect(switcher.contains("Color.primary.opacity(hovering ? 0.12 : 0.08)"), "the mode switcher keeps its plate at rest")
    }

    @Test func titlebarControlsHaveNoPlateAtRest() throws {
        for name in ["BroadcastStatusChip.swift", "OutputPresetChip.swift", "ClearChip.swift"] {
            let chip = try source(name)
            #expect(!chip.contains("in: Capsule()"), "\(name) draws no plate at rest")
            #expect(chip.contains(".headerItemLabel()"), "\(name) stands the header height")
        }
        #expect(try source("ClearChip.swift").contains(".headerItemBackground(tint: anyContent ? .green : nil)"))
        let preview = try source("LivePanel.swift")
        let picker = try slice(preview, from: "private var screenPicker: some View {", to: ".help(\"Which screen or layout")
        #expect(picker.contains(".headerItemBackground()") && !picker.contains("strokeBorder"), "the Output Preview picker is bare too")
        let broadcast = try source("BroadcastStatusChip.swift")
        let label = try slice(broadcast, from: "private var chipLabel: some View {", to: "private var liveCaption")
        #expect(label.contains("(tint ?? .clear).opacity(0.12)"), "the on-air tint washes the chip inside its ticking label")
    }

    @Test func thePresentationTabCarriesTheWholeDeck() throws {
        let inspector = try source("SlideObjectInspector.swift")
        #expect(inspector.contains("case presentation, slide, object, animation"))
        #expect(inspector.contains("if model.hasPresentationSettings {\n            options.append((.presentation, \"Presentation\"))"))
        let tab = try slice(inspector, from: "private func presentationInspector()", to: "private var deckThemeTitle")
        #expect(tab.contains("model.choosingDeckTheme = true"))
        #expect(tab.contains("PresentationBackgroundRows(model: model)"))
        #expect(tab.contains("ArrangementPopover(model: model)"))
        #expect(tab.contains("presentationSettingsSection()"), "resolution and key")
        #expect(inspector.contains("if !model.hasPresentationSettings {\n            presentationSettingsSection()"), "the Slide tab keeps them only without a Presentation tab")
    }

    @Test func everyThemePickOpensTheExplorer() throws {
        let inspector = try source("SlideObjectInspector.swift")
        #expect(!inspector.contains("InspectorPicker(\"Theme Slide\""), "one selector, never a menu of names")
        #expect(inspector.contains("ThemePickButton(title: themeSlideTitle, detail: themeSlideDetail) {\n                        model.choosingSlideTheme = true"))

        let editor = try source("SlideEditorView.swift")
        #expect(editor.contains("ApplyThemeSheet(") && editor.contains("model.applyTheme(themeId, design: design)"))
        #expect(editor.contains("SlideThemeSheet(appModel: appModel, render: render, model: model)"))

        let sheets = try source("ApplyThemeMenu.swift")
        let slideSheet = try slice(sheets, from: "struct SlideThemeSheet: View {", to: "private func pick(")
        #expect(slideSheet.contains("ThemeExplorerView("))
        #expect(slideSheet.contains("Button(\"Automatic\")"), "the old picker's Automatic row survives")
        #expect(sheets.contains("model.pickThemeSlide(name, themeId: themeId, for: slide.id)"))
        #expect(slideSheet.contains("Button(\"Blank\")"), "the slide list's Blank (No Theme) survives")
        #expect(!editor.contains("Menu(\"Theme Slide\")"), "never a menu of names")
        #expect(editor.contains("model.slideThemeTargetID = slide.id\n                                model.choosingSlideTheme = true"))
        #expect(sheets.contains("Button(\"No Theme\")"), "the old Theme menu's None survives")
    }

    @Test func theThemeItemsAndExportLiveInTheMenus() throws {
        let editor = try source("SlideEditorView.swift")
        let commands = try slice(editor, from: "struct EditorCommands: Commands {", to: "private func undo()")
        #expect(commands.contains("Button(\"Reapply Theme (Clear Slide Edits)\")"))
        #expect(commands.contains("Toggle(\"Show Theme Content\""))
        #expect(commands.contains("Button(\"Export Presentation\\u{2026}\")"))
        #expect(!commands.contains(".disabled(editor?.presentation"), "a menu that reads the deck rebuilds on every edit")
    }

    @Test func titlebarControlsSitLeftOfTheRightCardInEveryMode() throws {
        let shell = try source("AppShell.swift")
        let width = try slice(shell, from: "private var rightPanelWidth: CGFloat? {", to: "static let headerHeight")
        #expect(width.contains("if railVisible {") && width.contains("} else if editorTakesOver {"))
        #expect(shell.contains(".padding(.trailing, rightPanelWidth.map { $0 + CornerStandard.panelInset } ?? 0)"), "the drag-catcher stops at the right card")
        #expect(shell.contains(".frame(width: rightPanelWidth.map { $0 + CornerStandard.panelInset + 16 } ?? 16)"), "the controls stand left of it")
        #expect(shell.contains("- (rightPanelWidth.map { $0 + CornerStandard.panelInset } ?? 0)"), "the header's shrink priority counts the editor card too")

        let inspector = try source("SlideObjectInspector.swift")
        #expect(inspector.contains("ToolbarSegments(options: tabOptions, selection: $tab, fillsWidth: true)"))
    }

    @Test func theKeyPickerShowsOnlyForASongWithChordsOrAKey() throws {
        let inspector = try source("SlideObjectInspector.swift")
        #expect(inspector.contains("if let musicKey = model.presentation.musicKey {\n                musicKeyPicker"))
        #expect(inspector.contains("} else if ChordMath.hasChords(in: model.presentation) {\n                musicKeyPicker"))
    }
}
