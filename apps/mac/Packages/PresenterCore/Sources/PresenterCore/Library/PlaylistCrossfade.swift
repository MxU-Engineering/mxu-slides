import Foundation

public enum PlaylistCrossfade {

    public static let defaultSeconds: Double = 3
    public static let maximumSeconds: Double = 12

    public static let presets: [Double] = [1, 2, 4, 8, 12]

    public static func resolve(override: Double?, roomDefault: Double) -> Double {
        max(0, override ?? roomDefault)
    }

    public static func migratedOverride(_ stored: Double?) -> Double? {
        stored == 0 ? nil : stored
    }

    public static func label(_ seconds: Double) -> String {
        seconds <= 0 ? "Off" : "\(seconds.formatted())s"
    }
}

public extension Library {

    @discardableResult
    func migrateCrossfadeDefaults() throws -> Int {
        var migrated = 0
        for id in try store.ids(of: .playlist) {
            let document = try open(Playlist.self, id: id)
            let stored = document.value.crossfadeSeconds
            if PlaylistCrossfade.migratedOverride(stored) != stored {
                try document.update { $0.crossfadeSeconds = nil }
                try save(document)
                migrated += 1
            }
        }
        return migrated
    }
}
