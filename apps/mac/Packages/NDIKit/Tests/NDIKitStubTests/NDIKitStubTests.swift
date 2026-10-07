import XCTest
@testable import NDIKit

final class NDIKitStubTests: XCTestCase {
    func testEveryEntryPointReportsUnavailable() {
        XCTAssertThrowsError(try NDILibrary.load()) { error in
            XCTAssertEqual(error as? NDIError, .loadFailed(ndiUnavailable))
        }
        XCTAssertTrue(NDILibrary.reinitialize())

        let library = NDILibrary()
        XCTAssertNil(NDIFinder(library: library))
        XCTAssertNil(NDISender(library: library, name: "MxU Stub"))
        let input = NDIInputSource(library: library, sourceNameContaining: "MxU Stub")
        XCTAssertEqual(input.state, .offline)
        XCTAssertNil(input.latestFrame())
    }
}
