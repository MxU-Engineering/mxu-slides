import Foundation
import Testing
@testable import PresenterCore

private func stem(_ channel: String, at: Double = 0, duration: Double = 180, id: String = UUID().uuidString) -> TimelineCue {
    TimelineCue(id: id, lane: TimelineTracks.lane(for: channel), at: at, duration: duration, mediaId: "audio-\(channel)")
}

@Test func droppedStemsLandOnTheChannelsTheirNamesSay() {
    let channels = [
        TrackChannel(id: "click", name: "Click", role: "click"),
        TrackChannel(id: "keys", name: "Keys"),
        TrackChannel(id: "eg", name: "Electric Guitar"),
        TrackChannel(id: "loop", name: "Loop Pad", matchNames: ["Atmos"]),
    ]
    let on = { TimelineTracks.channel(forFileName: $0, in: channels)?.id }
    #expect(on("Click.wav") == "click")
    #expect(on("01 Keys 1.wav") == "keys")
    #expect(on("Piano.m4a") == nil)
    #expect(on("EG.wav") == "eg")
    #expect(on("EG 2.wav") == nil)
    #expect(on("Atmos.wav") == "loop")
    #expect(on("Metronome.aif") == "click")
    #expect(on("Bass.wav") == nil)
}

@Test func theFirstDropBuildsTheChannelsWithClickAndGuideMarked() {
    var counter = 0
    let result = TimelineTracks.assign(
        fileNames: ["Click Track.wav", "Cues.wav", "Drums.wav", "Keys.wav", "Piano.wav", "Strange Noise.wav"],
        to: [], newID: { counter += 1; return "c\(counter)" })
    #expect(result.channels.map(\.name) == ["Click", "Guide", "Drums", "Keys", "Piano", "Strange Noise"])
    #expect(result.channels.map(\.trackRole) == [.click, .guide, .music, .music, .music, .music])
    #expect(result.assignments["Piano.wav"] != result.assignments["Keys.wav"])
    #expect(TimelineTracks.role(forName: "Click") == .click)
    #expect(TimelineTracks.role(forName: "Vocal Cues") == .guide)
    #expect(TimelineTracks.role(forName: "Drum Click") == .click)
    #expect(TimelineTracks.canonical(["eg", "lead"]).name == "Electric Guitar Lead")
}

@Test func stemsAreBlocksThatMoveTogetherAndNeverTrimTheirStart() {
    let a = stem("click", at: 2, duration: 200)
    let b = stem("keys", at: 2, duration: 190)
    let late = stem("pad", at: 30, duration: 20)
    let slide = TimelineCue(id: "s", lane: TimelineLane.slide.rawValue, at: 5)
    let cues = [a, b, late, slide]
    #expect(TimelineTracks.stems(cues).map(\.id) == [a.id, b.id, late.id])
    #expect(Set(TimelineTracks.group(of: a, in: cues).map(\.id)) == [a.id, b.id])
    #expect(TimelineTracks.group(of: slide, in: cues).map(\.id) == ["s"])

    #expect(PresentationTimelines.contentEnd(cues) == 202)

    let trimmed = PresentationTimelines.edited(a, in: cues, mode: .trim, by: 1)
    #expect(trimmed.at == 3)
    #expect(trimmed.duration == 200)
    let shortened = PresentationTimelines.edited(a, in: cues, mode: .stretch, by: -10)
    #expect(shortened.duration == 190)

    #expect(a.kind == nil)
    #expect(a.trackChannelId == "click")
}

@Test func placingStemsMakesChannelsAndSwapsASongsOldStems() {
    var ids = 0
    let newID = { ids += 1; return "n\(ids)" }
    var cues: [TimelineCue] = []
    let keys = TrackChannel(id: "keys", name: "Keys")
    let made = TimelineTracks.place(
        [.init(fileName: "Click.wav", audioID: "a1", seconds: 200), .init(fileName: "Keys.wav", audioID: "a2", seconds: 190)],
        at: 1.001, channels: [keys], into: &cues, newID: newID)
    #expect(made.map(\.name) == ["Click"])
    #expect(made.first?.trackRole == .click)
    #expect(cues.count == 2)
    #expect(cues.allSatisfy { $0.at == 1 })
    #expect(cues.first { $0.mediaId == "a2" }?.trackChannelId == "keys")

    _ = TimelineTracks.place([.init(fileName: "Keys.wav", audioID: "a3", seconds: 190)],
                             at: 1, channels: [keys] + made, into: &cues, newID: newID)
    #expect(cues.count == 2)
    #expect(cues.contains { $0.mediaId == "a3" } && !cues.contains { $0.mediaId == "a2" })

    _ = TimelineTracks.place([.init(fileName: "Mystery.wav", audioID: "a4", seconds: 10)],
                             at: 1, channel: "keys", channels: [keys] + made, into: &cues, newID: newID)
    #expect(cues.first { $0.mediaId == "a4" }?.trackChannelId == "keys")
}

