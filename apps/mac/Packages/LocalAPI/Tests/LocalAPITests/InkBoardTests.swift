import CoreVideo
import Foundation
import Testing
@testable import LocalAPI

@Suite struct InkBoardTests {
    private func stroke(_ id: String, points: [Double] = [0.1, 0.1], erase: Bool = false) -> InkStroke {
        InkStroke(id: id, colorHex: "#ff3b30", width: 0.01, points: points, isOpen: true)
    }

    @Test func strokeLifecycle() {
        var board = InkBoard()
        let r1 = board.begin(stroke("c1.1"))
        #expect(r1)
        let r2 = board.append(id: "c1.1", points: [0.2, 0.2, 0.3, 0.3])
        #expect(r2 == [0.2, 0.2, 0.3, 0.3])
        let r3 = board.end(id: "c1.1")
        #expect(r3)
        #expect(board.strokes.count == 1)
        #expect(board.strokes[0].points.count == 6)
        #expect(!board.strokes[0].isOpen)
        #expect(board.isVisible)
    }

    @Test func duplicateIDsAndEmptyStrokesAreRejected() {
        var board = InkBoard()
        let r4 = board.begin(stroke("c1.1"))
        #expect(r4)
        let r5 = board.begin(stroke("c1.1"))
        #expect(!r5)
        let r6 = board.begin(stroke("c1.2", points: []))
        #expect(!r6)
    }

    @Test func pointsAreClampedAndNonFiniteDropped() {
        var board = InkBoard()
        board.begin(stroke("c1.1", points: [-1, 2]))
        board.append(id: "c1.1", points: [.nan, 0.5, 0.4, 0.6])
        #expect(board.strokes[0].points == [0, 1, 0.4, 0.6])
    }

    @Test func appendAfterEndIsIgnored() {
        var board = InkBoard()
        board.begin(stroke("c1.1"))
        board.end(id: "c1.1")
        let r7 = board.append(id: "c1.1", points: [0.5, 0.5])
        #expect(r7 == nil)
    }

    @Test func undoRemovesLastClosedStrokeOnly() {
        var board = InkBoard()
        board.begin(stroke("c1.1")); board.end(id: "c1.1")
        board.begin(stroke("c1.2"))
        let r8 = board.undo()
        #expect(r8 == "c1.1")
        #expect(board.strokes.map(\.id) == ["c1.2"])
        let r9 = board.undo()
        #expect(r9 == nil)
    }

    @Test func clearAndHideBumpRevisionOnlyOnChange() {
        var board = InkBoard()
        let start = board.revision
        board.clear()
        #expect(board.revision == start)
        board.begin(stroke("c1.1"))
        board.clear()
        #expect(board.strokes.isEmpty)
        let r10 = board.setHidden(true)
        #expect(r10)
        let r11 = board.setHidden(true)
        #expect(!r11)
        #expect(!board.isVisible)
    }

    @Test func strokeCapDropsOldestClosedStroke() {
        var board = InkBoard()
        for index in 0 ..< InkBoard.maxStrokes + 5 {
            board.begin(stroke("c1.\(index)"))
            board.end(id: "c1.\(index)")
        }
        #expect(board.strokes.count == InkBoard.maxStrokes)
        #expect(board.strokes.first?.id == "c1.5")
    }

    @Test func disconnectingViewerClosesItsOpenStrokes() {
        var board = InkBoard()
        board.begin(stroke("c1.1"))
        board.begin(stroke("c2.1"))
        let r12 = board.closeStrokes(withPrefix: "c1.")
        #expect(r12 == ["c1.1"])
        #expect(board.strokes.first { $0.id == "c2.1" }?.isOpen == true)
    }
}

@Suite struct InkProtocolTests {
    @Test func strokeValidation() {
        let good: [String: Any] = [
            "t": "ss", "id": "c3.1", "c": "#00E5FF", "w": 0.01, "a": 1, "cap": "round",
            "g": 0.02, "e": 0, "p": [0.1, 0.2],
        ]
        let parsed = InkRelayServer.stroke(from: good, viewer: "c3")
        #expect(parsed?.colorHex == "#00e5ff")
        #expect(parsed?.roundCap == true)
        #expect(parsed?.points == [0.1, 0.2])

        var spoofed = good
        spoofed["id"] = "c9.1"
        #expect(InkRelayServer.stroke(from: spoofed, viewer: "c3") == nil)
        var badColor = good
        badColor["c"] = "red"
        #expect(InkRelayServer.stroke(from: badColor, viewer: "c3") == nil)
        var tooWide = good
        tooWide["w"] = 0.9
        #expect(InkRelayServer.stroke(from: tooWide, viewer: "c3") == nil)
    }

    @Test func pinComparison() {
        #expect(InkRelayServer.constantTimeEqual("1234", "1234"))
        #expect(!InkRelayServer.constantTimeEqual("1234", "12345"))
        #expect(!InkRelayServer.constantTimeEqual("", "1234"))
    }

    @Test func pageResourceIsBundled() {
        #expect(InkRelayServer.pageData() != nil)
    }
}

@Suite struct InkRasterizerTests {
    @Test func opaqueWhereDrawnTransparentElsewhere() throws {
        var board = InkBoard()
        board.begin(InkStroke(
            id: "c1.1", colorHex: "#ff0000", width: 0.05, points: [0.1, 0.5, 0.9, 0.5]))
        board.end(id: "c1.1")
        let buffer = try #require(InkRasterizer.render(board, width: 200, height: 100))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func pixel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let p = base + y * rowBytes + x * 4
            return (p[0], p[1], p[2], p[3])
        }
        let on = pixel(100, 50)
        #expect(on.a == 255 && on.r == 255 && on.g == 0)
        #expect(pixel(100, 5).a == 0)
    }

    @Test func eraserRemovesInk() throws {
        var board = InkBoard()
        board.begin(InkStroke(id: "c1.1", colorHex: "#ff0000", width: 0.2, points: [0.1, 0.5, 0.9, 0.5]))
        board.end(id: "c1.1")
        board.begin(InkStroke(id: "c1.2", colorHex: "#999999", width: 0.2, erase: true, points: [0.1, 0.5, 0.9, 0.5]))
        board.end(id: "c1.2")
        let buffer = try #require(InkRasterizer.render(board, width: 200, height: 100))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let offset: Int = 50 * CVPixelBufferGetBytesPerRow(buffer) + 403
        #expect(base[offset] == 0)
    }
}
