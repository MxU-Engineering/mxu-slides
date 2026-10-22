import Foundation
import Testing
@testable import PresenterCore

private let keys = TrackChannel(id: "keys", name: "Keys")
private let click = TrackChannel(id: "click", name: "Click", role: "click")

@Test func anImportPlansWhatMatchedAndWhatWouldMakeAChannel() {
    var ids = 0
    let plan = TimelineTracks.plan(
        [.init(fileName: "Click.wav", audioID: "a", seconds: 9), .init(fileName: "Piano.wav", audioID: "b", seconds: 9, channels: 1),
         .init(fileName: "Bass.wav", audioID: "c", seconds: 9)],
        channels: [click, keys], newID: { ids += 1; return "n\(ids)" })
    #expect(plan.assignments == ["Click.wav": "click"])
    #expect(plan.unmatched.map(\.fileName) == ["Piano.wav", "Bass.wav"])
    #expect(plan.unmatched.map(\.proposed.name) == ["Piano", "Bass"])
    #expect(plan.unmatched[0].proposed.mono == true)

    let onRow = TimelineTracks.plan([.init(fileName: "Mystery.wav", audioID: "d", seconds: 1)], channel: "keys", channels: [keys])
    #expect(onRow == .init(assignments: ["Mystery.wav": "keys"], unmatched: []))
}

@Test func theSheetsChoicesPutFilesOnChannelsAndRememberThem() {
    var ids = 0
    let plan = TimelineTracks.plan(
        [.init(fileName: "Piano.wav", audioID: "a", seconds: 9), .init(fileName: "Organ.wav", audioID: "b", seconds: 9),
         .init(fileName: "Bells.wav", audioID: "c", seconds: 9)],
        channels: [click, keys], newID: { ids += 1; return "n\(ids)" })
    let resolution = TimelineTracks.resolve(plan, choices: [
        "Piano.wav": .existing("keys"),
        "Organ.wav": .new(name: "Count In"),
    ])
    #expect(resolution.assignments["Piano.wav"] == "keys")
    #expect(resolution.made.map(\.name) == ["Count In", "Bells"])
    #expect(resolution.made[0].trackRole == .click)
    #expect(resolution.remembered == ["keys": ["Piano"]])
    let list = TimelineTracks.adding(resolution, to: [click, keys])
    #expect(list.map(\.name) == ["Click", "Count In", "Keys", "Bells"])
    #expect(list.first { $0.id == "keys" }?.matchNames == ["Piano"])

    #expect(TimelineTracks.channel(forFileName: "Piano.wav", in: list)?.id == "keys")

    #expect(TimelineTracks.adding(resolution, to: list).first { $0.id == "keys" }?.matchNames == ["Piano"])

    #expect(TimelineTracks.resolve(plan, choices: ["Piano.wav": .existing("keys")], remember: false).remembered.isEmpty)

    #expect(TimelineTracks.resolve(plan).made.map(\.name) == ["Piano", "Organ", "Bells"])
}

@Test func aRememberedNameLandsOnANumberedChannel() {
    let guitar = TrackChannel(id: "eg2", name: "Electric Guitar 2", matchNames: ["Lead Gtr"])
    #expect(TimelineTracks.channel(forFileName: "Lead Gtr.wav", in: [guitar])?.id == "eg2")
    #expect(TimelineTracks.channel(forFileName: "Lead Gtr 3.wav", in: [guitar]) == nil)

    let pads = TrackChannel(id: "pad", name: "Pads 2", matchNames: ["Atmos"])
    #expect(TimelineTracks.channel(forFileName: "Big Atmos Swell.wav", in: [pads]) == nil)
}

@Test func addingATrackByNamePutsItInPlaybacksOrder() {
    var list = [click, keys]
    let made = TimelineTracks.adding(named: "  Guide ", to: &list, id: "g")
    #expect(made?.trackRole == .guide)
    #expect(list.map(\.id) == ["click", "g", "keys"])
    #expect(TimelineTracks.adding(named: " ", to: &list) == nil)
    #expect(list.count == 3)
}

