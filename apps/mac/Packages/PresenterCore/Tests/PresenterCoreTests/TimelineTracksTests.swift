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
    #expect(on("01 - Way Maker (Keys 1).wav") == "keys")
    #expect(on("Piano.m4a") == "keys")
    #expect(on("EG 2.wav") == "eg")
    #expect(on("Atmos.wav") == "loop")
    #expect(on("Metronome.aif") == "click")
    #expect(on("Bass.wav") == nil)
}

@Test func theFirstDropBuildsTheChannelsWithClickAndGuideMarked() {
    var counter = 0
    let result = TimelineTracks.assign(
        fileNames: ["Click Track.wav", "Cues.wav", "Drums.wav", "Keys.wav", "Piano.wav", "Strange Noise.wav"],
        to: [], newID: { counter += 1; return "c\(counter)" })
    #expect(result.channels.map(\.name) == ["Click", "Guide", "Drums", "Keys", "Strange Noise"])
    #expect(result.channels.map(\.trackRole) == [.click, .guide, .music, .music, .music])

    #expect(result.assignments["Piano.wav"] == result.assignments["Keys.wav"])
    #expect(TimelineTracks.role(forName: "Click") == .click)
    #expect(TimelineTracks.role(forName: "Vocal Cues") == .guide)
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

    _ = TimelineTracks.place([.init(fileName: "Keys v2.wav", audioID: "a3", seconds: 190)],
                             at: 1, channels: [keys] + made, into: &cues, newID: newID)
    #expect(cues.count == 2)
    #expect(cues.contains { $0.mediaId == "a3" } && !cues.contains { $0.mediaId == "a2" })

    _ = TimelineTracks.place([.init(fileName: "Mystery.wav", audioID: "a4", seconds: 10)],
                             at: 1, channel: "keys", channels: [keys] + made, into: &cues, newID: newID)
    #expect(cues.first { $0.mediaId == "a4" }?.trackChannelId == "keys")
}
