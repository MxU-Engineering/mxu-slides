import XCTest
@testable import NDIKit

final class NDIReinitializeTests: XCTestCase {
    private func loadedLibrary() throws -> NDILibrary {
        do {
            return try NDILibrary.load()
        } catch {
            throw XCTSkip("NDI runtime not installed: \(error)")
        }
    }

    func testSwapDeclinesWhileAnInstanceLivesThenLandsAfterRelease() throws {
        let library = try loadedLibrary()
        var finder: NDIFinder? = NDIFinder(library: library)
        XCTAssertNotNil(finder)
        XCTAssertFalse(
            NDILibrary.reinitialize(timeout: 0.3),
            "a live finder must hold the swap off")
        finder = nil
        XCTAssertTrue(NDILibrary.reinitialize(timeout: 5))
    }

    func testRuntimeStillWorksAfterASwap() throws {
        let library = try loadedLibrary()
        XCTAssertTrue(NDILibrary.reinitialize(timeout: 5))

        let finder = try XCTUnwrap(NDIFinder(library: library))
        _ = finder.currentSourceNames(wait: 200)
        XCTAssertNotNil(NDISender(library: library, name: "MxU Swap Probe"))
    }

    func testGateBlocksNewInstancesOnlyDuringTheSwap() {
        let gate = InstanceGate()
        gate.enter()
        XCTAssertNil(
            gate.withExclusive(timeout: 0.2, { true }),
            "exclusive must time out while a reader is active")
        gate.leave()
        XCTAssertEqual(gate.withExclusive(timeout: 1, { 7 }), 7)
    }
}