@Test func aMoveGivesThePreMoveIndicesAndTheNewOrder() {
    let list = ["a", "b", "c", "d"].map { TrackChannel(id: $0, name: $0) }
    let up = TimelineTracks.move("c", before: "a", in: list)
    #expect(up?.from == 2 && up?.before == 0)
    #expect(up?.next.map(\.id) == ["c", "a", "b", "d"])
    let down = TimelineTracks.move("a", before: "d", in: list)
    #expect(down?.next.map(\.id) == ["b", "c", "a", "d"])
    #expect(TimelineTracks.move("b", before: nil, in: list)?.next.map(\.id) == ["a", "c", "d", "b"])
    #expect(TimelineTracks.move("b", before: "c", in: list) == nil)
    #expect(TimelineTracks.move("gone", before: "a", in: list) == nil)
}

@Test func aReorderPersistsAsOneListMove() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("track-move-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try await Task { @LibraryActor in
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        let list = TrackChannelList(id: TrackChannelList.wellKnownID, channels: ["a", "b", "c"].map { TrackChannel(id: $0, name: $0.uppercased()) })
        _ = try engine.modify(TrackChannelList.self, id: list.id, orMake: { list }) { _ in }
        _ = try engine.edit(TrackChannelList.self, id: list.id) { try TrackChannelList.move("c", before: "a", on: $0) }
        let reopened = try DocumentStore(rootURL: root).load(TrackChannelList.self, id: list.id).value
        #expect(reopened.channels.map(\.id) == ["c", "a", "b"])
        #expect(reopened.channels.map(\.name) == ["C", "A", "B"])
    }.value
}

@Test func aSongUsesTheChannelsItsTimelinesHaveStemsOn() {
    var song = Presentation(id: "p", name: "Song", presentationKind: .song, themeId: "", slides: [])
    #expect(TimelineTracks.channelIDs(in: song).isEmpty)
    song.timelines = [
        PresentationTimeline(id: "t1", timecodeEnabled: false, timecodeStart: 0, cues: [
            TimelineCue(id: "s1", lane: TimelineTracks.lane(for: "keys"), at: 0, mediaId: "a"),
            TimelineCue(id: "x", lane: TimelineLane.slide.rawValue, at: 0),
        ]),
        PresentationTimeline(id: "t2", arrangementId: "short", timecodeEnabled: false, timecodeStart: 0, cues: [
            TimelineCue(id: "s2", lane: TimelineTracks.lane(for: "click"), at: 0, mediaId: "b"),
        ]),
    ]
    #expect(TimelineTracks.channelIDs(in: song) == ["keys", "click"])
}

@Test func aRenameOrRoleChangeMovesTheFamilySendAndKeepsClickOffMain() {
    let bus = { (family: TimelineTracks.Family) in "bus-\(family.rawValue)" }
    let guitar = TrackChannel(id: "x", name: "Electric Guitar 2")
    var piano = guitar
    piano.name = "Piano"
    let renamed = TimelineTracks.edited(
        sends: ["bus-Electric Guitars": 0.8, "monitor": 0.5], route: nil, from: guitar, to: piano, bus: bus, main: "main")
    #expect(renamed.sends == ["bus-Keys": 0.8, "monitor": 0.5])
    #expect(renamed.route == nil)

    var clicked = guitar
    clicked.role = "click"
    let toClick = TimelineTracks.edited(
        sends: ["bus-Electric Guitars": 1], route: "main", from: guitar, to: clicked, bus: bus, main: "main")
    #expect(toClick.sends == ["bus-Click": 1, "main": 0])
    #expect(toClick.route == "")

    let kept = TimelineTracks.edited(sends: [:], route: "iem", from: guitar, to: clicked, bus: bus, main: "main")
    #expect(kept.sends == ["main": 0])
    #expect(kept.route == "iem")

    var mono = guitar
    mono.mono = true
    #expect(TimelineTracks.edited(sends: ["bus-Electric Guitars": 1], route: nil, from: guitar, to: mono, bus: bus, main: "main").sends
        == ["bus-Electric Guitars": 1])
}

