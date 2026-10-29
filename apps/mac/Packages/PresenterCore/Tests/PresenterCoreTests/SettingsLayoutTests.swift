import Foundation
import PresenterCore
import Testing

@Suite struct SettingsLayoutTests {
    @Test func sidebarOrderIsS13() {
        #expect(SettingsLayout.pages.map(\.id) == [
            "general", "present", "edit", "screens",
            "avInputs", "streamRecord", "midi", "keyboard", "bible", "api",
        ])
    }

    @Test func everyRowLivesOnOnePage() {
        let rows = SettingsLayout.pages.flatMap(\.rows)
        #expect(rows.count == Set(rows).count)
    }

    @Test func rowsLandOnTheirPages() {
        let expected: [String: String] = [
            "present.nextSkipsBlanks": "screens",
            "present.defaultAnimations": "edit",
            "groups.palette": "edit",
            "edit.hideSidebar": "edit",
            "appearance.scheme": "general",
            "bible.apiBible": "bible",
            "audio.fadeEnabled": "present",
        ]
        for (row, page) in expected {
            #expect(SettingsLayout.page(ofRow: row) == page, "\(row)")
        }
    }

    @Test func movedPagesOpenWhereTheirRowsWent() {
        #expect(SettingsLayout.pageID(forStored: "appearance") == "general")
        #expect(SettingsLayout.pageID(forStored: "groups") == "edit")
        #expect(SettingsLayout.pageID(forStored: "audio") == "present")
        #expect(SettingsLayout.pageID(forStored: "midi") == "midi")
        let ids = Set(SettingsLayout.pages.map(\.id))
        #expect(SettingsLayout.movedPages.values.allSatisfy(ids.contains))
    }

    @Test func rowsSortByPageThenRow() {
        #expect(SettingsLayout.order(ofRow: "appearance.scheme") < SettingsLayout.order(ofRow: "present.slideTransition"))
        #expect(SettingsLayout.order(ofRow: "present.slideTransition") < SettingsLayout.order(ofRow: "present.mediaTransition"))
        #expect(SettingsLayout.order(ofRow: "nowhere") == .max)
    }

    @Test func headingsNeverRepeatTheirOnlyRow() {
        let present = SettingsLayout.page(id: "present")
        #expect(present?.sections.compactMap(\.title) == ["Transitions", "While presenting", "Present view", "Layouts", "Volunteers"])
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

    @Test func tableAndSettingsAgree() throws {
        let file = try #require(SourceSweep.app().file("SettingsView.swift"))
        let declared = Set(file.text.matches(of: /SettingsRowSpec\(\s*id: "([^"]+)"/).map { String($0.output.1) })
        let placed = Set(SettingsLayout.pages.flatMap(\.rows))
        #expect(declared.subtracting(placed).isEmpty, "not placed: \(declared.subtracting(placed).sorted())")
        #expect(placed.subtracting(declared).isEmpty, "placed but not declared: \(placed.subtracting(declared).sorted())")
    }
}
