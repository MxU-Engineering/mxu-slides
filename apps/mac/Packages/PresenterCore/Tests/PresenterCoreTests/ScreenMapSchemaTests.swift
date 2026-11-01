import XCTest
@testable import PresenterCore

final class ScreenMapSchemaTests: XCTestCase {
    func testAPreV160PresetDecodesToDotsOnly() throws {
        let json = #"{"id":"sunday","name":"Sunday","assignments":[{"targetKind":"placeholderScreen","targetId":"wall","enabledLayers":["slide"]}]}"#
        let preset = try JSONDecoder().decode(OutputPreset.self, from: Data(json.utf8))
        XCTAssertNil(preset.placements)
        XCTAssertNil(preset.layers)
        XCTAssertEqual(preset.assignments.first?.enabledLayers, ["slide"])
    }

    func testPlacementsAndLayersRoundTrip() throws {
        var preset = OutputPreset(id: "sunday", name: "Sunday", assignments: [])
        preset.layers = [CustomLayer(id: "live-stream", name: "Live Stream", above: "slide")]
        preset.placements = [
            LayerPlacement(layerId: "slide", x: 1920, y: 0, width: 1920, height: 1080, scale: nil),
            LayerPlacement(layerId: "slide", x: 4560, y: 620, width: 1200, height: 460, scale: .fill),
        ]
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(OutputPreset.self, from: data)
        XCTAssertEqual(back, preset)
        XCTAssertEqual(back.placements?.filter { $0.layerId == "slide" }.count, 2)
    }

    func testAMediaItemMayNameACustomLayer() throws {
        let old = try JSONDecoder().decode(CueMedia.self, from: Data(#"{"mediaId":"m1"}"#.utf8))
        XCTAssertNil(old.layerId)
        var cue = CueMedia(mediaId: "m1")
        cue.layerId = "live-stream"
        let back = try JSONDecoder().decode(CueMedia.self, from: try JSONEncoder().encode(cue))
        XCTAssertEqual(back.layerId, "live-stream")
    }
}
