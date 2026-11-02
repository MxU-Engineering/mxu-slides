import XCTest
@testable import RenderEngine

final class DropoutWatchTests: XCTestCase {
    func testARunIsReportedOnceWhenItEnds() {
        var watch = DropoutWatch()
        XCTAssertNil(watch.update(false, at: 1))
        XCTAssertNil(watch.update(true, at: 2))
        XCTAssertNil(watch.update(true, at: 2.25))
        let run = watch.update(false, at: 2.5)
        XCTAssertEqual(run?.start, 2)
        XCTAssertEqual(run?.seconds, 0.5)
        XCTAssertNil(watch.update(false, at: 3))
    }
}
