import Foundation
import Testing
@testable import PresenterCore

@Test func theDesignMapRoundTripsAndFallsBackToNameMatching() {
    var map = SlideDesignMap()
    #expect(map.entry(for: .scripture) == nil, "absent = match by name")
    map.set(SlideDesignMap.Entry(themeId: "scripture-theme", themeSlideName: "Verse + Reference"), for: .scripture)
    map.set(SlideDesignMap.Entry(themeId: "deck", themeSlideName: "Points"), for: .points)
    let back = SlideDesignMap.decode(map.encoded())
    #expect(back == map)
    #expect(back.entry(for: .scripture)?.themeSlideName == "Verse + Reference")
    map.set(nil, for: .scripture)
    #expect(map.entry(for: .scripture) == nil && map.entry(for: .points) != nil)
    #expect(SlideDesignMap.decode(nil) == SlideDesignMap() && SlideDesignMap.decode(Data("junk".utf8)) == SlideDesignMap())
    #expect(SlideDesignMap.kinds.first == .title && !SlideDesignMap.kinds.contains(.media) && !SlideDesignMap.kinds.contains(.body))
}

@Test func presetSwitchesAndBlanksRoundTripAndOldSettingsStillDecode() {
    var map = SlideDesignMap()
    #expect(map.preset(for: .scripture) == nil && map.blanks == .none)
    map.setPreset(.preset("side"), for: .scripture)
    map.otherPreset = .preset("full")
    map.blanks = .afterPassage
    map.setPreset(.combo("clear-stream"), for: .blank)
    #expect(map.preset(for: .scripture) == .preset("side"), "the type's own")
    #expect(map.preset(for: .points) == .preset("full"), "all other slides")
    #expect(map.ownPreset(for: .points) == nil)
    let back = SlideDesignMap.decode(map.encoded())
    #expect(back == map)

    let old = SlideDesignMap.decode(Data(#"{"entries":{"scripture":{"themeId":"t","themeSlideName":"Verse"}}}"#.utf8))
    #expect(old.entry(for: .scripture)?.themeSlideName == "Verse" && old.presets.isEmpty && old.blanks == .none && old.otherPreset == nil)

    let migrated = SlideDesignMap.decode(Data(#"{"blankPreset":{"kind":"outputPreset","id":"full"}}"#.utf8))
    #expect(migrated.preset(for: .blank) == .preset("full") && SlideDesignMap.kinds.contains(.blank))

    let action = SlidePresetChoice.preset("side").action()
    #expect(action.kind == .switchOutputPreset && action.presetId == "side" && SlidePresetChoice.preset("side").matches(action))
    let combo = SlidePresetChoice.combo("c").action()
    #expect(combo.kind == .fireCombo && combo.comboId == "c" && !SlidePresetChoice.preset("c").matches(combo))
}

@Test func slideOptionsRoundTripAndMissingKeysAreDefaults() {
    var map = SlideDesignMap()
    #expect(map.options == SlideOptions())
    #expect(!map.options.revealPoints && map.options.scriptureSplit == .fitToBox && map.options.verseNumbers)
    #expect(!map.options.blanksBetweenVerses && map.options.keepUnderlines && map.options.parenthesesToNotes)
    map.options.revealPoints = true
    map.options.scriptureSplit = .oneVerse
    map.options.verseNumbers = false
    #expect(SlideDesignMap.decode(map.encoded()) == map)

    #expect(SlideDesignMap.decode(Data(#"{"entries":{}}"#.utf8)).options == SlideOptions())
    let partial = SlideDesignMap.decode(Data(#"{"options":{"revealPoints":true,"scriptureSplit":"byPhrase"}}"#.utf8))
    #expect(partial.options.revealPoints && partial.options.scriptureSplit == .fitToBox && partial.options.parenthesesToNotes)
}

@Test func ownTypesLiveInTheOptionsWithTheirDesignAndSwitchUnderTheirName() {
    var map = SlideDesignMap()
    #expect(map.canAddOwnType(named: "Announcement") && !map.canAddOwnType(named: "Scripture") && !map.canAddOwnType(named: " "))
    map.options.ownTypes.append(SlideOptions.OwnType(name: "Announcement", split: .line, reveal: true))
    #expect(!map.canAddOwnType(named: "announcement"), "names are one case")
    map.set(SlideDesignMap.Entry(themeId: "t", themeSlideName: "Notice"), forType: "Announcement")
    map.setPreset(.preset("lower"), forType: "Announcement")
    let back = SlideDesignMap.decode(map.encoded())
    #expect(back == map && back.options.ownType(named: "announcement")?.split == .line)
    #expect(back.entry(forType: "Announcement")?.themeSlideName == "Notice" && back.preset(forType: "Announcement") == .preset("lower"))
    #expect(back.preset(forType: "Other") == nil && back.entry(for: .scripture) == nil)

    let partial = SlideDesignMap.decode(Data(#"{"options":{"ownTypes":[{"name":"Notice","split":"byWord"}]}}"#.utf8))
    #expect(partial.options.ownTypes == [SlideOptions.OwnType(name: "Notice")])
    #expect(SlideDesignMap.decode(Data(#"{"options":{}}"#.utf8)).options.ownTypes.isEmpty)

    map.renameOwnType("Announcement", to: "Notice")
    #expect(map.options.ownTypes.map(\.name) == ["Notice"] && map.entry(forType: "Notice")?.themeSlideName == "Notice")
    #expect(map.entry(forType: "Announcement") == nil && map.preset(forType: "Notice") == .preset("lower"))
    map.removeOwnType(named: "Notice")
    #expect(map.options.ownTypes.isEmpty && map.entries.isEmpty && map.presets.isEmpty)
}