@Test func eightGuitarsAreEightChannelsAndNoStemReplacesAnother() {
    var ids = 0
    let newID = { ids += 1; return "g\(ids)" }
    let guitars = (1 ... 8).map { "EG \($0).wav" }
    let first = TimelineTracks.assign(fileNames: guitars, to: [], newID: newID)
    #expect(first.channels.map(\.name) == (1 ... 8).map { "Electric Guitar \($0)" })
    #expect(Set(first.assignments.values).count == 8)

    let again = TimelineTracks.assign(fileNames: guitars.reversed(), to: first.channels, newID: newID)
    #expect(again.channels == first.channels)
    #expect(again.assignments["EG 3.wav"] == first.assignments["EG 3.wav"])

    #expect(TimelineTracks.channel(forFileName: "EG2.aif", in: first.channels)?.name == "Electric Guitar 2")
    let keys = [TrackChannel(id: "k", name: "Keys")]
    #expect(TimelineTracks.channel(forFileName: "Keys 1.wav", in: keys)?.id == "k")
    #expect(TimelineTracks.channel(forFileName: "Keys 2.wav", in: keys) == nil)

    let pair = TimelineTracks.assign(fileNames: ["EG.wav", "EG Lead.wav", "Keys.wav", "Piano.wav"], to: keys, newID: newID)
    #expect(pair.channels.map(\.name) == ["Electric Guitar", "Electric Guitar Lead", "Keys", "Piano"])

    let twice = TimelineTracks.assign(fileNames: ["EG.wav", "eg.WAV"], to: [], newID: newID)
    #expect(twice.channels.map(\.name) == ["Electric Guitar", "Electric Guitar 2"])
    var cues: [TimelineCue] = []
    _ = TimelineTracks.place(guitars.enumerated().map { .init(fileName: $1, audioID: "a\($0)", seconds: 60) },
                             at: 0, channels: first.channels, into: &cues, newID: newID)
    #expect(cues.count == 8)
}

@Test func aChannelMadeFromMonoStemsStartsMono() {
    var cues: [TimelineCue] = []
    let made = TimelineTracks.place(
        [.init(fileName: "Click.wav", audioID: "a", seconds: 10, channels: 1),
         .init(fileName: "Keys.wav", audioID: "b", seconds: 10, channels: 2),
         .init(fileName: "Bass.wav", audioID: "c", seconds: 10)],
        at: 0, channels: [], into: &cues)
    #expect(made.first { $0.name == "Click" }?.mono == true)
    #expect(made.first { $0.name == "Keys" }?.mono == nil)
    #expect(made.first { $0.name == "Bass" }?.mono == nil)
}

@Test func aSongShowsOnlyTheTracksItHasStemsOnAndTheOnesAddedToIt() {
    let channels = (1 ... 10).map { TrackChannel(id: "eg\($0)", name: "Electric Guitar \($0)") }
        + [TrackChannel(id: "click", name: "Click", role: "click")]
    let cues = [stem("eg2"), stem("click"), stem("gone"),
                TimelineCue(id: "s", lane: TimelineLane.slide.rawValue, at: 0)]
    let rows = TimelineTracks.rows(channels: channels, cues: cues, added: ["eg7"])

    #expect(rows.map(\.id) == ["eg2", "eg7", "click", "gone"])
    #expect(rows.last?.name == "Removed channel")
    #expect(TimelineTracks.rows(channels: channels, cues: [], added: []).isEmpty)
}

