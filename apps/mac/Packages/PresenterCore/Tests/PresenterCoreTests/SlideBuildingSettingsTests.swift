import Foundation
import Testing

@testable import PresenterCore

@Suite struct SlideBuildingSettingsTests {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let suite = "slide-building-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    private func map(_ theme: String) -> SlideDesignMap {
        var map = SlideDesignMap()
        map.set(.init(themeId: theme, themeSlideName: "Scripture"), for: .scripture)
        return map
    }

    @MainActor @Test func isATeamSingletonEveryComputerHoldsInTheSettingsBackup() {
        #expect(SlideBuildingSettings.documentKind == .slideBuildingSettings)
        #expect(SlideBuildingSettings.wellKnownID == "slide-building-settings")
        #expect(SyncScope.scope(for: .slideBuildingSettings) == .team)
        #expect(SyncScope.everyComputerHolds(.slideBuildingSettings))
        #expect(!SyncScope.everyComputerHolds(.presentation), "everything else follows the offline set")
        #expect(BackupSection.section(for: .slideBuildingSettings) == .settings)
        #expect(DocumentKind.slideBuildingSettings.directoryName == "slide-building-settings")
        #expect(!Library.listedKinds.contains(.slideBuildingSettings), "a singleton is never listed")
        #expect(ResidentLibrary.kinds.contains(.slideBuildingSettings), "readers on main read the resident value")
    }

    @Test func thisMacsOwnSettingsComeFromItsDefaultsAndEmptyIsUnset() {
        let data = map("booth-theme").encoded()
        let own = SlideBuildingSettings.fromDefaults(defaults([
            SlideBuildingSettings.designMapDefaultsKey: data,
            SlideBuildingSettings.messageNotesThemeDefaultsKey: "",
            SlideBuildingSettings.lyricsImportThemeDefaultsKey: "lyrics-theme",
        ]))
        #expect(own.id == SlideBuildingSettings.wellKnownID)
        #expect(own.slideDesignMap.entry(for: .scripture)?.themeId == "booth-theme")
        #expect(own.messageNotesThemeId == nil, "an empty choice is no choice")
        #expect(own.lyricsImportThemeId == "lyrics-theme")
        #expect(!own.isUnset)
        #expect(SlideBuildingSettings.fromDefaults(defaults([:])).isUnset)
    }

    @Test func theDrivesDocumentWinsOverThisMacsDefaultsOnceItIsHere() {
        let own = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID, lyricsImportThemeId: "mine")
        let drive = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID, lyricsImportThemeId: "booth")
        #expect(SlideBuildingSettings.effective(document: drive, defaults: own).lyricsImportThemeId == "booth")
        #expect(SlideBuildingSettings.effective(document: nil, defaults: own).lyricsImportThemeId == "mine")
        #expect(
            SlideBuildingSettings.effective(document: SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID), defaults: own).lyricsImportThemeId == nil,
            "once the document exists the defaults are never read, even for a field it leaves unset")
    }

    @Test func notesFallBackToTheLyricThemeThenTheStarter() {
        var settings = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
        #expect(settings.notesThemeId(starter: "pack") == "pack")
        #expect(settings.notesThemeId(starter: nil) == "", "no starter in the library: no theme")
        settings.lyricsImportThemeId = "lyrics"
        #expect(settings.notesThemeId(starter: "pack") == "lyrics")

        var none = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
        none.setLyricsLook(themeId: "", design: nil)
        #expect(none.notesThemeId(starter: "pack") == "")
        none.startOnTheme("pack")
        #expect(none.lyricsImportThemeId == "", "onboarding's starter never overrides it either")
    }

    @Test func aFreshLibraryStartsOnTheStarterThemeOnlyWhileNoneIsSet() {
        var fresh = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
        fresh.startOnTheme("pack.cleanGeometric.theme")
        #expect(fresh.lyricsImportThemeId == "pack.cleanGeometric.theme")
        var chosen = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID, lyricsImportThemeId: "church", lyricsImportDesign: "Lyrics Lower")
        chosen.startOnTheme("pack.cleanGeometric.theme")
        #expect(chosen.lyricsImportThemeId == "church" && chosen.lyricsImportDesign == "Lyrics Lower")
    }

    @Test func theDesignMapRoundTripsAsStableText() {
        var settings = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
        var design = map("t1")
        design.set(.init(themeId: "t2", themeSlideName: "Point"), for: .points)
        design.blanks = .afterPassage
        settings.setSlideDesignMap(design)
        #expect(settings.slideDesignMap == design)
        let first = settings.designMap
        settings.setSlideDesignMap(design)
        #expect(settings.designMap == first, "the same map is the same text, so saving it again changes nothing")
    }

    @Test func seedAdoptOrWaitFromTheDrivesIndex() {
        let own = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID, lyricsImportThemeId: "mine")
        let none = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
        #expect(SlideBuildingSeed.step(held: true, indexLoaded: true, inCloud: false, own: own) == .none, "already here")
        #expect(SlideBuildingSeed.step(held: false, indexLoaded: false, inCloud: false, own: own) == .none, "never before the Drive's index is read")
        #expect(SlideBuildingSeed.step(held: false, indexLoaded: true, inCloud: true, own: own) == .adopt, "the Drive's wins over this Mac's")
        #expect(SlideBuildingSeed.step(held: false, indexLoaded: true, inCloud: false, own: own) == .seed)
        #expect(SlideBuildingSeed.step(held: false, indexLoaded: true, inCloud: false, own: none) == .none, "nothing of its own to give")
    }

    @Test func aFirstCopyTakesOnlyWhatThisMacSet() {
        var document = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID, lyricsImportThemeId: "edited")
        document.fillUnset(from: SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID, messageNotesThemeId: "notes", lyricsImportThemeId: "old"))
        #expect(document.messageNotesThemeId == "notes")
        #expect(document.lyricsImportThemeId == "edited", "a value already there is kept")
        #expect(document.designMap == nil)
    }

    @MainActor @Test func twoComputersSeedingAtOnceMergeFieldByField() async throws {
        func computer(_ own: SlideBuildingSettings) async throws -> (URL, LibraryBatch) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("slide-building-\(UUID().uuidString)")
            let client = LibraryClient(rootURL: root)
            try await client.start().value
            let batch = try await client.modify(
                SlideBuildingSettings.self, id: SlideBuildingSettings.wellKnownID,
                orMake: { SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID) }, seeded: true, area: .team
            ) { $0.fillUnset(from: own) }.value
            return (root, batch)
        }
        var boothOwn = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
        boothOwn.setSlideDesignMap(map("booth-theme"))
        let (booth, boothBatch) = try await computer(boothOwn)
        let (laptop, _) = try await computer(SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID, messageNotesThemeId: "notes", lyricsImportThemeId: "lyrics"))
        defer { [booth, laptop].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(boothBatch.snapshot.area(kind: .slideBuildingSettings, id: SlideBuildingSettings.wellKnownID) == .team, "the Drive's, not this Mac's")

        let merged = try await onLibraryActor {
            let mine = try Library(rootURL: booth).open(SlideBuildingSettings.self, id: SlideBuildingSettings.wellKnownID)
            let theirs = try Library(rootURL: laptop).open(SlideBuildingSettings.self, id: SlideBuildingSettings.wellKnownID)
            #expect(mine.firstChangeHash() == theirs.firstChangeHash(), "one history")
            try mine.merge(theirs)
            return mine.value
        }
        #expect(merged.slideDesignMap.entry(for: .scripture)?.themeId == "booth-theme")
        #expect(merged.messageNotesThemeId == "notes")
        #expect(merged.lyricsImportThemeId == "lyrics", "neither computer's choice is lost")
    }

    @Test func theLyricThemeAndItsDesignArePickedTogether() {
        var settings = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
        #expect(settings.lyricsDesign == "Lyrics", "no pick = the theme's Lyrics design")

        settings.setLyricsLook(themeId: "sunday", design: "Lyrics (Lower Third)")
        #expect(settings.lyricsImportThemeId == "sunday")
        #expect(settings.lyricsDesign == "Lyrics (Lower Third)")
        #expect(!settings.isUnset)

        settings.setLyricsLook(themeId: "sunday", design: nil)
        #expect(settings.lyricsDesign == "Lyrics (Lower Third)", "a theme-only pick of the same theme keeps the design")
        settings.setLyricsLook(themeId: "youth", design: nil)
        #expect(settings.lyricsImportThemeId == "youth")
        #expect(settings.lyricsImportDesign == nil, "another theme drops a design its names may not have")

        settings.setLyricsLook(themeId: "youth", design: "Big Words")
        settings.setLyricsLook(themeId: "youth", design: "")
        #expect(settings.lyricsDesign == "Lyrics", "Use \u{201C}Theme\u{201D} goes back to Lyrics")

        settings.setLyricsLook(themeId: "youth", design: "Big Words")
        settings.setLyricsLook(themeId: "", design: "")
        #expect(settings.lyricsImportThemeId == "", "None is a choice, kept")
        #expect(settings.lyricsImportDesign == nil, "None has no design")
    }
}

