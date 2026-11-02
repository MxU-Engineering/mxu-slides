import Foundation
import LocalAPI
import MediaEngine
import Observation
import PresenterCore
import RenderEngine
import SlideScene

@MainActor
@Observable
final class MediaTransportController {

    struct Row: Identifiable, Equatable {
        var candidate: TransportCandidate
        var name: String
        var state: MediaTransportState

        var marks: [VideoMarks.Point] = []
        var id: String { candidate.mediaID }

        func tracks(_ other: Row, at date: Date) -> Bool {
            candidate == other.candidate && name == other.name && marks == other.marks
                && state.tracks(other.state, at: date)
        }
    }

    private(set) var rows: [Row] = []

    private(set) var rowsVersion = 0

    private(set) var selectedLayer: String?

    private(set) var pinnedID: String?

    private(set) var layerStack: [RenderLayer] = ShowState().layerStackTopFirst

    private let appModel: AppModel
    private let render: RenderContext
    private var seeds: [TransportSeed] = []
    private var firedAt: [String: Date] = [:]
    private var poll: Timer?
    private static let layerKey = "transport.selectedLayer"

    init(appModel: AppModel, render: RenderContext) {
        self.appModel = appModel
        self.render = render
        selectedLayer = UserDefaults.standard.string(forKey: Self.layerKey)
    }

    var viewedLayer: String {
        guard let selectedLayer, layerStack.contains(where: { $0.id == selectedLayer }) else {
            return TransportTarget.defaultLayer
        }
        return selectedLayer
    }

    func layerName(_ id: String) -> String {
        layerStack.first { $0.id == id }?.name ?? LayerKind(rawValue: id)?.displayName ?? id
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

    func select(layer: String?) {
        selectedLayer = layer
        pinnedID = nil
        UserDefaults.standard.set(layer, forKey: Self.layerKey)
        pushCountdown(force: true)
    }

    func pin(_ mediaID: String?) {
        pinnedID = mediaID
        if let mediaID, let row = rows.first(where: { $0.id == mediaID }) {
            selectedLayer = row.candidate.layerID
        }
        pushCountdown(force: true)
    }

    func togglePlayPause(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }

        APIFireFeed.shared.publish(APIFireEvent(
            kind: .mediaTransport, id: id, mediaTransport: APIMediaTransportCommand(action: row.state.isPlaying ? "pause" : "resume")))
        if row.state.isPlaying {
            render.media.pause(id: id)
        } else {
            render.media.resume(id: id)
        }
        refresh()
    }

    func seek(_ id: String, to seconds: Double, final: Bool) {
        if final {
            APIFireFeed.shared.publish(APIFireEvent(kind: .mediaTransport, id: id, mediaTransport: APIMediaTransportCommand(action: "seek", position: seconds)))
        }
        render.media.seek(id: id, to: seconds, precise: final)
        refresh()
    }

    func resetToStart(_ id: String) {
        APIFireFeed.shared.publish(APIFireEvent(kind: .mediaTransport, id: id, mediaTransport: APIMediaTransportCommand(action: "reset")))
        render.media.seek(id: id, to: 0, precise: true)
        refresh()
    }

    static func isFinished(_ state: MediaTransportState, at date: Date) -> Bool {
        !state.isPlaying && !state.isLooping && state.duration > 0
            && state.position(at: date) >= state.duration - 0.05
    }

