import Automerge
import Foundation
import Testing
@testable import PresenterCore

private typealias T = PresentationTimelines

private let hour = 3600 * T.framesPerSecond

private func timeline(_ id: String, start: Int = 0, length: Double = 300) -> PresentationTimeline {
    PresentationTimeline(id: id, timecodeEnabled: true, timecodeStart: start, length: length, cues: [])
}

private let service: [(id: String, timeline: PresentationTimeline?)] = [
    ("a", timeline("ta")), ("header", nil), ("b", timeline("tb")), ("bare", nil), ("c", timeline("tc")),
]

private func songs(byOrder: Bool, _ items: [(id: String, timeline: PresentationTimeline?)] = service) -> [TimecodeFollow.Song] {
    let starts = T.serviceStarts(items, byOrder: byOrder)
    return items.compactMap { item in
        item.timeline.map { TimecodeFollow.Song(itemID: item.id, timeline: $0, start: starts[item.id]) }
    }
}

@Test func v143ServiceDecodesSavedWithEachSong() throws {
    let json = #"{"id":"s","name":"Sunday","serviceDate":"2026-10-18","items":[]}"#
    #expect(try JSONDecoder().decode(Service.self, from: Data(json.utf8)).timecodeByOrder == nil)
}

@Test func startTimesRoundTripThroughTheDocument() throws {
    var service = Service(id: "s", name: "Sunday", serviceDate: "2026-10-18", items: [])
    service.timecodeByOrder = true
    let document = Document()
    try AutomergeEncoder(doc: document).encode(service)
    #expect(try AutomergeDecoder(doc: document).decode(Service.self).timecodeByOrder == true)
}

@Test func aPlanRefreshKeepsTheServicesStartTimes() {
    func plan(_ version: String) -> PlanSyncLogic.PlanSnapshot {
        PlanSyncLogic.PlanSnapshot(
            hexId: "p", name: "Sunday", title: "Sunday", serviceTypeName: "Weekend",
            startsAt: "2026-10-18T09:00:00Z", version: version,
            times: [PlanSyncLogic.TimeSnapshot(hexId: "t1", name: "9:00 am", items: [
                PlanSyncLogic.ItemSnapshot(hexId: "i1", name: "Way Maker", kind: "song", duration: 300, pcoItemId: "p1"),
            ])])
    }
    var service = PlanSyncLogic.materialize(plan: plan("v1"))
    #expect(service.timecodeByOrder == nil)
    service.timecodeByOrder = true
    #expect(PlanSyncLogic.materialize(plan: plan("v2"), into: service).timecodeByOrder == true)
}

@Test func savedWithEachSongUsesEachTimelinesOwnStart() {
    let items: [(id: String, timeline: PresentationTimeline?)] = [
        ("a", timeline("ta", start: 5 * hour)), ("bare", nil), ("b", timeline("tb", start: 9 * hour)),
    ]
    #expect(T.serviceStarts(items, byOrder: false) == ["a": 5 * hour, "b": 9 * hour])
}

@Test func inServiceOrderGivesEachTimelineSongAnHourAndSkipsTheRest() {
    #expect(T.serviceStarts(service, byOrder: true) == ["a": hour, "b": 2 * hour, "c": 3 * hour])
}

@Test func inServiceOrderFollowsReordersAndAddedOrRemovedSongs() {

    let moved = [service[4]] + service[0..<4]
    #expect(T.serviceStarts(moved, byOrder: true) == ["c": hour, "a": 2 * hour, "b": 3 * hour])

    let removed = service.filter { $0.id != "b" }
    #expect(T.serviceStarts(removed, byOrder: true) == ["a": hour, "c": 2 * hour])

    let added = service.map { $0.id == "bare" ? ("bare", timeline("tbare")) : $0 }
    #expect(T.serviceStarts(added, byOrder: true) == ["a": hour, "b": 2 * hour, "bare": 3 * hour, "c": 4 * hour])
}

@Test func theSameSongTwiceInAServiceIsTwoSongs() {
    let twice: [(id: String, timeline: PresentationTimeline?)] = [("a1", timeline("ta")), ("a2", timeline("ta"))]
    #expect(T.serviceStarts(twice, byOrder: true) == ["a1": hour, "a2": 2 * hour])
}

