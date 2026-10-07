import Foundation
import Testing
@testable import PresenterCore

@Test func crossfadeOverrideBeatsRoomDefaultAndZeroMeansCut() {
    #expect(PlaylistCrossfade.resolve(override: nil, roomDefault: 3) == 3)
    #expect(PlaylistCrossfade.resolve(override: 0, roomDefault: 3) == 0)
    #expect(PlaylistCrossfade.resolve(override: 8, roomDefault: 3) == 8)
    #expect(PlaylistCrossfade.resolve(override: nil, roomDefault: -1) == 0)
    #expect(PlaylistCrossfade.migratedOverride(0) == nil)
    #expect(PlaylistCrossfade.migratedOverride(2) == 2)
    #expect(PlaylistCrossfade.migratedOverride(nil) == nil)
    #expect(PlaylistCrossfade.label(0) == "Off")
    #expect(PlaylistCrossfade.label(3.5) == "3.5s")
}

@LibraryActor @Test func legacyZeroCrossfadeMigratesToFollowTheRoom() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = try Library(rootURL: root)
    _ = try library.create(Playlist(
        id: "legacy", name: "Legacy", entries: [], playbackMode: .playAll, crossfadeSeconds: 0))
    _ = try library.create(Playlist(
        id: "custom", name: "Custom", entries: [], playbackMode: .playAll, crossfadeSeconds: 2))
    _ = try library.create(Playlist(id: "fresh", name: "Fresh", entries: [], playbackMode: .playAll))

    #expect(try library.migrateCrossfadeDefaults() == 1)
    #expect(try library.open(Playlist.self, id: "legacy").value.crossfadeSeconds == nil)
    #expect(try library.open(Playlist.self, id: "custom").value.crossfadeSeconds == 2)
    #expect(try library.open(Playlist.self, id: "fresh").value.crossfadeSeconds == nil)
    #expect(try library.migrateCrossfadeDefaults() == 0)
}