    func refresh(seeds newSeeds: [TransportSeed]? = nil, layers: [RenderLayer]? = nil) {
        if let newSeeds { seeds = newSeeds }
        if let layers, layers != layerStack { layerStack = layers }
        let now = Date()
        let states = render.media.transportStates()
        var next: [Row] = []
        for seed in seeds {
            guard let state = states[seed.mediaID], state.duration > 0 else { continue }
            let fired = firedAt[seed.mediaID] ?? Date()
            firedAt[seed.mediaID] = fired
            next.append(Row(
                candidate: TransportCandidate(
                    mediaID: seed.mediaID, layerID: seed.layerID, origin: seed.origin,
                    isLooping: state.isLooping, firedAt: fired
                ),
                name: appModel.entry(seed.mediaID)?.name ?? "Video",
                state: state,
                marks: appModel.media(seed.mediaID).map {
                    VideoMarks.points($0.marks, inPoint: $0.inPoint, length: state.duration)
                } ?? []
            ))
        }
        let liveIDs = Set(next.map(\.id))
        firedAt = firedAt.filter { liveIDs.contains($0.key) }

        if let pinnedID, !liveIDs.contains(pinnedID) {
            self.pinnedID = nil
        }
        let moved = !rows.elementsEqual(next) { $0.tracks($1, at: now) }
        if moved { rows = next }
        fireVideoActions(states, at: now)
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
        for layer in Set(rows.map(\.candidate.layerID)) {
            guard let target = TransportTarget.countdownTarget(
                candidates: rows.map(\.candidate), layer: layer
            ).flatMap({ candidate in rows.first { $0.id == candidate.mediaID } })
            else { continue }
            let item = appModel.media(target.id)
            wanted[layer] = VideoCountdown(
                name: target.name,
                duration: target.state.duration,
                position: target.state.position(at: now),
                anchoredAt: now,
                isPlaying: target.state.isPlaying,
                marks: VideoMarks.points(item?.marks, inPoint: item?.inPoint, length: target.state.duration)
            )
        }
        var info = render.confidenceInfo
        let current = info.videoCountdowns

        let tracking = Set(wanted.keys) == Set(current.keys)
            && wanted.allSatisfy { key, next in
                current[key].map { held in
                    next.name == held.name
                        && next.marks == held.marks
                        && next.duration == held.duration
                        && next.isPlaying == held.isPlaying
                        && abs(held.remaining(at: now) - next.remaining(at: now)) < MediaTransportState.playingTolerance
                } ?? false
            }
        let writes = force || !tracking
        if writes {
            info.videoCountdowns = wanted
            info.videoCountdown = wanted[TransportTarget.defaultLayer]
            render.confidenceInfo = info
        }
        return writes
    }

    var runVideoActions: (([SlideAction]) -> Void)?

    private var markReads: [String: (position: Double, at: Date)] = [:]

    private var markTimer: Timer?

    private func fireVideoActions(_ states: [String: MediaTransportState], at now: Date) {
        var reads: [String: (position: Double, at: Date)] = [:]
        var due: [[SlideAction]] = []
        var wait: TimeInterval?
        for seed in seeds {
            guard let state = states[seed.mediaID], state.duration > 0 else { continue }
            let last = markReads[seed.mediaID]
            let position = state.position(at: now)
            guard last != nil || state.isPlaying else { continue }
            reads[seed.mediaID] = (position, now)
            let item = appModel.media(seed.mediaID)
            let points = VideoMarks.points(item?.marks, inPoint: item?.inPoint, length: state.duration)
            guard !points.isEmpty else { continue }
            let crossed = VideoMarks.crossed(
                points, from: last?.position, to: position, elapsed: last.map { now.timeIntervalSince($0.at) } ?? 0,
                rate: state.rate, length: state.duration, looping: state.isLooping)
            for point in crossed {
                DiagnosticsStore.shared.note(
                    "video.mark", detail: "\(seed.mediaID) \(point.name) at \(String(format: "%.3f", point.at)) read \(String(format: "%.3f", position))")
                if let actions = item?.marks?.first(where: { $0.id == point.id })?.actions, !actions.isEmpty {
                    due.append(actions)
                }
            }
            if state.isPlaying, state.rate > 0,
               let ahead = VideoMarks.untilNext(points, after: position, length: state.duration, looping: state.isLooping) {
                wait = min(wait ?? .infinity, ahead / state.rate)
            }
        }
        markReads = reads
        markTimer?.invalidate()
        markTimer = nil
        guard let wait else {
            for actions in due { runVideoActions?(actions) }
            return
        }
        let timer = Timer(timeInterval: wait + 0.002, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        markTimer = timer

        for actions in due { runVideoActions?(actions) }
    }
}