@Test func aRealMultiTracksSetBuildsChannelsNamedAfterItsStems() {

    let files = ["AG", "BGVS", "Bass", "Click Track", "Drums", "EG 1", "EG 2", "EG 3", "EG 4", "Electric Piano",
                 "Guide", "Keys 1", "Mellotron", "Organ", "Perc", "Piano", "Strings", "Synth Bass 2", "Synth Bass"]
        .map { $0 + ".m4a" }
    let result = TimelineTracks.assign(fileNames: files, to: [])

    #expect(result.channels.map(\.name) == [
        "Click", "Guide", "Drums", "Percussion", "Bass", "Synth Bass", "Synth Bass 2",
        "Electric Guitar 1", "Electric Guitar 2", "Electric Guitar 3", "Electric Guitar 4", "Acoustic Guitar",
        "Electric Piano", "Keys 1", "Mellotron", "Organ", "Piano", "Background Vocals", "Strings",
    ])
    #expect(Set(result.assignments.values).count == files.count)
    #expect(result.channels.filter { $0.trackRole != .music }.map(\.name) == ["Click", "Guide"])

    let next = TimelineTracks.assign(
        fileNames: ["Way Maker - Click.wav", "Way Maker - EG 2.wav", "Way Maker - Keys.wav", "Way Maker - Bass.wav"],
        to: result.channels)
    #expect(next.channels.count == result.channels.count)
    let byName = Dictionary(uniqueKeysWithValues: result.channels.map { ($0.name, $0.id) })
    #expect(next.assignments["Way Maker - Click.wav"] == byName["Click"])
    #expect(next.assignments["Way Maker - EG 2.wav"] == byName["Electric Guitar 2"])
    #expect(next.assignments["Way Maker - Keys.wav"] == byName["Keys 1"])

    var moved = result.channels
    moved.append(moved.remove(at: 0))
    let pads = TimelineTracks.assign(fileNames: ["Pads.wav"], to: moved)
    #expect(pads.channels.last?.name == "Click")
    #expect(pads.channels.firstIndex { $0.name == "Pads" } == pads.channels.firstIndex { $0.name == "Background Vocals" }! - 1)
}

@Test func everyChannelFeedsItsFamilysBus() {

    let expected: [(String, String?, TimelineTracks.Family)] = [
        ("Acoustic Guitar", nil, .acousticGuitars), ("Background Vocals", nil, .vocals), ("Bass", nil, .bass),
        ("Click", "click", .click), ("Drums", nil, .drums), ("Electric Guitar 3", nil, .electricGuitars),
        ("Electric Piano", nil, .keys), ("Guide", "guide", .guide), ("Keys 1", nil, .keys),
        ("Mellotron", nil, .keys), ("Organ", nil, .keys), ("Percussion", nil, .percussion), ("Piano", nil, .keys),
        ("Strings", nil, .strings), ("Synth Bass 2", nil, .bass), ("Synth Bass", nil, .bass),
        ("Lead Vocal", nil, .vocals), ("Lead Guitar", nil, .electricGuitars), ("Pads", nil, .synths),
        ("Track", nil, .other),
    ]
    for (name, role, family) in expected {
        #expect(TimelineTracks.family(of: TrackChannel(id: name, name: name, role: role)) == family, "\(name)")
    }

    #expect(TimelineTracks.Family.click.colorName == "Orange")
    #expect(TimelineTracks.Family.drums.colorName == TimelineTracks.Family.percussion.colorName)
}

@Test func theMixerShowsTracksOnceTheChurchHasThem() {

    var channels: [TrackChannel] = []
    #expect(!TimelineTracks.hasTracks(channels))
    let mixes: [(id: String, folderId: String?)] = [
        ("main", nil), ("bus-keys", "tracks"), ("bus-click", "tracks"), ("stream", "mine"), ("lobby", nil),
    ]
    let folders = ["tracks", "mine", "empty"]
    let before = TimelineTracks.shownMixes(
        mixes, folders: folders, buses: ["bus-keys", "bus-click"], hasTracks: TimelineTracks.hasTracks(channels))
    #expect(before.mixes == ["main", "stream", "lobby"])
    #expect(before.folders == ["mine", "empty"])
    var cues: [TimelineCue] = []
    channels = TimelineTracks.place(
        [.init(fileName: "Click.wav", audioID: "a", seconds: 9), .init(fileName: "Keys.wav", audioID: "b", seconds: 9)],
        at: 0, channels: channels, into: &cues)
    #expect(TimelineTracks.hasTracks(channels))
    let after = TimelineTracks.shownMixes(
        mixes, folders: folders, buses: ["bus-keys", "bus-click"], hasTracks: TimelineTracks.hasTracks(channels))
    #expect(after.mixes.count == 5 && after.folders.count == 3)
}

