import Foundation
import Testing
@testable import PresenterCore

@Suite struct LibraryViewOptionsTests {
    private func entry(_ id: String, kind: DocumentKind = .presentation, subkind: String = "", updated: Double = 0, used: Double? = nil) -> LibraryIndex.Entry {
        LibraryIndex.Entry(id: id, kind: kind, subkind: subkind, name: id, updatedAt: Date(timeIntervalSince1970: updated),
                           lastUsedAt: used.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func sortByNameKeepsTheIndexOrderAndTheOthersPutNewestFirst() {
        let byName = [entry("a", updated: 1, used: 5), entry("b", updated: 3), entry("c", updated: 3, used: 9)]
        #expect(LibrarySort.name.ordered(byName).map(\.id) == ["a", "b", "c"])
        #expect(LibrarySort.dateModified.ordered(byName).map(\.id) == ["b", "c", "a"], "a tie keeps name order")
        #expect(LibrarySort.recentlyUsed.ordered(byName).map(\.id) == ["c", "a", "b"], "never used sorts last")
        #expect(LibrarySort.allCases.map(\.title) == ["Name", "Date Modified", "Recently Used", "Date Added"])
    }

    @Test func dateAddedPutsNewestImportsFirstAndOnlyMediaOffersIt() {
        let added: [String: Date] = ["b": Date(timeIntervalSince1970: 10), "c": Date(timeIntervalSince1970: 20)]
        let byName = [entry("a", kind: .media), entry("b", kind: .media), entry("c", kind: .media)]
        #expect(LibrarySort.dateAdded.ordered(byName, addedAt: { added[$0] }).map(\.id) == ["c", "b", "a"])
        #expect(LibrarySort.dateAdded.merged(
            LibrarySort.dateAdded.ordered(byName, addedAt: { added[$0] }),
            cloud: [TeamCloudItem(kind: .media, id: "c-x", name: "0 cloud", folder: "", updatedAt: nil)],
            addedAt: { added[$0] }
        ).map(\.id) == ["c", "b", "c-x", "a"], "a listed row without a file sits with the undated, by name")
        #expect(LibrarySort.choices(for: .media).contains(.dateAdded))
        #expect(!LibrarySort.choices(for: .presentation).contains(.dateAdded))
    }

    @Test func thePickerSortsLastUsedBestMatchOrDateAdded() {
        let ranked = [entry("rank1", kind: .media), entry("rank2", kind: .media, used: 5), entry("rank3", kind: .media, used: 9)]
        let added: [String: Date] = ["rank1": Date(timeIntervalSince1970: 30), "rank3": Date(timeIntervalSince1970: 10)]
        #expect(MediaPickerSort.lastUsed.ordered(ranked, typed: true, addedAt: { added[$0] }).map(\.id) == ["rank3", "rank2", "rank1"])
        #expect(MediaPickerSort.bestMatch.ordered(ranked, typed: true, addedAt: { added[$0] }).map(\.id) == ["rank1", "rank2", "rank3"])
        #expect(MediaPickerSort.bestMatch.ordered(ranked, typed: false, addedAt: { added[$0] }).map(\.id) == ["rank3", "rank2", "rank1"],
                "nothing typed: the recency list the picker always opened on")
        #expect(MediaPickerSort.dateAdded.ordered(ranked, typed: true, addedAt: { added[$0] }).map(\.id) == ["rank1", "rank3", "rank2"])
    }

    @Test func cloudItemsMergeIntoTheListInItsOrder() {
        func cloud(_ name: String, updated: Double? = nil) -> TeamCloudItem {
            TeamCloudItem(kind: .presentation, id: "c-" + name, name: name, folder: "", updatedAt: updated.map { Date(timeIntervalSince1970: $0) })
        }
        let held = [entry("Battle", updated: 1, used: 5), entry("Who Else", updated: 4), entry("export", updated: 2)]
        let clouds = [cloud("What a God", updated: 3), cloud("Ancient Gates", updated: 5), cloud("Zion")]
        #expect(LibrarySort.name.merged(held, cloud: clouds).map(\.id) == ["c-Ancient Gates", "Battle", "c-What a God", "Who Else", "c-Zion", "export"],
                "A–Z by the index's byte order, downloaded or not")
        #expect(LibrarySort.dateModified.merged(LibrarySort.dateModified.ordered(held), cloud: clouds).map(\.id)
                == ["c-Ancient Gates", "Who Else", "c-What a God", "export", "Battle", "c-Zion"], "no date sorts last")
        #expect(LibrarySort.recentlyUsed.merged(LibrarySort.recentlyUsed.ordered(held), cloud: clouds).map(\.id)
                == ["Battle", "c-Ancient Gates", "c-What a God", "Who Else", "c-Zion", "export"], "cloud items sit among the never used, by name")
        #expect(LibrarySort.name.merged([], cloud: clouds).map(\.id) == ["c-Ancient Gates", "c-What a God", "c-Zion"])
        #expect(LibrarySort.name.merged([entry("Same")], cloud: [cloud("Same")]).map(\.id) == ["Same", "c-Same"], "a tie goes to the held entry")
    }

    @Test func upcomingIsEveryServiceDatedTodayOrLater() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 20))!
        let services = [entry("past", kind: .service, subkind: "2026-09-26"), entry("today", kind: .service, subkind: "2026-09-27"),
                        entry("far", kind: .service, subkind: "2027-06-01"), entry("undated", kind: .service)]
        #expect(UpcomingUse.services(services, today: today, calendar: calendar) == ["today", "far"], "no limit on how far ahead")
    }

    @Test func aServiceUsesItsItemsAndTheirNotesDecks() {
        var deck = ServiceItem(id: "i1", itemKind: .presentation, name: "Song", refId: "deck")
        deck.mxuMessageNotesDeckDocId = "notes"
        let service = Service(id: "sv", name: "", serviceDate: "", items: [deck, ServiceItem(id: "i2", itemKind: .header, name: "Welcome", refId: "")])
        #expect(UpcomingUse.references(of: service) == ["deck", "notes"])
    }
}
