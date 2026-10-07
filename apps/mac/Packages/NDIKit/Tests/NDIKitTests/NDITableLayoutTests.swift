import CNDI
import XCTest
@testable import NDIKit

final class NDITableLayoutTests: XCTestCase {
    private func loadedLibrary() throws -> NDILibrary {
        do {
            return try NDILibrary.load()
        } catch {
            throw XCTSkip("NDI runtime not installed: \(error)")
        }
    }

    func testEveryCalledSlotIsTheRuntimeExportOfThatName() throws {
        let library = try loadedLibrary()
        XCTAssertEqual(
            NDILibrary.tableMismatches(library.table, resolve: library.export), [])
    }

    func testTheSlottingThatCrashedLaunchIsRefusedBeforeAnyCall() throws {
        let library = try loadedLibrary()

        var table = library.table
        table.find_create_v2 = unsafeBitCast(
            library.table.version, to: type(of: table.find_create_v2))
        table.find_wait_for_sources = unsafeBitCast(
            library.table.find_create_v2, to: type(of: table.find_wait_for_sources))

        let expected = ["NDIlib_find_create_v2", "NDIlib_find_wait_for_sources"]
        XCTAssertEqual(NDILibrary.tableMismatches(table, resolve: library.export), expected)
        guard case .failure(let error) = NDILibrary.activate(table: table, handle: library.handle)
        else { return XCTFail("a mis-slotted table must never activate") }
        XCTAssertEqual(error, .tableMismatch(expected))
    }

    func testAnEmptyTableNeverPassesForTheRuntime() {
        let elsewhere = UnsafeRawPointer(bitPattern: 0x1000)
        let mismatches = NDILibrary.tableMismatches(NDIlib_v5()) { _ in elsewhere }
        XCTAssertEqual(mismatches.count, 13)
        XCTAssertEqual(mismatches.first, "NDIlib_initialize")
        XCTAssertTrue(mismatches.contains("NDIlib_find_create_v2"))
    }
}
