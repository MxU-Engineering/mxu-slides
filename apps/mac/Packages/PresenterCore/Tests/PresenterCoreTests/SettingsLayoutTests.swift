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
            "edit.hideSidebar": "edit",
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

    @Test func headingsNeverRepeatTheirOnlyRow() {
        let present = SettingsLayout.page(id: "present")
        #expect(present?.sections.compactMap(\.title) == ["Transitions", "Songs", "Music", "Service times", "Present view", "Layouts", "Volunteers"])
        for page in SettingsLayout.pages {
            for section in page.sections where section.rows.count == 1 {
                #expect(section.title != "Groups" && section.title != "Appearance", "\(page.id)")
            }
        }
    }

    @Test func noHeadingRepeatsARowTitle() throws {
        let file = try #require(SourceSweep.app().file("SettingsView.swift"))
        let titles = Dictionary(
            file.text.matches(of: /SettingsRowSpec\(\s*id: "([^"]+)",\s*title: "([^"]+)"/).map { (String($0.output.1), String($0.output.2)) },
            uniquingKeysWith: { first, _ in first })
        for page in SettingsLayout.pages {
            for section in page.sections {
                if let heading = section.title {
                    for row in section.rows {
                        #expect(titles[row]?.lowercased() != heading.lowercased(), "\(row) under \(heading)")
                    }
                }
            }
        }
    }

    @Test func aOneComputerChurchSeesNoTags() {
        for row in SettingsLayout.pages.flatMap(\.rows) {
            #expect(SettingsLayout.tag(forRow: row, otherComputersOnTeam: 0, othersOnThisSetup: 0) == nil, "\(row)")
        }
    }

    @Test func teamRowsSayTeamOnceThereAreOtherComputers() {
        #expect(SettingsLayout.tag(forRow: "groups.palette", otherComputersOnTeam: 2, othersOnThisSetup: 0) == .team)
        #expect(SettingsLayout.tag(forRow: "present.slideTransition", otherComputersOnTeam: 2, othersOnThisSetup: 0) == nil,
                "another computer with its own setup doesn't share transitions")
        #expect(SettingsLayout.tag(forRow: "appearance.scheme", otherComputersOnTeam: 2, othersOnThisSetup: 2) == nil, "this computer's own")
    }

    @Test func setupRowsSayWhoShareTheSetup() {
        let tag = SettingsLayout.tag(forRow: "present.slideTransition", otherComputersOnTeam: 1, othersOnThisSetup: 1)
        #expect(tag == .sharedOnSetup(others: 1))
        #expect(tag?.words == "Shared with 1 other computer")
    }

    @Test func linkedKindsNameTheOtherComputer() {
        func tag(_ mode: WorkspaceLinkMode) -> SettingsLayout.Tag? {
            SettingsLayout.tag(forRow: "screens.outputPresets", otherComputersOnTeam: 1, othersOnThisSetup: 0, link: (mode, "Booth Mac"))
        }
        #expect(tag(.twoWay)?.words == "Shared with Booth Mac")
        #expect(tag(.oneWay)?.words == "From Booth Mac")
        #expect(tag(.oneWay)?.help == "Only Booth Mac can change these.")
        #expect(tag(.namesOnly)?.words == "Names from Booth Mac")
        #expect(tag(.thisWorkspaceOnly) == nil)
        #expect(SettingsLayout.tag(forRow: "screens.outputPresets", otherComputersOnTeam: 1, othersOnThisSetup: 0,
                                   link: (.thisWorkspaceOnly, "Booth Mac"), followedBy: ["Lobby Mac"]) == .sharedWith("Lobby Mac"))
    }

    @Test func tableAndSettingsAgree() throws {
        let file = try #require(SourceSweep.app().file("SettingsView.swift"))
        let declared = Set(file.text.matches(of: /SettingsRowSpec\(\s*id: "([^"]+)"/).map { String($0.output.1) })
        let placed = Set(SettingsLayout.pages.flatMap(\.rows))
        #expect(declared.subtracting(placed).isEmpty, "not placed: \(declared.subtracting(placed).sorted())")
        #expect(placed.subtracting(declared).isEmpty, "placed but not declared: \(placed.subtracting(declared).sorted())")
    }
}
