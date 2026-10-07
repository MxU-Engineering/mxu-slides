import Foundation

public enum MediaAutoAdvance {

    public static let minimumStillDwellSeconds: Double = 0.5

    public static func isEnabled(_ playlist: Playlist) -> Bool {
        playlist.autoAdvance ?? false
    }

    public static func delay(for entry: PlaylistEntry, in playlist: Playlist) -> Double {
        max(entry.autoAdvanceDelaySeconds ?? playlist.autoAdvanceDelaySeconds ?? 0, 0)
    }

    public static func stillDwell(for entry: PlaylistEntry, in playlist: Playlist) -> Double {
        max(delay(for: entry, in: playlist), minimumStillDwellSeconds)
    }

    public static func leadSeconds(fromDelay delay: Double) -> Double {
        max(0, -delay)
    }

    public static func shouldPreFire(remainingWallClock: Double, delay: Double) -> Bool {
        let lead = leadSeconds(fromDelay: delay)
        return lead > 0 && remainingWallClock <= lead
    }
}
