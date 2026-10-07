import Foundation
import Testing
@testable import PresenterCore

@Test func slideRoundTripsThroughJSON() throws {
    let slide = PresenterCore.sampleSlide()
    let data = try JSONEncoder().encode(slide)
    let decoded = try JSONDecoder().decode(Slide.self, from: data)
    #expect(decoded == slide)
}

@Test func slideObjectKindCoversAllCases() {

    #expect(SlideObjectKind.allCases.count == 4)
}

@Test func actionComboRoundTripsThroughJSON() throws {

    let combo = ActionCombo(id: "c1", name: "Sunday Open", actions: [
        SlideAction(id: "a1", kind: .switchOutputPreset, presetId: "preset-1"),
        SlideAction(id: "a2", kind: .timerStart, timerId: "t1"),
        SlideAction(
            id: "a3", kind: .midiOut, midiKind: .controlChange,
            midiChannel: 3, midiNumber: 12, midiValue: 90),
        SlideAction(id: "a4", kind: .fireCombo, comboId: "c2"),
    ])
    let data = try JSONEncoder().encode(combo)
    let decoded = try JSONDecoder().decode(ActionCombo.self, from: data)
    #expect(decoded == combo)
}

@Test func signageBoardAndActionsRoundTrip() throws {

    let board = SignageBoard(id: SignageBoard.wellKnownID, signages: [
        SignageChannel(id: "ch-lobby", name: "Lobby", playlistId: "loop-1"),
        SignageChannel(id: "ch-cafe", name: "Café"),
    ])
    let decodedBoard = try JSONDecoder().decode(
        SignageBoard.self, from: JSONEncoder().encode(board))
    #expect(decodedBoard == board)
    #expect(decodedBoard.signages[1].playlistId == nil)

    let content = SlideAction(
        id: "a1", kind: .setSignage, playlistId: "loop-1", signageId: "ch-lobby")
    let source = SlideAction(
        id: "a2", kind: .setScreenSource, signageId: "ch-lobby", screenId: "screen-1")
    for action in [content, source] {
        let decoded = try JSONDecoder().decode(
            SlideAction.self, from: JSONEncoder().encode(action))
        #expect(decoded == action)
    }
}

@Test func musicActionsRoundTripAndStayAdditive() throws {

    let file = SlideAction(
        id: "a1", kind: .fireAudio, audioItemId: "song-1", audioRepeat: true)
    let playlist = SlideAction(
        id: "a2", kind: .fireAudioPlaylist, playlistId: "walkin-1", audioRepeat: false)
    for action in [file, playlist] {
        let decoded = try JSONDecoder().decode(
            SlideAction.self, from: JSONEncoder().encode(action))
        #expect(decoded == action)
    }

    let bare = SlideAction(id: "a3", kind: .fireAudioPlaylist, playlistId: "walkin-1")
    let object = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(bare)) as? [String: Any]
    #expect(object?["audioItemId"] == nil)
    #expect(object?["audioRepeat"] == nil)
}

@Test func slideActionsFieldStaysAbsentWhenNil() throws {

    let slide = Slide(id: "s1", name: "", objects: [])
    let data = try JSONEncoder().encode(slide)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["actions"] == nil)
    let decoded = try JSONDecoder().decode(Slide.self, from: data)
    #expect(decoded.actions == nil)
}

@Test func playlistsFileUnderTheirLibrarySection() {

    let media = Playlist(
        id: "p1", name: "Loops", playlistKind: .media, entries: [],
        playbackMode: .playAll, crossfadeSeconds: 0
    )
    #expect(media.indexSubkind == "media")

    let legacy = Playlist(
        id: "p2", name: "Walk-in",
        entries: [PlaylistEntry(id: "e1", refKind: .audio, refId: "a1")],
        playbackMode: .playAll, crossfadeSeconds: 0
    )
    #expect(legacy.effectiveKind == .audio)
    let inferredMedia = Playlist(
        id: "p3", name: "Kids videos",
        entries: [PlaylistEntry(id: "e2", refKind: .media, refId: "m1")],
        playbackMode: .playAll, crossfadeSeconds: 0
    )
    #expect(inferredMedia.effectiveKind == .media)
    let empty = Playlist(
        id: "p4", name: "Empty", entries: [], playbackMode: .playAll, crossfadeSeconds: 0
    )
    #expect(empty.effectiveKind == .audio)
}

@Test func editorBackedKindsAreExactlyTheEditorDocuments() {

    let editorBacked = Set(DocumentKind.allCases.filter(\.opensInEditor))
    #expect(editorBacked == [
        .presentation, .theme, .overlay, .confidenceLayout, .media, .audio, .note,
    ])
}