@MainActor @Test func theTracksAreaTakesAudioFilesAndFoldersFromFinder() {
    let file = { (name: String) in URL(fileURLWithPath: "/tmp/" + name) }
    #expect(TimelineTracks.takesFinderDrop([file("Click Track.m4a")]))
    #expect(TimelineTracks.takesFinderDrop([file("Album.jpg"), file("Keys.wav")]))
    #expect(TimelineTracks.takesFinderDrop([URL(fileURLWithPath: "/tmp/Run To The Father", isDirectory: true)]))
    #expect(!TimelineTracks.takesFinderDrop([file("Walk-in.mp4"), file("Album.jpg")]))
    #expect(!TimelineTracks.takesFinderDrop([]))
}

@Test func oneFileDroppedOnATrackRowGoesThereAndASongsFilesGoByName() {
    let stems: [TimelineStemImport] = [.init(fileName: "Piano.wav", audioID: "a", seconds: 9), .init(fileName: "Keys.wav", audioID: "b", seconds: 9)]

    let several = TimelineTracks.plan(stems, channel: "click", channels: [click, keys])
    #expect(several.assignments == ["Keys.wav": "keys"])
    #expect(several.unmatched.map(\.fileName) == ["Piano.wav"])
    var cues: [TimelineCue] = []
    TimelineTracks.place(stems, at: 2, assignments: TimelineTracks.plan([stems[0]], channel: "click", channels: [click]).assignments, into: &cues)
    #expect(cues.map(\.trackChannelId) == ["click"])
    #expect(cues.first?.at == 2)
}

@Test func theTrackListSaysTheFamilyMixOnlyWhenTheNameDoesnt() {
    let line = { (name: String, role: String?, mono: Bool?) in
        TimelineTracks.listSubtitle(TrackChannel(id: "x", name: name, role: role, mono: mono))
    }
    #expect(line("Drums", nil, nil) == "Stereo")
    #expect(line("Electric Guitar 2", nil, true) == "Mono")
    #expect(line("Click", "click", nil) == "Stereo")
    #expect(line("Synth Bass", nil, nil) == "Bass mix · Stereo")
    #expect(line("Piano", nil, nil) == "Keys mix · Stereo")
    #expect(line("Background Vocals", nil, nil) == "Vocals mix · Stereo")
    #expect(line("Drum Click", "click", true) == "Click mix · Mono")
}

@Test func oneMoreFileJoinsTheTracksItemTheSongUses() {
    let set = TrackSet(id: "s", name: "Song", stems: [TrackSetStem(audioId: "a", name: "Click"), TrackSetStem(audioId: "b", name: "Keys")])
    let other = TrackSet(id: "o", name: "Other", stems: [TrackSetStem(audioId: "z", name: "Bass")])
    let cues = [TimelineCue(id: "c", lane: TimelineTracks.lane(for: "keys"), at: 0, mediaId: "b"),
                TimelineCue(id: "x", lane: TimelineLane.slide.rawValue, at: 0)]
    #expect(TrackSets.usedBy(cues, in: [other, set])?.id == "s")
    #expect(TrackSets.usedBy([], in: [other, set]) == nil)

    let shared = TrackSet(id: "x", name: "Another", stems: [TrackSetStem(audioId: "a", name: "Click")])
    let both = cues + [TimelineCue(id: "d", lane: TimelineTracks.lane(for: "click"), at: 0, mediaId: "a")]
    #expect(TrackSets.usedBy(both, in: [shared, set])?.id == "s")
    let joined = TrackSets.joining([TrackSetStem(audioId: "n", name: "Drums"), TrackSetStem(audioId: "a", name: "Click")], to: set)
    #expect(joined.stems.map(\.audioId) == ["a", "b", "n"])
}

@Test func aRowDroppedOnAnotherTakesItsPlace() {
    let list = ["a", "b", "c", "d"].map { TrackChannel(id: $0, name: $0) }
    func order(_ id: String, onto target: String) -> [String]? {
        guard let drop = TimelineTracks.dropping(id, onto: target, in: list) else { return nil }
        return TimelineTracks.move(id, before: drop.before, in: list)?.next.map(\.id)
    }
    #expect(order("d", onto: "b") == ["a", "d", "b", "c"])
    #expect(order("a", onto: "c") == ["b", "c", "a", "d"])
    #expect(order("a", onto: "d") == ["b", "c", "d", "a"])
    #expect(TimelineTracks.dropping("a", onto: "a", in: list) == nil)
    #expect(TimelineTracks.dropping("gone", onto: "a", in: list) == nil)
}
