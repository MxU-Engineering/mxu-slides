import Foundation
import RenderEngine
import XCTest
@testable import OutputEngine

@MainActor
final class OutputLayoutTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private func classify(_ outputs: OutputManager, _ screenID: UUID) -> OutputLayoutKind {
        OutputLayout.classify(
            slices: outputs.slices(forScreen: screenID),
            hasBlends: { sliceID in
                let adjustments = outputs.adjustments(forScreen: sliceID)
                return adjustments.blendLeft != nil || adjustments.blendRight != nil
                    || adjustments.blendTop != nil || adjustments.blendBottom != nil
            }
        )
    }

    func testPlacementIsOrthogonalToTheShape() throws {

        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 832, height: 416))
        outputs.seedPlacement(forSlice: screen.id, frameWidth: 1920, frameHeight: 1080)
        let placement = try XCTUnwrap(outputs.placement(forSlice: screen.id))
        XCTAssertEqual(placement.width, 832, "seeded 1:1 at wall-native pixels, top-left")
        XCTAssertEqual(placement.y, 0)
        XCTAssertEqual(classify(outputs, screen.id), .single)

        outputs.applyLayout(.single, outputCount: 1, overlap: 0, forScreen: screen.id)
        XCTAssertEqual(outputs.placement(forSlice: screen.id)?.width, 832)
    }

    func testShareItSeedsTheJoinerBelowTheIncumbent() throws {
        let outputs = try makeManager()
        let wall = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 1536, height: 864))
        let ribbon = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Ribbon", width: 1920, height: 192))
        outputs.seedPlacement(forSlice: wall.id, frameWidth: 1920, frameHeight: 1080)
        outputs.seedPlacement(
            forSlice: ribbon.id, frameWidth: 1920, frameHeight: 1080,
            siblings: [try XCTUnwrap(outputs.placement(forSlice: wall.id))])
        XCTAssertEqual(outputs.placement(forSlice: ribbon.id)?.y, 864, "lands under the wall")

        let tall = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Tall", width: 400, height: 400))
        outputs.seedPlacement(
            forSlice: tall.id, frameWidth: 1920, frameHeight: 1080,
            siblings: [try XCTUnwrap(outputs.placement(forSlice: ribbon.id))])
        XCTAssertEqual(outputs.placement(forSlice: tall.id)?.y, 0)
    }

    func testEveryLayoutRoundTripsThroughClassify() throws {
        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 384, height: 108))

        XCTAssertEqual(classify(outputs, screen.id), .single)

        outputs.applyLayout(.mirror, outputCount: 3, overlap: 0, forScreen: screen.id)
        XCTAssertEqual(outputs.slices(forScreen: screen.id).count, 3)
        XCTAssertEqual(classify(outputs, screen.id), .mirror)

        outputs.applyLayout(.grouped, outputCount: 2, overlap: 0, forScreen: screen.id)
        XCTAssertEqual(classify(outputs, screen.id), .grouped)
        let grouped = outputs.slices(forScreen: screen.id).dropFirst()
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first?.sourceRect.width ?? 0, 0.5, accuracy: 0.001)

        outputs.applyLayout(.edgeBlend, outputCount: 3, overlap: 0.06, forScreen: screen.id)
        XCTAssertEqual(classify(outputs, screen.id), .edgeBlend)
        let tiles = Array(outputs.slices(forScreen: screen.id).dropFirst())
        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles[0].name, "Left")
        XCTAssertEqual(tiles[1].name, "Center")

        let middle = outputs.adjustments(forScreen: tiles[1].id)
        XCTAssertNotNil(middle.blendLeft)
        XCTAssertNotNil(middle.blendRight)
        let left = outputs.adjustments(forScreen: tiles[0].id)
        XCTAssertNil(left.blendLeft, "the wall's outer edge never ramps")
        XCTAssertNotNil(left.blendRight)

        outputs.applyLayout(.single, outputCount: 1, overlap: 0, forScreen: screen.id)
        XCTAssertEqual(outputs.slices(forScreen: screen.id).count, 1)
        XCTAssertEqual(classify(outputs, screen.id), .single)
    }

    func testHandEditedRegionsReadBackAsCustom() throws {
        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 384, height: 108))
        outputs.applyLayout(.grouped, outputCount: 2, overlap: 0, forScreen: screen.id)
        let tile = try XCTUnwrap(outputs.slices(forScreen: screen.id).dropFirst().first)
        outputs.setSliceSourceRect(
            CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5), forSlice: tile.id)
        XCTAssertEqual(classify(outputs, screen.id), .custom,
                       "a shape the picker can't express stays fully editable as Custom")
    }

    func testGroupedReleasesTheDefaultSlicesBacking() throws {
        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 384, height: 108))
        outputs.assignPlaceholderDevice(placeholderID: screen.id, displayUUID: "DISPLAY-A")
        var released: [UUID] = []
        outputs.applyLayout(
            .edgeBlend, outputCount: 2, overlap: 0.05, forScreen: screen.id,
            releasingCarries: { released.append($0) })
        XCTAssertNil(outputs.placeholderDevices[screen.id],
                     "the default slice becomes whole-canvas plumbing — tiles own the glass")
        XCTAssertTrue(released.contains(screen.id), "carries get the release callback too")
    }

    func testTileMathAndNames() {
        let tiles = OutputLayout.tiles(columns: 3, overlap: 0.06)
        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles[0].minX, 0, accuracy: 0.0001)
        XCTAssertEqual(tiles[2].maxX, 1, accuracy: 0.0001)

        XCTAssertEqual(tiles[0].maxX - tiles[1].minX, 0.06, accuracy: 0.0001)
        XCTAssertEqual(OutputLayout.tileName(0, of: 2), "Left")
        XCTAssertEqual(OutputLayout.tileName(2, of: 3), "Right")
        XCTAssertEqual(OutputLayout.tileName(3, of: 4), "Slice 4")
    }
}
