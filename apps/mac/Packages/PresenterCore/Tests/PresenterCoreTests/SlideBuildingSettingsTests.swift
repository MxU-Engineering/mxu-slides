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
        let own = SlideBuildingSettings.fromDefaults(defaults([
            SlideBuildingSettings.designMapDefaultsKey: Data("{}".utf8),
            SlideBuildingSettings.messageNotesThemeDefaultsKey: "",
            SlideBuildingSettings.lyricsImportThemeDefaultsKey: "lyrics-theme",
        ]))
        #expect(own.id == SlideBuildingSettings.wellKnownID)
        #expect(own.designMap == "{}")
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
        let boothOwn = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID, designMap: "{\"booth\":true}")
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
        #expect(merged.designMap == "{\"booth\":true}")
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
        #expect(settings.lyricsImportThemeId == nil)
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
        let text = try source("LibraryView.swift")
        #expect(!text.contains("\"makeSlides.designMap\""), "LibraryView.swift reads this Mac's design map")
        #expect(!text.contains("LyricsImportDefaults"), "LibraryView.swift reads this Mac's theme")
    }

    @Test func lyricImportsBuildOnThePickedDesignAndAReflowKeepsIt() throws {
        let text = try source("LibraryView.swift")
        #expect(text.contains("slideBuilding.lyricsDesign"), "LibraryView.swift reads the church's lyric design")
        #expect(text.contains("themeSlideName: design"), "LibraryView.swift builds on it")
        #expect(text.contains("LyricsThemeChooser.lyrics("), "LibraryView.swift picks it in the explorer")
        #expect(try source("SlideEditorModel.swift").contains("themeSlideName: Reflow.lyricDesign(of: presentation.slides)"))
    }
}
