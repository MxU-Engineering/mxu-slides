import Foundation
import Testing

@Suite struct LibraryThemeDesignsSweepTests {
    @Test func themeRowsShowTheirFirstDesignAndOpenLikeFolders() throws {
        let library = try #require(SourceSweep.app().file("LibraryView.swift")).text
        #expect(library.contains("if case .theme(let theme) = loaded, let design = theme.slides?.first {"))
        #expect(library.contains("Theme.self, id: entry.id, updatedAt: stamp, client: client"), "the face decodes off main")
        #expect(library.contains("if entry.kind == .theme, NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) {\n                    model.librarySelection = [entry.id]\n                    openThemeID = entry.id"), "the click selects it too, so Edit opens it")
        #expect(!library.contains("openThemeID = nil\n"), "stays open across tabs: pick a deck in Slides, drag its designs onto the editor's rows")
        #expect(library.contains(".modifier(slideDropTarget(entry))\n            // A theme opens like a folder"), "the tap sits outside the drop target, which Edit's click rebuilds")
        #expect(library.contains("AppModel.folderableSections.contains(model.selectedSection) || model.selectedSection == .themes"), "Themes has the grid")
        #expect(library.contains("if entry.kind == .theme, !NSEvent.modifierFlags.contains(.shift) {\n                    openThemeID = entry.id"), "a theme card opens too")
    }

    @Test func designsEditAtTheirSlideAndDragAsThemeDesigns() throws {
        let sweep = try SourceSweep.app()
        let library = try #require(sweep.file("LibraryView.swift")).text
        #expect(library.contains("model.openInEditor(entryID: theme.id, slideID: designID)"))
        let designs = try #require(sweep.file("LibraryThemeDesigns.swift")).text
        #expect(designs.contains(".draggablePayload(runOnly ? nil : ThemeDesignDrag.payload(themeId: look.theme.id, designId: design.id))"))
        #expect(designs.components(separatedBy: ".modifier(DesignDragAndMenu(").count == 3, "rows and cards both drag and edit")
        #expect(designs.contains("LibraryFireActions(model: model, controls: nil, entry: entry) { edit(design.id) }"), "the pencil")
        #expect(library.contains("guard appModeRaw == AppMode.present.rawValue || entry.kind == .theme,"), "themes' pencil in Edit too")
        #expect(designs.contains("Button(\"Edit…\") { edit(design.id) }"))
        #expect(designs.contains("if let editor {\n            editor.selectSlide(id)\n        } else if opensOnClick {\n            edit(id)"), "in Edit a click shows or opens the design")
        #expect(designs.contains("if let id { pick(id) }"), "the List's own click opens it")
        #expect(!designs.contains("simultaneousGesture"), "a tap on a List row takes its drag")
        #expect(library.contains("opensOnClick: appModeRaw == AppMode.edit.rawValue"))
        #expect(!designs.contains("ThemeLook.load("), "one theme, never every theme")
    }

    @Test func aDroppedDesignRestylesTheSlideItLandsOn() throws {
        let sweep = try SourceSweep.app()
        let drops = try #require(sweep.file("GutterDropDelegate.swift")).text
        #expect(drops.contains("if Self.appliesToSlide(payload: NSPasteboard(name: .drag).string(forType: .string)) {\n            .on"), "ring, never a line")
        #expect(drops.contains("!GutterDropDelegate.appliesToSlide(payload: payload)"), "gaps refuse it")
        let grid = try #require(sweep.file("PresentGridView.swift")).text
        #expect(grid.contains("model.applyTheme(to: presentation.id, slideIDs: [slide.id], themeID: dropped.themeId, design: dropped.design.name)"))
        #expect(try #require(sweep.file("AppModel.swift")).text.contains("self == .media || self == .audio || self == .notes || self == .themes"),
                "Edit keeps the deck open on the Themes tab, to drop designs on")
        let editor = try #require(sweep.file("SlideEditorView.swift")).text
        #expect(editor.contains("guard model.hasPresentationSettings else { return false }\n            model.pickThemeSlide(dropped.design.name, themeId: dropped.themeId, for: slide.id)"))
    }
}
