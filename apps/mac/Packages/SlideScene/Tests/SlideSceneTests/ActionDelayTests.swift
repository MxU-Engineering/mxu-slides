import Foundation
import PresenterCore
import Testing
@testable import SlideScene

@Suite struct ActionDelayTests {
    private func step(
        _ kind: SlideActionKind, id: String = UUID().uuidString,
        layer: String? = nil, delay: Double? = nil
    ) -> SlideAction {
        var action = SlideAction(id: id, kind: kind, layer: layer)
        action.delaySeconds = delay
        return action
    }

    @Test func scheduleSplitsAndOrdersBatches() {
        let actions = [
            step(.clearAll, id: "a"),
            step(.timerConfigure, id: "b", delay: 5),
            step(.fireOverlay, id: "c"),
            step(.timerStart, id: "d", delay: 5),
            step(.captureStop, id: "e", delay: 2),
        ]
        let schedule = SlideSceneBuilder.delaySchedule(actions)
        #expect(schedule.immediate.map(\.id) == ["a", "c"])
        #expect(schedule.delayed.map(\.delay) == [2, 5])

        #expect(schedule.delayed.map { $0.actions.map(\.id) } == [["e"], ["b", "d"]])
    }

    @Test func zeroAndAbsentDelaysAreImmediate() {
        let actions = [step(.clearAll, id: "a", delay: 0), step(.clearAudio, id: "b")]
        let schedule = SlideSceneBuilder.delaySchedule(actions)
        #expect(schedule.immediate.map(\.id) == ["a", "b"])
        #expect(schedule.delayed.isEmpty)
        #expect(!SlideSceneBuilder.waitsBeforeFiring(actions[0]))
    }

    @Test func delayedOwnLayerClearSurvivesTheFireFilter() {

        var deck = Slide(id: "s", name: "s", objects: [])
        deck.actions = [
            step(.clearLayer, id: "now", layer: "slide"),
            step(.clearLayer, id: "later", layer: "slide", delay: 30),
        ]
        #expect(SlideSceneBuilder.fireActions(for: deck).map(\.id) == ["later"])
    }

    @Test func delayedOwnLayerClearSurvivesTheMediaFireFilter() {
        var item = MediaItem(
            id: "m", name: "m", mediaKind: .video, classification: .foreground,
            fileHash: "", fileName: "m.mov", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false
        )
        item.actions = [
            step(.clearLayer, id: "now", layer: "videos"),
            step(.clearLayer, id: "later", layer: "videos", delay: 10),
        ]
        #expect(
            SlideSceneBuilder.fireActions(forMedia: item, on: .videos).map(\.id)
                == ["later"])
    }
}