@Suite struct SlideBuildingReadersSweepTests {
    private func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func theReadersUseTheChurchDocument() throws {
        for name in ["MakeSlidesSheet.swift", "LibraryView.swift", "ImportLyricsSheet.swift"] {
            let text = try source(name)
            #expect(!text.contains("\"makeSlides.designMap\""), "\(name) reads this Mac's design map")
            #expect(!text.contains("LyricsImportDefaults"), "\(name) reads this Mac's theme")
        }
        #expect(try source("MakeSlidesSheet.swift").contains("appModel.slideBuilding.slideDesignMap"))
    }

    @Test func theWalkthroughFixesAreWiredIn() throws {
        #expect(try source("MakeSlidesSheet.swift").contains("slideDisplay: .hidden"))
        let model = try source("AppModel.swift")
        #expect(model.contains("startOnTheme(StarterPack.cleanGeometric.themeID)"))
        let bar = try source("NoteSelectionBar.swift")
        #expect(bar.contains("replaceKeepingAttributes(range, with: storage.slideNoteWrapped(range))"))
        #expect(!bar.contains("insertText(\"(\""), "a typed ( takes the card's attributes above the line")

        let document = try source("NoteDocumentView.swift")
        #expect(document.contains("if style.slideDisplay == .hidden {\n                result.append(hostedCard(block,"))
        #expect(!document.contains("guard style.slideDisplay != .hidden else { return }"))

        #expect(document.contains("origin.y += leadingPanelRoom") && document.contains("textContainerInset.height * 2 + leadingPanelRoom"))

        let panels = try source("NotePanelViews.swift")
        #expect(panels.contains("final class PanelOverlayView") && panels.contains("owner?.drawPanels()"))
        #expect(!document.contains("            drawPanels()\n"), "the text view no longer draws them itself")

        #expect(document.contains("DispatchQueue.main.async { [weak self] in\n            guard metrics.columnWidth != column else { return }"))

        #expect(document.contains("attachment.host = host\n            host.scheduleSizeCheck()"))
        #expect(document.contains("(value as? NoteSlideAttachment)?.host?.scheduleSizeCheck()"))
        #expect(document.contains(".onGeometryChange(for: CGSize.self) { $0.size } action: { [weak attachment] _ in\n                attachment?.host?.scheduleSizeCheck()"))
        #expect(document.contains("availableWidth: metrics.columnWidth - (attachment.style.slideDisplay.drawsPanels ? NotePanelMetrics.inset * 2 : 0)"))

        let reader = try source("NoteReaderView.swift")
        #expect(reader.contains("SlideTile(") && reader.contains("liveOverride: context.liveSlideID == fired.id"))
        #expect(try source("PresentGridView.swift").contains("if let liveOverride { return liveOverride }"))

        #expect(panels.contains("case .slide(_, _, let index) = NoteSlides.resolve(ref, presentation: { model.presentation($0) })"))

        #expect(panels.contains("if markGutter == 0 {\n                NSGraphicsContext.saveGraphicsState()"))

        #expect(try source("NoteMarginMarks.swift").contains("style.slideDisplay == .compact, let index = cardIndex(ofSlide: slideId)"))
    }
}
