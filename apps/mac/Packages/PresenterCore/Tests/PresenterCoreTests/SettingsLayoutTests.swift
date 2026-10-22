import Foundation
import PresenterCore
import Testing

@Suite struct SettingsLayoutTests {
    @Test func sidebarOrderIsS13() {
        #expect(SettingsLayout.pages.map(\.id) == [
            "account", "general", "sync", "present", "edit", "screens",
            "avInputs", "streamRecord", "midi", "keyboard", "api",
        ])
    }

    @Test func everyRowLivesOnOnePage() {
        let rows = SettingsLayout.pages.flatMap(\.rows)
        #expect(rows.count == Set(rows).count)
    }

    @Test func rowsLandWhereCodyPutThem() {
        let expected: [String: String] = [
            "present.nextSkipsBlanks": "screens",
            "present.defaultAnimations": "edit",
            "account.messageNotesTheme": "edit",
            "groups.palette": "edit",
            "appearance.scheme": "general",
            "updates.automatic": "general",
            "station.workspaceLinks": "sync",
            "station.room": "account",
            "station.campus": "account",
            "station.enabled": "api",
            "station.remote": "api",
            "audio.fadeEnabled": "present",
            "account.autoSwitchServiceTimes": "present",
        ]
        for (row, page) in expected {
            #expect(SettingsLayout.page(ofRow: row) == page, "\(row)")
        }
    }

    @Test func movedPagesOpenWhereTheirRowsWent() {
        #expect(SettingsLayout.pageID(forStored: "appearance") == "general")
        #expect(SettingsLayout.pageID(forStored: "updates") == "general")
        #expect(SettingsLayout.pageID(forStored: "groups") == "edit")
        #expect(SettingsLayout.pageID(forStored: "audio") == "present")
        #expect(SettingsLayout.pageID(forStored: "sync") == "sync")
        let ids = Set(SettingsLayout.pages.map(\.id))
        #expect(SettingsLayout.movedPages.values.allSatisfy(ids.contains))
    }

    @Test func rowsSortByPageThenRow() {
        #expect(SettingsLayout.order(ofRow: "account.session") < SettingsLayout.order(ofRow: "appearance.scheme"))
        #expect(SettingsLayout.order(ofRow: "present.slideTransition") < SettingsLayout.order(ofRow: "present.mediaTransition"))
        #expect(SettingsLayout.order(ofRow: "nowhere") == .max)
    }

    @Test func tableAndSettingsAgree() throws {
        let file = try #require(SourceSweep.app().file("SettingsView.swift"))
        let declared = Set(file.text.matches(of: /SettingsRowSpec\(\s*id: "([^"]+)"/).map { String($0.output.1) })
        let placed = Set(SettingsLayout.pages.flatMap(\.rows))
        #expect(declared.subtracting(placed).isEmpty, "not placed: \(declared.subtracting(placed).sorted())")
        #expect(placed.subtracting(declared).isEmpty, "placed but not declared: \(placed.subtracting(declared).sorted())")
    }
}
