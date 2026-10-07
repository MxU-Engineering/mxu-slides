import Foundation
import Testing

@testable import PresenterCore

@Suite struct PerfScenarioTests {
    @Test func parsesTheScriptsScenarios() {
        #expect(PerfScenario("animate:Editorial Serif/Lower Third") == .animate(theme: "Editorial Serif", layout: "Lower Third"))
        #expect(PerfScenario("edit:Path Text Perf/1/Card") == .edit(deck: "Path Text Perf", slide: 1, object: "Card"))
        #expect(PerfScenario("idle") == .idle)
    }

    @Test func refusesWhatItCannotRun() {
        for spec in ["", "animate", "animate:Editorial Serif", "animate:/Lower Third", "edit:Deck/0/Card",
                     "edit:Deck/one/Card", "edit:Deck/1", "edit:Deck/1/", "play:Deck", "idle:now"] {
            #expect(PerfScenario(spec) == nil, "\(spec)")
        }
    }

    @Test func theReadyLineNamesBothPressPoints() {
        #expect(PerfScenario.readyDetail(center: CGPoint(x: 932.4, y: 574.6), handle: CGPoint(x: 1100, y: 700))
            == "center 932,575 handle 1100,700")
        #expect(PerfScenario.readyDetail(center: nil, handle: nil) == "center none handle none")
    }
}
