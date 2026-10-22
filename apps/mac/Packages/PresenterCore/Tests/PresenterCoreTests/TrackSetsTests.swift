import Foundation
import Testing
@testable import PresenterCore

@Test func aMultiTracksFolderSaysTheSongKeyAndTempo() {
    let found = TrackSets.download(fromFolder: "Run To The Father-Run to the Father-C-68.50bpm")
    #expect(found == .init(song: "Run To The Father", key: "C", tempo: 68.5))
    #expect(TrackSets.download(fromFolder: "Way Maker-Default-Bb-136bpm").key == "Bb")
    #expect(TrackSets.download(fromFolder: "Stems").key == nil)
    #expect(TrackSets.download(fromFolder: "Song-Live-H-90bpm").key == nil)

    let files = ["/Users/x/Downloads/Run To The Father-Run to the Father-C-68.50bpm/MultiTracks/EG 1.m4a"]
    #expect(TrackSets.download(forFiles: files).tempo == 68.5)

    #expect(TrackSets.download(forFiles: ["/Users/x/Downloads/Run To The Father-Run to the Father-C-68.50bpm"]).key == "C")
    #expect(TrackSets.name(song: "Run to the Father", key: "C", tempo: 68.5) == "Run to the Father — C, 68.5 bpm")
    #expect(TrackSets.name(song: "Way Maker", key: nil, tempo: 136) == "Way Maker — 136 bpm")
    #expect(TrackSets.name(song: "Song", key: nil, tempo: nil) == "Song")
}

@Test func setsHideTheirStemsFromMusicAndASecondDropReusesTheSet() {
    let set = TrackSet(id: "s", name: "Song", stems: [
        TrackSetStem(audioId: "a1", name: "Click"), TrackSetStem(audioId: "a2", name: "Keys", channelId: "keys"),
    ])
    #expect(TrackSets.stemIDs([set]) == ["a1", "a2"])
    #expect(TrackSets.existing(withStems: ["a2", "a1"], in: [set])?.id == "s")
    #expect(TrackSets.existing(withStems: ["a1"], in: [set]) == nil)
}

@Test func aSongsTimelineUsesItsStemsAndMedia() {
    var deck = Presentation(id: "p", name: "Song", presentationKind: .song, themeId: "", slides: [])
    deck.timelines = [PresentationTimeline(id: "t", timecodeEnabled: false, timecodeStart: 0, cues: [
        TimelineCue(id: "c1", lane: TimelineTracks.lane(for: "keys"), at: 0, mediaId: "stem-keys"),
        TimelineCue(id: "c2", lane: TimelineLane.loopingVideos.rawValue, at: 0, mediaId: "bg"),
    ])]
    #expect(MediaReferences.ids(in: deck).isSuperset(of: ["stem-keys", "bg"]))
}

@Test func aSetsStemsLandOnTheChannelsTheyKept() {
    let channels = [TrackChannel(id: "lead", name: "Lead Guitar"), TrackChannel(id: "eg", name: "Electric Guitar")]
    var cues: [TimelineCue] = []

    _ = TimelineTracks.place(
        [.init(fileName: "EG", audioID: "a", seconds: 10, channelId: "lead"),
         .init(fileName: "EG 2", audioID: "b", seconds: 10, channelId: "gone")],
        at: 0, channels: channels, into: &cues)
    #expect(cues.first { $0.mediaId == "a" }?.trackChannelId == "lead")
    #expect(cues.first { $0.mediaId == "b" }?.trackChannelId != "gone")
}
