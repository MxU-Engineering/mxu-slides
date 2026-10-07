import Foundation
import MediaEngine
import Observation
import RenderEngine
import SlideScene

@MainActor
@Observable
final class MediaTransportController {

    struct Row: Identifiable, Equatable {
        var candidate: TransportCandidate
        var name: String
        var state: MediaTransportState
        var id: String { candidate.mediaID }

        func tracks(_ other: Row, at date: Date) -> Bool {
            candidate == other.candidate && name == other.name && state.tracks(other.state, at: date)
        }
    }

    private(set) var rows: [Row] = []

    private(set) var rowsVersion = 0

    private(set) var selectedLayer: LayerKind?

    private(set) var pinnedID: String?

    private let appModel: AppModel
    private let render: RenderContext
    private var seeds: [TransportSeed] = []
    private var firedAt: [String: Date] = [:]
    private var poll: Timer?
    private static let layerKey = "transport.selectedLayer"

    init(appModel: AppModel, render: RenderContext) {
        self.appModel = appModel
        self.render = render
        if let raw = UserDefaults.standard.string(forKey: Self.layerKey) {
            selectedLayer = LayerKind(rawValue: raw)
        }
    }

    var viewedLayer: LayerKind {
        selectedLayer ?? TransportTarget.defaultLayer
    }

    var target: Row? {
        let resolved = TransportTarget.resolve(
            candidates: rows.map(\.candidate),
            viewedLayer: viewedLayer,
            pinnedID: pinnedID,
            preferNonLooping: pinnedID == nil
        )
        return resolved.flatMap { candidate in
            rows.first { $0.id == candidate.mediaID }
        }
    }

    var showsTransport: Bool {
        guard let target else { return false }
        return !target.candidate.isLooping || pinnedID == target.id
    }

    func select(layer: LayerKind?) {
        selectedLayer = layer
        pinnedID = nil
        UserDefaults.standard.set(layer?.rawValue, forKey: Self.layerKey)
        pushCountdown(force: true)
    }

    func pin(_ mediaID: String?) {
        pinnedID = mediaID
        if let mediaID, let row = rows.first(where: { $0.id == mediaID }) {
            selectedLayer = row.candidate.layer
        }
        pushCountdown(force: true)
    }

    func togglePlayPause(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        if row.state.isPlaying {
            render.media.pause(id: id)
        } else {
            render.media.resume(id: id)
        }
        refresh()
    }

    func seek(_ id: String, to seconds: Double, final: Bool) {
        render.media.seek(id: id, to: seconds, precise: final)
        refresh()
    }

    func resetToStart(_ id: String) {
        render.media.seek(id: id, to: 0, precise: true)
        refresh()
    }

    static func isFinished(_ state: MediaTransportState, at date: Date) -> Bool {
        !state.isPlaying && !state.isLooping && state.duration > 0
            && state.position(at: date) >= state.duration - 0.05
    }

    func refresh(seeds newSeeds: [TransportSeed]? = nil) {
        if let newSeeds { seeds = newSeeds }
        let now = Date()
        let states = render.media.transportStates()
        var next: [Row] = []
        for seed in seeds {
            guard let state = states[seed.mediaID], state.duration > 0 else { continue }
            let fired = firedAt[seed.mediaID] ?? Date()
            firedAt[seed.mediaID] = fired
            next.append(Row(
                candidate: TransportCandidate(
                    mediaID: seed.mediaID, layer: seed.layer, origin: seed.origin,
                    isLooping: state.isLooping, firedAt: fired
                ),
                name: appModel.entry(seed.mediaID)?.name ?? "Video",
                state: state
            ))
        }
        let liveIDs = Set(next.map(\.id))
        firedAt = firedAt.filter { liveIDs.contains($0.key) }

        if let pinnedID, !liveIDs.contains(pinnedID) {
            self.pinnedID = nil
        }
        let moved = !rows.elementsEqual(next) { $0.tracks($1, at: now) }
        if moved { rows = next }
        updatePoll()
        let countdownsMoved = pushCountdown()
        if moved || countdownsMoved { rowsVersion += 1 }
    }

    private func updatePoll() {
        if rows.isEmpty {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        }
    }

    @discardableResult
    private func pushCountdown(force: Bool = false) -> Bool {
        let now = Date()
        var wanted: [String: VideoCountdown] = [:]
        for layer in Set(rows.map(\.candidate.layer)) {
            guard let target = TransportTarget.countdownTarget(
                candidates: rows.map(\.candidate), layer: layer
            ).flatMap({ candidate in rows.first { $0.id == candidate.mediaID } })
            else { continue }
            wanted[layer.rawValue] = VideoCountdown(
                name: target.name,
                duration: target.state.duration,
                position: target.state.position(at: now),
                anchoredAt: now,
                isPlaying: target.state.isPlaying
            )
        }
        var info = render.confidenceInfo
        let current = info.videoCountdowns

        let tracking = Set(wanted.keys) == Set(current.keys)
            && wanted.allSatisfy { key, next in
                current[key].map { held in
                    next.name == held.name
                        && next.duration == held.duration
                        && next.isPlaying == held.isPlaying
                        && abs(held.remaining(at: now) - next.remaining(at: now)) < MediaTransportState.playingTolerance
                } ?? false
            }
        let writes = force || !tracking
        if writes {
            info.videoCountdowns = wanted
            info.videoCountdown = wanted[TransportTarget.defaultLayer.rawValue]
            render.confidenceInfo = info
        }
        return writes
    }
}
