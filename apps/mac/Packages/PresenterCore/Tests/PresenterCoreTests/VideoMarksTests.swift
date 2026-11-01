import Foundation
import Testing
@testable import PresenterCore

private typealias V = VideoMarks

private let marks = [
    VideoMark(id: "c", name: "Band walk-on", at: 40, actions: []),
    VideoMark(id: "a", name: "Show QR", at: 5, actions: []),
    VideoMark(id: "b", name: "Hide QR", at: 20, actions: []),
    VideoMark(id: "d", name: "Show QR", at: 50, actions: []),
]
private let points = V.points(marks, inPoint: nil, length: 60)

private func ids(_ points: [V.Point]) -> [String] { points.map(\.id) }

@Test func v160MediaItemDecodesWithNoMarks() throws {
    let json = """
    {"id":"m","name":"Clip","mediaKind":"video","classification":"foreground","fileHash":"h","fileName":"c.mov",\
    "fileStatus":"ready","statusDetail":"","tags":[],"favorite":false,"collections":[],"loops":false}
    """
    #expect(try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8)).marks == nil)
}

@Test func pointsAreWindowSecondsInTimeOrderAndDropMarksOutsideTheTrim() {
    #expect(ids(points) == ["a", "b", "c", "d"])

    let red = V.points([VideoMark(id: "r", name: "Red", at: 3, actions: [], colorHex: "#FF3B30")], inPoint: nil, length: 60)
    #expect(red.first?.colorHex == "#FF3B30")
    let trimmed = V.points(marks, inPoint: 10, length: 35)
    #expect(ids(trimmed) == ["b", "c"])
    #expect(trimmed.map(\.at) == [10, 30])
}

@Test func playingAcrossAMarkFiresIt() {
    #expect(ids(V.crossed(points, from: 4.9, to: 5.1, elapsed: 0.2, rate: 1, length: 60, looping: false)) == ["a"])

    #expect(ids(V.crossed(points, from: 4.8, to: 5, elapsed: 0.2, rate: 1, length: 60, looping: false)) == ["a"])
    #expect(V.crossed(points, from: 5, to: 5.2, elapsed: 0.2, rate: 1, length: 60, looping: false).isEmpty)
}

@Test func aJumpFiresNothing() {

    #expect(V.crossed(points, from: 10, to: 45, elapsed: 0.25, rate: 1, length: 60, looping: false).isEmpty)

    #expect(V.crossed(points, from: 45, to: 30, elapsed: 0.25, rate: 1, length: 60, looping: false).isEmpty)
}

@Test func playRateWidensWhatTimeCanExplain() {
    #expect(ids(V.crossed(points, from: 19.5, to: 20.4, elapsed: 0.45, rate: 2, length: 60, looping: false)) == ["b"])
    #expect(V.crossed(points, from: 19.5, to: 20.4, elapsed: 0.45, rate: 1, length: 60, looping: false).isEmpty)
}

@Test func aFreshStartFiresFromTheTopButAMidVideoStartSkips() {
    let top = V.points([VideoMark(id: "z", name: "Top", at: 0, actions: [])] + marks, inPoint: nil, length: 60)
    #expect(ids(V.crossed(top, from: nil, to: 0.3, elapsed: 0, rate: 1, length: 60, looping: false)) == ["z"])
    #expect(V.crossed(top, from: nil, to: 30, elapsed: 0, rate: 1, length: 60, looping: false).isEmpty)

    #expect(ids(V.crossed(top, from: 60, to: 0.2, elapsed: 0.25, rate: 1, length: 60, looping: false)) == ["z"])
}

@Test func aLoopFiresItsMarksEveryPass() {
    let wrap = V.crossed(points, from: 59.9, to: 5.05, elapsed: 5.2, rate: 1, length: 60, looping: true)
    #expect(ids(wrap) == ["a"])

    #expect(V.crossed(points, from: 59.9, to: 5.05, elapsed: 5.2, rate: 1, length: 60, looping: false).isEmpty)
}

@Test func targetsPickTheNextOrTheNamedMarkElseTheEnd() {
    #expect(V.target(points, after: 6, target: .nextMark, name: nil)?.id == "b")
    #expect(V.target(points, after: 6, target: .namedMark, name: "show qr")?.id == "d")
    #expect(V.target(points, after: 50, target: .nextMark, name: nil) == nil)
    #expect(V.target(points, after: 0, target: .end, name: nil) == nil)
}

@Test func countUpStartsFromThePreviousMarkOfTheSameRule() {
    #expect(V.countUpStart(points, before: 30, target: .nextMark, name: nil) == 20)
    #expect(V.countUpStart(points, before: 30, target: .namedMark, name: "Show QR") == 5)
    #expect(V.countUpStart(points, before: 30, target: .end, name: nil) == 0)
    #expect(V.countUpStart(points, before: 2, target: .nextMark, name: nil) == 0)
}

@Test func untilNextWrapsOnlyWhenLooping() {
    #expect(V.untilNext(points, after: 10, length: 60, looping: false) == 10)
    #expect(V.untilNext(points, after: 55, length: 60, looping: false) == nil)
    #expect(V.untilNext(points, after: 55, length: 60, looping: true) == 10)
}

@Test func editsKeepTimeOrderAndStayInsideTheFile() {
    #expect(V.defaultName(nil) == "Mark 1")
    #expect(V.defaultName([VideoMark(id: "x", name: "Mark 2", at: 1, actions: [])]) == "Mark 3")
    let added = V.adding(marks, id: "e", name: "Mark 5", at: 12.34567, actions: [], fileLength: 60)
    #expect(added.map(\.id) == ["a", "e", "b", "c", "d"])
    #expect(added[1].at == 12.346)
    #expect(V.adding(nil, id: "f", name: "End", at: 99, actions: [], fileLength: 60).first?.at == 60)
    let moved = V.moving(marks, id: "a", to: 45, fileLength: 60)
    #expect(moved.map(\.id) == ["b", "c", "a", "d"])
    #expect(V.moving(marks, id: "a", to: -3, fileLength: 60).first { $0.id == "a" }?.at == 0)
}

@Test func marksAtTheSameMomentAllFireInTheListsOrder() {
    let same = V.adding(
        V.adding(nil, id: "y", name: "Lights", at: 30, actions: [], fileLength: 60),
        id: "x", name: "Alert", at: 30, actions: [], fileLength: 60)
    let points = V.points(same, inPoint: nil, length: 60)

    #expect(ids(V.crossed(points, from: 29.9, to: 30.1, elapsed: 0.2, rate: 1, length: 60, looping: false)) == same.map(\.id))
    #expect(same.map(\.id) == ["x", "y"])
}

@Test func actionMarksAreNamedAfterTheirTarget() {
    #expect(V.defaultName(forActionLabel: "Fire Alert: Band on Stage") == "Band on Stage")
    #expect(V.defaultName(forActionLabel: "Clear All") == "Clear All")
    #expect(V.defaultName(forActionLabel: "Fire Overlay: ") == "Fire Overlay: ")
}