@Test func theOneClickPatchLaysTheFamilyMixesAcrossTheInterface() {
    let sixteen = TimelineTracks.patchPlan(start: 0, deviceChannels: 16)
    #expect(sixteen.count == 12)
    #expect(sixteen.first! == (.click, 0) && sixteen[1] == (.guide, 1) && sixteen.last! == (.other, 11))

    let late = TimelineTracks.patchPlan(start: 8, deviceChannels: 16)
    #expect(late.count == 8 && late.last!.channel == 15)

    let room = TimelineTracks.patchPlan(
        TimelineTracks.Family.allCases.filter { $0 != .click && $0 != .guide }, start: 2, deviceChannels: 16)
    #expect(room.first! == (.drums, 2) && room.count == 10)
}

@Test func layoutsByOutputCountPutClickAndGuideFirst() {
    let two = TimelineTracks.layout(outputs: 2)
    #expect(two[.click] == [0] && two[.guide] == [0])
    #expect(two[.drums] == [1] && two[.other] == [1])
    let three = TimelineTracks.layout(outputs: 3)
    #expect(three[.click] == [0] && three[.keys] == [1, 2])
    let four = TimelineTracks.layout(outputs: 4)
    #expect(four[.click] == [0] && four[.guide] == [1] && four[.bass] == [2, 3])
    for size in TimelineTracks.layoutSizes {
        let layout = TimelineTracks.layout(outputs: size)

        #expect(layout.count == TimelineTracks.Family.allCases.count - (size == 1 ? 2 : 0))
        #expect(layout.values.allSatisfy { $0.allSatisfy { $0 < size } })
    }

    #expect(TimelineTracks.layout(fitting: 6) == TimelineTracks.layout(outputs: 4))
    #expect(TimelineTracks.layout(fitting: 32) == TimelineTracks.layout(outputs: 22))
    #expect(TimelineTracks.layout(fitting: 22)[.other] == [20, 21])
    #expect(TimelineTracks.layout(outputs: 0).isEmpty)
}

@Test func soloQuietsTheOtherMusicChannelsButNeverClickOrGuide() {
    let channels = [TrackChannel(id: "c", name: "Click", role: "click"), TrackChannel(id: "k", name: "Keys"),
                    TrackChannel(id: "b", name: "Bass"), TrackChannel(id: "d", name: "Drums")]
    #expect(TimelineTracks.silencedBySolo(channels, soloed: []).isEmpty)
    #expect(TimelineTracks.silencedBySolo(channels, soloed: ["k"]) == ["b", "d"])
    #expect(TimelineTracks.silencedBySolo(channels, soloed: ["k", "b"]) == ["d"])

    #expect(TimelineTracks.silencedBySolo(channels, soloed: ["c"]).isEmpty)
}

@Test func theFoldedBarSpansEveryStemAndReachesThemAll() {
    let song = (0 ..< 3).map { TimelineCue(id: "s\($0)", lane: "track:c\($0)", at: 2, duration: 300, mediaId: "a\($0)") }
    let later = TimelineCue(id: "late", lane: "track:c9", at: 90, duration: 250, mediaId: "z")
    let slide = TimelineCue(id: "slide", lane: "slides", at: 5)
    let cues = song + [later, slide]
    let bar = TimelineTracks.folded(TimelineTracks.stems(cues), in: cues)
    #expect(bar?.at == 2 && bar?.duration == 338)
    #expect(TimelineTracks.reach(of: bar!, in: cues) == ["s0", "s1", "s2", "late"])
    #expect(TimelineTracks.reach(of: song[0], in: cues) == ["s0", "s1", "s2"])
    #expect(TimelineTracks.reach(of: slide, in: cues) == ["slide"])
}

@Test func thePlayheadReadsLikeTheRuler() {
    #expect(PresentationTimelines.playheadClock(158.74) == "2:38.7")
    #expect(PresentationTimelines.playheadClock(0) == "0:00.0")
    #expect(PresentationTimelines.playheadClock(3599.99) == "59:59.9")
}

@Test func aDropFindsItsRowWhateverTheHeights() {
    let heights = [26.0, 26, 60, 20]
    #expect(PresentationTimelines.row(atY: 0, heights: heights) == 0)
    #expect(PresentationTimelines.row(atY: 30, heights: heights) == 1)
    #expect(PresentationTimelines.row(atY: 54, heights: heights) == 2)
    #expect(PresentationTimelines.row(atY: 114, heights: heights) == 2)
    #expect(PresentationTimelines.row(atY: 115, heights: heights) == 3)
    #expect(PresentationTimelines.row(atY: 136, heights: heights) == nil)
    #expect(PresentationTimelines.row(atY: -1, heights: heights) == nil)
}
