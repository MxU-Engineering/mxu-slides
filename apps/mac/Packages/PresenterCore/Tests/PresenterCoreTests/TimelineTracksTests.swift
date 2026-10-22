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
    #expect(pair.channels.map(\.name) == ["Keys", "Electric Guitar", "Electric Guitar Lead", "Piano"])

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
        "Acoustic Guitar", "Background Vocals", "Bass", "Click", "Drums", "Electric Guitar 1", "Electric Guitar 2",
        "Electric Guitar 3", "Electric Guitar 4", "Electric Piano", "Guide", "Keys 1", "Mellotron", "Organ",
        "Percussion", "Piano", "Strings", "Synth Bass 2", "Synth Bass",
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
}
