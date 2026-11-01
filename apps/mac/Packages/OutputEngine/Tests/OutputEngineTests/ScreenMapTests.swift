import RenderEngine
import XCTest
@testable import OutputEngine

final class ScreenMapTests: XCTestCase {
    let wall = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    let ribbon = CGRect(x: 0, y: 1080, width: 5760, height: 192)

    func testNoPlacementsFollowTheDot() {
        XCTAssertNil(ScreenMapResolver.resolve(placements: [], screen: wall))
    }

    func testAScreenOffTheMapFollowsTheDot() {
        XCTAssertNil(ScreenMapResolver.resolve(placements: [MapPlacement(rect: wall)], screen: nil))
    }

    func testAPlacementOnTheScreenFillsIt() {
        let hits = ScreenMapResolver.resolve(placements: [MapPlacement(rect: wall, fill: true)], screen: wall)
        XCTAssertEqual(hits, [ResolvedPlacement(frame: CGRect(x: 0, y: 0, width: 1, height: 1), fill: true)])
    }

    func testASpannedPlacementContinuesPastTheScreen() {

        let span = MapPlacement(rect: CGRect(x: 0, y: 0, width: 3840, height: 1080))
        let hits = ScreenMapResolver.resolve(placements: [span], screen: wall)
        XCTAssertEqual(hits, [ResolvedPlacement(frame: CGRect(x: -1, y: 0, width: 2, height: 1), fill: false)])
    }

    func testDuplicatePlacementsBothLand() {
        let corner = MapPlacement(rect: CGRect(x: 3200, y: 600, width: 640, height: 360))
        let hits = ScreenMapResolver.resolve(placements: [MapPlacement(rect: wall), corner], screen: wall)
        XCTAssertEqual(hits?.count, 2)
        XCTAssertEqual(hits?.last?.frame.minX ?? 0, (3200 - 1920) / 1920, accuracy: 0.0001)
    }

    func testAPlacementElsewhereShowsNothingHere() {
        let hits = ScreenMapResolver.resolve(placements: [MapPlacement(rect: ribbon)], screen: wall)
        XCTAssertEqual(hits, [])
    }

    func testStartingPoints() {
        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(ScreenMapResolver.onePerScreen([left, wall]).map(\.rect), [left, wall])
        XCTAssertEqual(ScreenMapResolver.acrossScreens([left, wall]).map(\.rect), [CGRect(x: 0, y: 0, width: 3840, height: 1080)])
        XCTAssertEqual(ScreenMapResolver.acrossScreens([]), [])
    }

    func testTheMapIsAsBigAsItsPieces() throws {
        var map = ScreenMap()
        let a = UUID(), b = UUID()
        map.place(a, at: wall)
        map.place(b, at: ribbon)
        XCTAssertEqual(map.bounds, CGRect(x: 0, y: 0, width: 5760, height: 1272))
        XCTAssertEqual(map.rect(for: a), wall)
        map.place(b, at: nil)
        XCTAssertNil(map.rect(for: b))
        let data = try JSONEncoder().encode(map)
        XCTAssertEqual(try JSONDecoder().decode(ScreenMap.self, from: data), map)
    }

    @MainActor
    func testSettingTheMapFiresTheSaveHookOnce() throws {
        let outputs = OutputManager(compositor: try Compositor())
        var saves = 0
        outputs.screenMapChanged = { saves += 1 }
        let map = ScreenMap(screens: [UUID().uuidString: wall])
        outputs.setScreenMap(map)
        outputs.setScreenMap(map)
        XCTAssertEqual(outputs.screenMap, map)
        XCTAssertEqual(saves, 1)
    }
}
