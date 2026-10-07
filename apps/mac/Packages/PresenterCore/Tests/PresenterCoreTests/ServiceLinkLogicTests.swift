import XCTest
@testable import PresenterCore

final class ServiceLinkLogicTests: XCTestCase {
    private func infoItem(
        name: String, songTitle: String? = nil, ccli: Int? = nil
    ) -> ServiceItem {
        ServiceItem(
            id: "item-1", itemKind: .info, name: name, refId: "",
            mxuItemHexId: "mxu-1", mxuSongTitle: songTitle, mxuCcliNumber: ccli)
    }

    private func rules(_ list: [ServiceLinkRule] = []) -> ServiceLinkRules {
        ServiceLinkRules(id: ServiceLinkRules.wellKnownID, rules: list)
    }

    func testSongKeyAppliesOnceToAChordedLinkedSong() {

        var row = ServiceItem(id: "r", itemKind: .presentation, name: "Way Maker", refId: "deck", mxuSongKey: "A")
        XCTAssertEqual(ServiceLinkLogic.pendingSongKey(for: row), "A")
        row.mxuSongKeyApplied = "A"
        XCTAssertNil(ServiceLinkLogic.pendingSongKey(for: row), "applied: the operator's own pick is left alone")
        row.mxuSongKey = "B"
        XCTAssertNil(ServiceLinkLogic.pendingSongKey(for: row), "the key moved: the pick stays")
        var unlinked = row
        unlinked.itemKind = .info
        unlinked.refId = ""
        XCTAssertNil(ServiceLinkLogic.pendingSongKey(for: unlinked))
        var keyless = row
        keyless.mxuSongKey = nil
        XCTAssertNil(ServiceLinkLogic.pendingSongKey(for: keyless))

        let chorded = Presentation(
            id: "deck", name: "Way Maker", presentationKind: .song, themeId: "t",
            slides: [Slide(id: "s", name: "", objects: [
                SlideObject(id: "o", objectKind: .text, name: "", text: "Way maker",
                            chords: [ChordPlacement(line: 0, column: 0, symbol: "G")]),
            ])],
            musicKey: "G")
        XCTAssertEqual(
            ServiceLinkLogic.songKeyUpdate(playing: "B", presentation: chorded),
            ServiceLinkLogic.SongKeyUpdate(displayKey: "B", appliedKey: "B"))
        XCTAssertEqual(
            ServiceLinkLogic.songKeyUpdate(playing: "Em", presentation: chorded),
            ServiceLinkLogic.SongKeyUpdate(displayKey: nil, appliedKey: "Em"),
            "the written key (by relative) stores as nil, the header's Original rule")
        var unkeyed = chorded
        unkeyed.musicKey = nil
        XCTAssertNil(ServiceLinkLogic.songKeyUpdate(playing: "B", presentation: unkeyed), "no written key: can't transpose")
        var plain = chorded
        plain.slides[0].objects[0].chords = nil
        XCTAssertNil(ServiceLinkLogic.songKeyUpdate(playing: "B", presentation: plain), "no chords: nothing to set")
    }

    func testNormalizeStripsCaseAndPunctuation() {
        XCTAssertEqual(ServiceLinkLogic.normalize("  Way Maker!  "), "way maker")
        XCTAssertEqual(ServiceLinkLogic.normalize("WAY   MAKER"), "way maker")
        XCTAssertEqual(ServiceLinkLogic.normalize("Way-Maker (Live)"), "way maker live")
    }

    func testStickyRuleWinsButOnlyWithinItsServiceType() {

        let ruleSet = rules([
            ServiceLinkRule(id: "r1", normalizedName: "way maker", serviceTypeName: "Weekend", itemKind: .presentation, refId: "weekend"),
        ])
        let candidates = [ServiceLinkLogic.Candidate(id: "by-ccli", name: "Way Maker", ccliNumber: 7)]

        XCTAssertEqual(
            ServiceLinkLogic.resolve(
                item: infoItem(name: "Way Maker!", songTitle: "Way Maker", ccli: 7),
                serviceTypeName: "Weekend", rules: ruleSet, candidates: candidates),
            .link(itemKind: .presentation, refId: "weekend"))

        XCTAssertEqual(
            ServiceLinkLogic.resolve(
                item: infoItem(name: "Way Maker", songTitle: "Way Maker", ccli: 7),
                serviceTypeName: "Youth", rules: ruleSet, candidates: candidates),
            .link(itemKind: .presentation, refId: "by-ccli"))
        XCTAssertEqual(
            ServiceLinkLogic.resolve(
                item: infoItem(name: "Way Maker"),
                serviceTypeName: "Youth", rules: ruleSet, candidates: candidates),
            .none)
    }

    func testCcliExactMatchLinksOnlyWhenUnambiguous() {
        let one = [ServiceLinkLogic.Candidate(id: "p1", name: "Different Name", ccliNumber: 7_115_744)]
        XCTAssertEqual(
            ServiceLinkLogic.resolve(
                item: infoItem(name: "Way Maker", songTitle: "Way Maker", ccli: 7_115_744),
                serviceTypeName: nil, rules: rules(), candidates: one),
            .link(itemKind: .presentation, refId: "p1"))

        let two = one + [ServiceLinkLogic.Candidate(id: "p2", name: "Way Maker Alt", ccliNumber: 7_115_744)]
        XCTAssertEqual(
            ServiceLinkLogic.resolve(
                item: infoItem(name: "Way Maker", songTitle: "Way Maker", ccli: 7_115_744),
                serviceTypeName: nil, rules: rules(), candidates: two),
            .none)
    }

