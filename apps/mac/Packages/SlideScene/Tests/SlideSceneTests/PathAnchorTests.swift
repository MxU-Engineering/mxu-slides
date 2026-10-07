import CoreGraphics
import Testing
@testable import SlideScene

@Test func encodeParseRoundTripsAnchors() {
    let anchors = [
        PathAnchor(point: CGPoint(x: 100, y: 200), handleOut: CGPoint(x: 180, y: 120)),
        PathAnchor(point: CGPoint(x: 400, y: 200), handleIn: CGPoint(x: 320, y: 120)),
        PathAnchor(point: CGPoint(x: 250, y: 420)),
    ]
    guard let encoded = PathAnchorCodec.encode(anchors: anchors, closed: true) else {
        Issue.record("encode failed")
        return
    }
    guard let decoded = PathAnchorCodec.parse(encoded.pathData, in: encoded.frame) else {
        Issue.record("parse failed")
        return
    }
    #expect(decoded.closed)
    #expect(decoded.anchors.count == 3)
    for (a, b) in zip(anchors, decoded.anchors) {
        #expect(abs(a.point.x - b.point.x) < 0.5)
        #expect(abs(a.point.y - b.point.y) < 0.5)
        #expect((a.handleOut == nil) == (b.handleOut == nil))
        if let ha = a.handleOut, let hb = b.handleOut {
            #expect(abs(ha.x - hb.x) < 0.5)
            #expect(abs(ha.y - hb.y) < 0.5)
        }
    }
}

@Test func straightSegmentsEncodeAsLines() {
    let anchors = [
        PathAnchor(point: CGPoint(x: 0, y: 0)),
        PathAnchor(point: CGPoint(x: 100, y: 0)),
        PathAnchor(point: CGPoint(x: 100, y: 100)),
    ]
    let encoded = PathAnchorCodec.encode(anchors: anchors, closed: false)
    #expect(encoded?.pathData.contains(" L ") == true)
    #expect(encoded?.pathData.contains(" C ") == false)
    #expect(encoded?.pathData.hasSuffix("Z") == false)
}

@Test func quadraticsParseAsExactCubics() {

    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let parsed = PathAnchorCodec.parse("M 0 0 Q 0.5 1 1 0", in: frame)
    #expect(parsed != nil)
    #expect(parsed?.anchors.count == 2)
    #expect(parsed?.anchors[0].handleOut != nil)
    #expect(parsed?.anchors[1].handleIn != nil)
}

@Test func multipleSubpathsAreRefusedNotFlattened() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(PathAnchorCodec.parse("M 0 0 L 1 0 M 0 1 L 1 1", in: frame) == nil)
}

@Test func degenerateSpansKeepMinimumExtent() {

    let anchors = [
        PathAnchor(point: CGPoint(x: 50, y: 0)),
        PathAnchor(point: CGPoint(x: 50, y: 300)),
    ]
    let encoded = PathAnchorCodec.encode(anchors: anchors, closed: false)
    #expect((encoded?.frame.width ?? 0) >= 1)
}

@Test func encodeAbsoluteRoundTripsCanvasSpaceMasks() {

    let anchors = [
        PathAnchor(point: CGPoint(x: 0.25, y: 0.4)),
        PathAnchor(
            point: CGPoint(x: 0.75, y: 0.4),
            handleIn: CGPoint(x: 0.6, y: 0.3), handleOut: CGPoint(x: 0.9, y: 0.5)),
        PathAnchor(point: CGPoint(x: 0.5, y: 0.8)),
    ]
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let data = PathAnchorCodec.encodeAbsolute(anchors: anchors, closed: true)
    #expect(data != nil)
    let parsed = PathAnchorCodec.parse(data ?? "", in: unit)
    #expect(parsed?.closed == true)
    #expect(parsed?.anchors.count == 3)
    let first = parsed?.anchors.first?.point ?? .zero
    #expect(abs(first.x - 0.25) < 0.001 && abs(first.y - 0.4) < 0.001)
    let curved = parsed?.anchors[1]
    #expect(abs((curved?.handleIn?.x ?? 0) - 0.6) < 0.001)
    #expect(abs((curved?.handleOut?.y ?? 0) - 0.5) < 0.001)
}

@Test func encodeAbsoluteRefusesDegenerateInput() {
    #expect(PathAnchorCodec.encodeAbsolute(
        anchors: [PathAnchor(point: .zero)], closed: true) == nil)
}
