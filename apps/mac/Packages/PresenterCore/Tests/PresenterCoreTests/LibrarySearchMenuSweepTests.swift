import Foundation
import Testing

@Suite struct LibrarySearchMenuSweepTests {
    @Test func searchHitsCarryTheRowMenu() throws {
        let file = try #require(SourceSweep.app().file("LibraryView.swift"))
        let start = try #require(file.codeLines.firstIndex { $0.contains("private func searchHitRow(") })
        let body = file.codeLines[file.block(from: start)].joined(separator: "\n")
        #expect(file.codeLines[start].contains("menus: RowMenuLists"), "the pass hands the row its menu lists")
        #expect(body.contains("entryMenu(hit.entry, menus: menus)"), "the row's menu is the library row's")
        let raw = file.lines[file.block(from: start)].joined(separator: "\n")
        #expect(raw.contains("Button(\"Show in Library\")"), "plus the way back to where it lives")
        #expect(body.components(separatedBy: "Button(").count == 2, "no other menu of its own")
    }
}