    func testTitleMatchesNameOrCcliSongTitleUnambiguously() {
        let candidates = [
            ServiceLinkLogic.Candidate(id: "p1", name: "Way Maker (Live)", ccliSongTitle: "Way Maker"),
            ServiceLinkLogic.Candidate(id: "p2", name: "Great Are You Lord"),
        ]
        XCTAssertEqual(
            ServiceLinkLogic.resolve(
                item: infoItem(name: "WAY MAKER", songTitle: "Way Maker"),
                serviceTypeName: nil, rules: rules(), candidates: candidates),
            .link(itemKind: .presentation, refId: "p1"))

        let ambiguous = candidates + [ServiceLinkLogic.Candidate(id: "p3", name: "Way Maker")]
        XCTAssertEqual(
            ServiceLinkLogic.resolve(
                item: infoItem(name: "Way Maker", songTitle: "Way Maker"),
                serviceTypeName: nil, rules: rules(), candidates: ambiguous),
            .none)
    }

    func testNonSongRowsNeverAutoMatchByTitle() {
        let candidates = [ServiceLinkLogic.Candidate(id: "p1", name: "Announcements")]
        XCTAssertEqual(
            ServiceLinkLogic.resolve(
                item: infoItem(name: "Announcements"),
                serviceTypeName: nil, rules: rules(), candidates: candidates),
            .none)
    }

    func testSuggestionsNameMatchNonSongRowsButNotOnSharedWordsAlone() {

        let candidates = [
            ServiceLinkLogic.Candidate(id: "p1", name: "Song of Ascent"),
            ServiceLinkLogic.Candidate(id: "p2", name: "One Thing Remains"),
            ServiceLinkLogic.Candidate(id: "ann", name: "Announcements"),
        ]
        XCTAssertEqual(
            ServiceLinkLogic.suggestions(
                for: infoItem(name: "Song One"),
                serviceTypeName: nil, rules: rules(), candidates: candidates),
            [])
        XCTAssertEqual(
            ServiceLinkLogic.suggestions(
                for: infoItem(name: "Announcements"),
                serviceTypeName: nil, rules: rules(), candidates: candidates).map(\.id),
            ["ann"])

        let ruleSet = rules([
            ServiceLinkRule(id: "r1", normalizedName: "song one", serviceTypeName: nil, itemKind: .presentation, refId: "p2"),
        ])
        XCTAssertEqual(
            ServiceLinkLogic.suggestions(
                for: infoItem(name: "Song One"),
                serviceTypeName: nil, rules: ruleSet, candidates: candidates).map(\.id),
            ["p2"])
    }

    func testSuggestionsDropSharedWordOnlyHitsButKeepPrefixAndCcli() {
        let candidates = [
            ServiceLinkLogic.Candidate(id: "live", name: "Way Maker (Live)"),
            ServiceLinkLogic.Candidate(id: "other", name: "Make Way"),
            ServiceLinkLogic.Candidate(id: "ccli", name: "Different Title", ccliNumber: 7115744),
        ]
        let ranked = ServiceLinkLogic.suggestions(
            for: infoItem(name: "Way Maker", songTitle: "Way Maker", ccli: 7115744),
            serviceTypeName: nil, rules: rules(), candidates: candidates)
        XCTAssertEqual(ranked.map(\.id), ["ccli", "live"])
    }

    func testStampRuleUpdatesInPlaceAndRemoveRuleDeletes() {
        var ruleSet = rules()
        ServiceLinkLogic.stampRule(
            into: &ruleSet, itemName: "Way Maker!", serviceTypeName: "Weekend",
            itemKind: .presentation, refId: "p1", newID: { "r1" })
        ServiceLinkLogic.stampRule(
            into: &ruleSet, itemName: "way maker", serviceTypeName: "Weekend",
            itemKind: .media, refId: "m1", newID: { "r2" })

        XCTAssertEqual(ruleSet.rules.count, 1)
        XCTAssertEqual(ruleSet.rules[0].refId, "m1")
        XCTAssertEqual(ruleSet.rules[0].itemKind, .media)

        ServiceLinkLogic.stampRule(
            into: &ruleSet, itemName: "Way Maker", serviceTypeName: "Youth",
            itemKind: .presentation, refId: "p9", newID: { "r3" })
        ServiceLinkLogic.removeRule(from: &ruleSet, itemName: "Way Maker", serviceTypeName: "Weekend")
        XCTAssertEqual(ruleSet.rules.map(\.serviceTypeName), ["Youth"])
    }

    func testMatchArrangementByNormalizedName() {
        let arrangements = [
            Arrangement(id: "a1", name: "Default", sectionIds: []),
            Arrangement(id: "a2", name: "Full Band", sectionIds: []),
        ]
        XCTAssertEqual(ServiceLinkLogic.matchArrangement(named: "full band", in: arrangements), "a2")
        XCTAssertNil(ServiceLinkLogic.matchArrangement(named: "Acoustic", in: arrangements))
        XCTAssertNil(ServiceLinkLogic.matchArrangement(named: nil, in: arrangements))
    }
}
