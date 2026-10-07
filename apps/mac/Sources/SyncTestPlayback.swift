import Foundation
import MediaEngine
import OutputEngine

@MainActor
enum SyncTestPlayback {
    private static var generation = 0

    static func install(outputs: OutputManager, media: MediaEngine) {
        outputs.syncTestPlayback = { on in set(on, media: media) }
    }

    static func set(_ on: Bool, media: MediaEngine) {
        generation += 1
        let mine = generation
        if on {
            Task { @MainActor in
                do {
                    let url = try await movieURL()
                    let prepared = try await media.prepare(url: url)
                    if generation == mine {
                        media.play(prepared, id: OutputManager.syncTestMediaID, loop: true)
                        DiagnosticsStore.shared.note("syncTest", detail: "playing \(url.lastPathComponent)")
                    }
                } catch {
                    DiagnosticsStore.shared.note("syncTest", detail: "failed: \(error)")
                }
            }
        } else {
            media.stop(id: OutputManager.syncTestMediaID)
            DiagnosticsStore.shared.note("syncTest", detail: "stopped")
        }
    }

    static func movieURL() async throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("MxU Slides/Test Patterns", isDirectory: true)
        return try await SyncTestPattern.cachedMovie(in: dir)
    }
}
