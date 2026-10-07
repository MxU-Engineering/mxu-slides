import XCTest
@testable import PresenterCore

final class KeyboardControlTests: XCTestCase {

    func testChordDisplayAndNormalization() {
        XCTAssertEqual(KeyChord("B", command: true).display, "⌘B")
        XCTAssertEqual(KeyChord("f1").display, "F1")
        XCTAssertEqual(KeyChord("left").display, "←")
        XCTAssertEqual(
            KeyChord("s", command: true, option: true, control: true, shift: true).display,
            "⌃⌥⇧⌘S")

        XCTAssertTrue(KeyChord("esc").matches(KeyChord("escape")))
        XCTAssertTrue(KeyChord("enter").matches(KeyChord("return")))
    }

    func testChordMatchingIgnoresNilVsFalseModifiers() {
        var stored = KeyChord("c")
        stored.command = false 
        XCTAssertTrue(stored.matches(KeyChord("c")))
        XCTAssertFalse(KeyChord("c", command: true).matches(KeyChord("c")))
    }

    func testChordRoundTripsThroughJSON() throws {
        let chord = KeyChord("n", command: true, shift: true)
        let decoded = try JSONDecoder().decode(
            KeyChord.self, from: JSONEncoder().encode(chord))
        XCTAssertTrue(decoded.matches(chord))
    }

    func testDefaultsApplyWithEmptyMap() {
        let map = KeyCommandMap()
        XCTAssertEqual(map.chords(for: .clearAll).map(\.key), ["f1"])
        XCTAssertEqual(map.chords(for: .nextSlide).count, 3)
        XCTAssertFalse(map.isCustomized(.clearAll))
    }

    func testOverrideUnbindAndReset() {
        var map = KeyCommandMap()
        map.setChord(KeyChord("f8"), for: .clearMedia)
        XCTAssertEqual(map.chords(for: .clearMedia).map(\.key), ["f8"])
        XCTAssertTrue(map.isCustomized(.clearMedia))

        map.setChord(nil, for: .clearAll)
        XCTAssertEqual(map.chords(for: .clearAll), [])
        XCTAssertTrue(map.isCustomized(.clearAll))

        map.resetToDefault(.clearAll)
        map.resetToDefault(.clearMedia)
        XCTAssertEqual(map.chords, [:])
    }

    func testRecordingTheSingleDefaultClearsTheOverride() {
        var map = KeyCommandMap()
        map.setChord(KeyChord("F2"), for: .clearSlides)
        XCTAssertFalse(map.isCustomized(.clearSlides))

        map.setChord(nil, for: .newService)
        XCTAssertFalse(map.isCustomized(.newService))
    }

    func testUnbindSurvivesJSONRoundTrip() throws {
        var map = KeyCommandMap()
        map.setChord(nil, for: .clearAll)
        let decoded = try JSONDecoder().decode(
            KeyCommandMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded.chords(for: .clearAll), [])
        XCTAssertTrue(decoded.isCustomized(.clearAll))
    }

    func testResolveHonorsScopes() {
        let map = KeyCommandMap()

        XCTAssertEqual(
            map.resolve(chord: KeyChord("f1"), activeScopes: [.present]),
            .command(.clearAll))

        XCTAssertNil(map.resolve(chord: KeyChord("f1"), activeScopes: [.editor]))

        XCTAssertEqual(
            map.resolve(chord: KeyChord("n", command: true), activeScopes: [.editor]),
            .command(.newPresentation))
    }

    func testNarrowScopeBeatsAnywhereOnSharedChord() {
        var map = KeyCommandMap()

        map.setChord(KeyChord("j", command: true), for: .nextSlide)
        map.setChord(KeyChord("j", command: true), for: .newService)
        XCTAssertEqual(
            map.resolve(chord: KeyChord("j", command: true), activeScopes: [.present]),
            .command(.nextSlide))

        XCTAssertEqual(
            map.resolve(chord: KeyChord("j", command: true), activeScopes: [.editor]),
            .command(.newService))
    }

    func testComboBindingsResolveInPresent() {
        var map = KeyCommandMap()
        map.setChord(KeyChord("f9"), forComboID: "combo-1")
        XCTAssertEqual(map.boundComboIDs, ["combo-1"])
        XCTAssertEqual(
            map.resolve(chord: KeyChord("f9"), activeScopes: [.present]),
            .generated(GeneratedKey(.combo, "combo-1")))
        XCTAssertNil(map.resolve(chord: KeyChord("f9"), activeScopes: [.editor]))
        map.setChord(nil, forComboID: "combo-1")
        XCTAssertEqual(map.boundComboIDs, [])
    }

    func testGeneratedKeyParsingRoundTrips() {
        let key = GeneratedKey(.outputPreset, "preset-1")
        XCTAssertEqual(key.mapKey, "preset.preset-1")
        XCTAssertEqual(GeneratedKey.parse("preset.preset-1"), key)
        XCTAssertEqual(
            GeneratedKey.parse("settings.streamRecord/presets"),
            GeneratedKey(.settingsPage, "streamRecord/presets"))

        XCTAssertNil(GeneratedKey.parse(KeyCommand.nextSlide.rawValue))
        XCTAssertNil(GeneratedKey.parse("dmx.fixture-9"))
    }

