import Foundation
import Testing
@testable import PresenterCore

@Suite struct SlideLayerFactsTests {
    @Test func chipsComeFromStoredFieldsOnly() {
        var cue = CueMedia(mediaId: "m1", layer: .stillGraphics, classification: .foreground)
        cue.layerId = "x"
        let slide = Slide(
            id: "s1", name: "Preservice", objects: [], background: cue,
            actions: [SlideAction(id: "a1", kind: .switchOutputPreset, presetId: "sermon")])
        let chips = SlideLayerFacts.chips(
            for: slide,
            item: { _ in ("Online Preservice Graphic", .image) },
            layerName: { $0 == "x" ? "Live Stream" : nil })
        #expect(chips.count == 1, "the preset switch wears no chip; its action glyph does the telling")
        #expect(chips[0].label == "Live Stream")
        #expect(chips[0].itemName == "Online Preservice Graphic")

        let plain = Slide(id: "s2", name: "", objects: [], background: CueMedia(mediaId: "m1", layer: .stillGraphics, classification: .foreground))
        #expect(SlideLayerFacts.chips(for: plain, item: { _ in ("Pic", .image) }, layerName: { _ in "?" }).isEmpty)
        var gone = plain
        gone.background?.layerId = "deleted"
        #expect(SlideLayerFacts.chips(for: gone, item: { _ in ("Pic", .image) }, layerName: { _ in nil }).isEmpty)
    }

    @Test func addAndRemoveLayerRoundTripThroughThePreset() throws {
        var preset = OutputPreset(
            id: "sunday", name: "Sunday",
            assignments: [OutputAssignment(targetKind: .placeholderScreen, targetId: "wall", enabledLayers: ["slide"])])
        let layer = preset.addLayer(named: "Live Stream", id: "live")
        #expect(layer.above == "slide")
        #expect(preset.layers == [layer])
        #expect(preset.assignments[0].enabledLayers == ["live", "slide"])
        let back = try JSONDecoder().decode(OutputPreset.self, from: JSONEncoder().encode(preset))
        #expect(back == preset)

        preset.placements = [LayerPlacement(layerId: "live", x: 0, y: 0, width: 10, height: 10)]
        preset.removeLayer(id: "live")
        #expect(preset.layers == nil)
        #expect(preset.placements == nil)
        #expect(preset.assignments[0].enabledLayers == ["slide"])
    }

    @Test func theLayerChoiceWritesOneFieldAndClearsTheOther() {
        var cue = CueMedia(mediaId: "m1")
        cue.setRoutingLayer("live")
        #expect(cue.layerId == "live")
        #expect(cue.layer == nil)
        cue.setRoutingLayer(CueMediaLayer.videos.rawValue)
        #expect(cue.layer == .videos)
        #expect(cue.layerId == nil)
        #expect(cue.storedRoutingLayerId == "videos")
        cue.setRoutingLayer(nil)
        #expect(cue.layer == nil)
        #expect(cue.layerId == nil)
        #expect(cue.storedRoutingLayerId == nil)
        #expect(cue.defaultLayer(kind: .video) == .loopingVideos, "no classification reads background")
    }
}