@Test func savedStartsAllAtZeroCantTellTheSongsApart() {
    let songs = songs(byOrder: false)

    #expect(TimecodeFollow.song(containing: 10, rate: .fps30, in: songs)?.song.itemID == "a")
    #expect(TimecodeFollow.song(containing: 7200 + 10, rate: .fps30, in: songs) == nil)
    #expect(TimecodeFollow.clashes(songs) == ["a", "b", "c"])
}

@Test func inServiceOrderTheHourSaysWhichSong() {
    let songs = songs(byOrder: true)
    #expect(TimecodeFollow.song(containing: 3600 + 10, rate: .fps30, in: songs)?.song.itemID == "a")
    let b = TimecodeFollow.song(containing: 7200 + 42, rate: .fps30, in: songs)
    #expect(b?.song.itemID == "b")
    #expect(abs((b?.position ?? 0) - 42) < 1e-9)
    #expect(TimecodeFollow.song(containing: 3 * 3600 + 1, rate: .fps30, in: songs)?.song.itemID == "c")
    #expect(TimecodeFollow.song(containing: 10, rate: .fps30, in: songs) == nil)
    #expect(TimecodeFollow.clashes(songs).isEmpty)

    var follow = TimecodeFollow()
    let reading = TimecodeClock.Reading(state: .locked, position: 7200 + 0.1, rate: .fps30)
    #expect(follow.step(reading, songs: songs)?.itemID == "b")
}

@Test func inServiceOrderOnlyASongOverAnHourOverlaps() {
    let long: [(id: String, timeline: PresentationTimeline?)] = [("a", timeline("ta", length: 3700)), ("b", timeline("tb"))]
    #expect(TimecodeFollow.clashes(songs(byOrder: true, long)) == ["a", "b"])
    let windows = T.serviceStarts(long, byOrder: true).map { T.Window(id: $0.key, start: $0.value, length: 300 * 30) }
    #expect(T.overlaps(T.Window(id: "a", start: hour, length: T.frames(seconds: 3700)), in: windows).map(\.id) == ["b"])
}

@Test func cueRowsAndRecordingUseTheStartInThisService() {
    let blocks = [TimelinePlayedBlock(sectionId: "v", slideIds: ["v1"])]
    var song = timeline("t")
    song.cues = [T.slideCue(id: "s", at: 1, anchor: T.anchor(occurrence: 0, in: blocks)!)]
    #expect(TimecodeFollow.cueRows(song, start: 2 * hour, blocks: blocks) { _ in "Verse" }.map(\.timecode)
        == ["02:00:01:00"])
    #expect(TimecodeFollow.cueRows(song, blocks: blocks) { _ in "Verse" }.map(\.timecode) == ["00:00:01:00"])
    #expect(TimecodeRecording.mode(timeline: song, start: 2 * hour, hasInput: true, follows: true)
        == .timecode(start: 2 * hour))
    #expect(TimecodeRecording.mode(timeline: song, hasInput: true, follows: true) == .timecode(start: 0))
}

@Test func aNewServiceTakesTheLatestEarlierSameTypeServicesStartTimes() {
    func service(_ id: String, _ date: String, type: String? = "Weekend", byOrder: Bool? = nil) -> Service {
        var service = Service(id: id, name: id, serviceDate: date, items: [])
        service.mxuServiceTypeName = type
        service.timecodeByOrder = byOrder
        return service
    }
    let library = [
        service("old", "2026-10-04"), service("last", "2026-10-11", byOrder: true),
        service("youth", "2026-10-16", type: "Youth"), service("future", "2026-10-25"),
    ]
    let next = service("next", "2026-10-18")
    #expect(PlanSyncLogic.inheritedTimecodeByOrder(for: next, from: library) == true)

    let saved = library.map { $0.id == "last" ? service("last", "2026-10-11") : $0 }
    #expect(PlanSyncLogic.inheritedTimecodeByOrder(for: next, from: saved) == nil)

    #expect(PlanSyncLogic.inheritedTimecodeByOrder(for: service("y", "2026-10-23", type: "Youth"), from: library) == nil)
    #expect(PlanSyncLogic.inheritedTimecodeByOrder(for: service("local", "2026-10-18", type: nil), from: library) == nil)
    #expect(PlanSyncLogic.inheritedTimecodeByOrder(for: service("first", "2026-10-01"), from: library) == nil)
}
