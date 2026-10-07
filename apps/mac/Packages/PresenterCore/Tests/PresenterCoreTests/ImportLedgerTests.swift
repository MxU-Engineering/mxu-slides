import XCTest
@testable import PresenterCore

final class ImportLedgerTests: XCTestCase {

    func testFingerprintIsDeterministicAndContentSensitive() {
        var combo = ActionCombo(id: "c1", name: "Baptism", actions: [])
        let hash = ImportFingerprint.hash(combo)
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash, ImportFingerprint.hash(combo), "same content, same hash")
        combo.name = "Baptism 2"
        XCTAssertNotEqual(hash, ImportFingerprint.hash(combo), "any edit breaks equality")
    }

    func testLedgerStampAndUneditedComparison() {
        var ledger = ImportLedger(id: ImportLedger.wellKnownID, entries: [])
        ledger.stamp("doc-1", "abc")
        XCTAssertEqual(ledger.value(for: "doc-1"), "abc")

        ledger.stamp("doc-1", "def")
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.value(for: "doc-1"), "def")

        XCTAssertTrue(ledger.isUnedited(docId: "doc-1", currentHash: "def"))

        XCTAssertFalse(ledger.isUnedited(docId: "doc-1", currentHash: "zzz"))
        XCTAssertFalse(ledger.isUnedited(docId: "doc-2", currentHash: "def"))
        XCTAssertFalse(ledger.isUnedited(docId: "doc-1", currentHash: nil))
    }

    private func ledger(stamping: [String: String] = [:]) -> ImportLedger {
        var ledger = ImportLedger(id: ImportLedger.wellKnownID, entries: [])
        for (name, letter) in stamping {
            ledger.stamp(ImportLedger.hotKeyPrefix + name, letter)
        }
        return ledger
    }

    func testHotKeysKeepMineFillsUnsetOnly() {
        var palette = GroupPalette.defaults
        palette.groups[7].hotKey = "" 
        let stamps = palette.applyImportedHotKeys(
            ["chorus": "y", "intro": "j"], policy: .keepMine, ledger: ledger())
        XCTAssertEqual(palette.groups[7].hotKey, "", "explicit none survives")
        XCTAssertEqual(palette.groups.first { $0.name == "Intro" }?.hotKey, "j")
        XCTAssertEqual(stamps.map(\.docId), ["hotkey.intro"])
        XCTAssertEqual(stamps.map(\.hash), ["j"])
    }

    func testHotKeysUpdateUneditedOverwritesOnlyStampedLetters() {
        var palette = GroupPalette.defaults

        palette.groups.first { $0.name == "Intro" }.map { _ in }
        let introIndex = palette.groups.firstIndex { $0.name == "Intro" }!
        let bridgeIndex = palette.groups.firstIndex { $0.name == "Bridge" }!
        palette.groups[introIndex].hotKey = "j"
        palette.groups[bridgeIndex].hotKey = "q"
        let stamps = palette.applyImportedHotKeys(
            ["intro": "k", "bridge": "w"],
            policy: .updateUnedited,
            ledger: ledger(stamping: ["intro": "j"]))
        XCTAssertEqual(palette.groups[introIndex].hotKey, "k", "stamped = untouched → updates")
        XCTAssertEqual(palette.groups[bridgeIndex].hotKey, "q", "operator's letter survives")
        XCTAssertEqual(stamps.map(\.docId), ["hotkey.intro"])
    }

    func testHotKeysReplaceWinsOutrightAndSeedEqualClearsToDefault() {
        var palette = GroupPalette.defaults
        let chorusIndex = palette.groups.firstIndex { $0.name == "Chorus" }!
        let tagIndex = palette.groups.firstIndex { $0.name == "Tag" }!
        palette.groups[chorusIndex].hotKey = "" 
        palette.groups[tagIndex].hotKey = "y" 
        _ = palette.applyImportedHotKeys(
            ["chorus": "c", "tag": "t"], policy: .replace, ledger: ledger())

        XCTAssertNil(palette.groups[chorusIndex].hotKey)
        XCTAssertNil(palette.groups[tagIndex].hotKey)
        XCTAssertEqual(GroupPalette.effectiveHotKey(for: palette.groups[chorusIndex]), "c")
    }
}
