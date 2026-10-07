import AudioEngine
import Foundation
import Observation
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

@MainActor
@Observable
final class MediaPlaylistController {
    private struct Walk {
        var playlistID: String
        var queue: PlaylistQueue

        var delays: [String: Double]
        var refs: [String: String]
        var entryID: String
        var mediaID: String
        var layer: LayerKind
        var isVideo: Bool
        var startedAt: Date

        var finishedAt: Date?
    }

    private static let missingTransportGraceSeconds: Double = 10

    private var walk: Walk?
    private var tickTask: Task<Void, Never>?
    private let appModel: AppModel
    private weak var controls: ServiceControls?

    init(appModel: AppModel, controls: ServiceControls) {
        self.appModel = appModel
        self.controls = controls
        armMutationWatch()
    }

    var livePlaylistID: String? { walk?.playlistID }
    var liveEntryID: String? { walk?.entryID }

    func isWalking(_ playlistID: String) -> Bool {
        walk?.playlistID == playlistID
    }

    func play(playlistID: String, startAt entryID: String? = nil) {
        guard let playlist = try? appModel.playlist(playlistID) else { return }
        let mediaEntries = playlist.entries.filter { $0.refKind == .media }
        guard !mediaEntries.isEmpty else { return }
        var queue = PlaylistQueue(
            entryIDs: mediaEntries.map(\.id),
            repeatBehavior: AudioPlayer.repeatBehavior(for: playlist.playbackMode),
            shuffled: playlist.shuffle ?? false
        )
        queue.start(at: entryID)
        endWalk()
        var next = Walk(
            playlistID: playlistID,
            queue: queue,
            delays: Dictionary(uniqueKeysWithValues: mediaEntries.map {
                ($0.id, MediaAutoAdvance.delay(for: $0, in: playlist))
            }),
            refs: Dictionary(uniqueKeysWithValues: mediaEntries.map { ($0.id, $0.refId) }),
            entryID: "", mediaID: "", layer: .videos, isVideo: false,
            startedAt: Date()
        )
        guard let startID = next.queue.currentEntryID,
              startEntry(startID, walk: &next)
        else { return }
        guard MediaAutoAdvance.isEnabled(playlist) else { return }
        walk = next
        syncTickTask()
    }

    func stop() {
        guard let walk else { return }
        if let controls, controls.state.liveMedia[walk.layer]?.mediaId == walk.mediaID {
            controls.clear(layer: walk.layer)
        }
        endWalk()
    }

    private func endWalk() {
        walk = nil
        syncTickTask()
    }

    @discardableResult
    private func startEntry(_ entryID: String, walk: inout Walk) -> Bool {
        var target = entryID
        for _ in 0 ..< max(walk.queue.entryIDs.count, 1) {
            if let refID = walk.refs[target],
               let item = appModel.media(refID),
               let controls {
                let isVideo = item.mediaKind == .video

                let loops: Bool? = isVideo
                    ? (walk.queue.repeatBehavior == .single ? true : false)
                    : nil
                let previousID = walk.mediaID
                let previousLayer = walk.layer

                let layer = controls.fire(mediaItem: item, loopsOverride: loops, context: .playlistWalk)

                if !previousID.isEmpty, previousID != item.id, previousLayer != layer,
                   controls.state.liveMedia[previousLayer]?.mediaId == previousID {
                    controls.clear(layer: previousLayer)
                }
                walk.entryID = target
                walk.mediaID = item.id
                walk.layer = layer
                walk.isVideo = isVideo
                walk.startedAt = Date()
                walk.finishedAt = nil
                return true
            }
            DiagnosticsStore.shared.note("mediaWalk.entry.missing", detail: target)
            guard let skipped = walk.queue.advanceAfterNaturalEnd(), skipped != target
            else { return false }
            target = skipped
        }
        return false
    }

    private func syncTickTask() {
        if walk == nil {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard var walk, let controls else { return }

        guard controls.state.liveMedia[walk.layer]?.mediaId == walk.mediaID else {
            return endWalk()
        }

        guard walk.queue.repeatBehavior != .single else { return }
        let now = Date()
        let delay = walk.delays[walk.entryID] ?? 0
        if walk.isVideo {
            guard let transport = controls.render.media.transport(id: walk.mediaID) else {

                if now.timeIntervalSince(walk.startedAt) > Self.missingTransportGraceSeconds {
                    advance(&walk)
                }
                return
            }
            if transport.isLooping {

                let due = walk.startedAt.addingTimeInterval(transport.duration + delay)
                if now >= due { advance(&walk) }
                return
            }
            if walk.finishedAt == nil, MediaTransportController.isFinished(transport, at: now) {
                walk.finishedAt = now
                self.walk = walk
            }
            guard let finishedAt = walk.finishedAt,
                  now >= finishedAt.addingTimeInterval(delay)
            else { return }
            advance(&walk)
        } else {
            let dwell = max(delay, MediaAutoAdvance.minimumStillDwellSeconds)
            guard now >= walk.startedAt.addingTimeInterval(dwell) else { return }
            advance(&walk)
        }
    }

    private func advance(_ walk: inout Walk) {
        guard let next = walk.queue.advanceAfterNaturalEnd() else {

            return endWalk()
        }
        if startEntry(next, walk: &walk) {
            self.walk = walk
        } else {
            endWalk()
        }
    }

    private func armMutationWatch() {
        withObservationTracking {

            _ = appModel.version(of: .playlist)
            _ = appModel.version(of: .media)
            _ = appModel.version(of: .audio)

            _ = appModel.fillVersion(of: .playlist)
            _ = appModel.fillVersion(of: .media)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshFromDocument()
                self.armMutationWatch()
            }
        }
    }

    private func refreshFromDocument() {
        guard var walk else { return }
        guard let playlist = try? appModel.playlist(walk.playlistID),
              MediaAutoAdvance.isEnabled(playlist)
        else { return endWalk() }
        let mediaEntries = playlist.entries.filter { $0.refKind == .media }
        walk.queue.updateEntries(mediaEntries.map(\.id))
        walk.queue.repeatBehavior = AudioPlayer.repeatBehavior(for: playlist.playbackMode)
        walk.queue.setShuffled(playlist.shuffle ?? false)
        walk.delays = Dictionary(uniqueKeysWithValues: mediaEntries.map {
            ($0.id, MediaAutoAdvance.delay(for: $0, in: playlist))
        })
        walk.refs = Dictionary(uniqueKeysWithValues: mediaEntries.map { ($0.id, $0.refId) })
        self.walk = walk
    }
}

private struct MediaPlaylistControllerKey: EnvironmentKey {
    static let defaultValue: MediaPlaylistController? = nil
}

extension EnvironmentValues {
    var mediaPlaylists: MediaPlaylistController? {
        get { self[MediaPlaylistControllerKey.self] }
        set { self[MediaPlaylistControllerKey.self] = newValue }
    }
}