    func testGeneratedScopesFollowTheirKind() {
        var map = KeyCommandMap()

        map.setChord(KeyChord("f8"), for: GeneratedKey(.outputPreset, "sunday"))
        XCTAssertEqual(
            map.resolve(chord: KeyChord("f8"), activeScopes: [.present]),
            .generated(GeneratedKey(.outputPreset, "sunday")))
        XCTAssertNil(map.resolve(chord: KeyChord("f8"), activeScopes: []))

        map.setChord(
            KeyChord("m", command: true, control: true),
            for: GeneratedKey(.settingsPage, "midi"))
        XCTAssertEqual(
            map.resolve(chord: KeyChord("m", command: true, control: true), activeScopes: []),
            .generated(GeneratedKey(.settingsPage, "midi")))

        map.setChord(
            KeyChord("m", command: true, control: true),
            for: GeneratedKey(.timerStart, "t1"))
        XCTAssertEqual(
            map.resolve(
                chord: KeyChord("m", command: true, control: true),
                activeScopes: [.present]),
            .generated(GeneratedKey(.timerStart, "t1")))

        XCTAssertTrue(map.conflictedKeys().contains("settings.midi"))
        XCTAssertTrue(map.conflictedKeys().contains("timerstart.t1"))
    }

    func testConflictsAreScopeAware() {
        var map = KeyCommandMap()

        map.setChord(KeyChord("f1"), for: .clearMedia)
        var conflicted = map.conflictedKeys()
        XCTAssertTrue(conflicted.contains(KeyCommand.clearAll.rawValue))
        XCTAssertTrue(conflicted.contains(KeyCommand.clearMedia.rawValue))

        map = KeyCommandMap()
        map.setChord(KeyChord("b", command: true), for: .previousSlide)
        conflicted = map.conflictedKeys()
        XCTAssertFalse(conflicted.contains(KeyCommand.boldSelection.rawValue))

        map = KeyCommandMap()
        map.setChord(KeyChord("1", command: true), for: .nextSlide)
        conflicted = map.conflictedKeys()
        XCTAssertTrue(conflicted.contains(KeyCommand.modePresent.rawValue))
        XCTAssertTrue(conflicted.contains(KeyCommand.nextSlide.rawValue))
    }

    func testStockDefaultsCarryNoConflicts() {
        XCTAssertEqual(KeyCommandMap().conflictedKeys(), [])
    }

    func testToggleRightPanelsShipsBoundAnywhere() {
        XCTAssertEqual(
            KeyCommand.toggleRightPanels.defaultChords,
            [KeyChord("r", command: true, control: true)])
        XCTAssertEqual(KeyCommand.toggleRightPanels.scope, .anywhere)
        XCTAssertEqual(KeyCommand.toggleRightPanels.displayName, "Toggle Right Panels")
    }

    func testEffectiveHotKeyFallsBackToSeeds() {
        let chorus = GroupDefinition(id: "chorus", name: "Chorus", colorHex: "#CC004EFF")
        XCTAssertEqual(GroupPalette.effectiveHotKey(for: chorus), "c")

        let verse2 = GroupDefinition(id: "v2", name: "Verse 2", colorHex: "#005999FF")
        XCTAssertEqual(GroupPalette.effectiveHotKey(for: verse2), "s")
    }

    func testEmptyHotKeyIsExplicitlyNone() {
        var chorus = GroupDefinition(id: "chorus", name: "Chorus", colorHex: "#CC004EFF")
        chorus.hotKey = ""
        XCTAssertNil(GroupPalette.effectiveHotKey(for: chorus))
        chorus.hotKey = "Q"
        XCTAssertEqual(GroupPalette.effectiveHotKey(for: chorus), "q")
    }

    func testFillUnsetHotKeysIsFirstImportWins() {
        var palette = GroupPalette.defaults

        palette.groups[7].hotKey = "" 
        palette.groups[12].hotKey = "q" 
        palette.fillUnsetHotKeys(imported: [
            "chorus": "y", 
            "bridge": "w", 
            "tag": "t", 
            "intro": "j", 
            "unknowngroup": "u", 
            "vamp": "5", 
        ])
        XCTAssertEqual(palette.groups[7].hotKey, "")
        XCTAssertEqual(palette.groups[12].hotKey, "q")
        XCTAssertNil(palette.groups.first { $0.name == "Tag" }?.hotKey)
        XCTAssertEqual(palette.groups.first { $0.name == "Intro" }?.hotKey, "j")
        XCTAssertNil(palette.groups.first { $0.name == "Vamp" }?.hotKey)

        let intro = palette.groups.first { $0.name == "Intro" }!
        XCTAssertEqual(GroupPalette.effectiveHotKey(for: intro), "j")
    }

    func testHotKeyTargetsPreservePaletteOrderAndDedupe() {
        let palette = GroupPalette.defaults
        let targets = palette.hotKeyTargets

        XCTAssertEqual(targets["a"], ["verse", "verse1"])
        XCTAssertEqual(targets["c"], ["chorus", "chorus1"])

        XCTAssertNil(targets.values.first { $0.contains("blank") })
    }
}
