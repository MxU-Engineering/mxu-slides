import Foundation
import MediaEngine
import Observation
import PresenterCore
import SlideScene
import SwiftUI

@MainActor
@Observable
final class SignageController {

    static let stillDwellSeconds: Double = 8

    private struct SignageItem {
        var mediaID: String
        var isVideo: Bool
        var duration: Double

        var extraDelay: Double = 0
    }

    private struct ChannelLoop {
        var playlistID: String
        var items: [SignageItem]
        var index: Int
        var startedAt: Date
        var engineID: String
    }

    static let screenSourcesKey = "signage.screenSources"

    private(set) var screenAssignments: [UUID: String] = [:]
    private var loops: [String: ChannelLoop] = [:]
    private var advanceTask: Task<Void, Never>?

    private let appModel: AppModel
    private let render: RenderContext

    init(appModel: AppModel, render: RenderContext) {
        self.appModel = appModel
        self.render = render
        restoreScreenSources()
        rebuild()
        armMutationWatch()
    }

    var screens: [(id: UUID, name: String)] {
        render.outputs.placeholderScreens.map { ($0.id, $0.name) }
    }

    var channels: [SignageChannel] {
        appModel.signageBoard.signages
    }

    var playlistChoices: [(id: String, name: String)] {
        appModel.entries(of: .playlist, subkind: PlaylistKind.media.rawValue).map { ($0.id, $0.name) }
    }

    func playlistName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return appModel.indexEntry(id)?.name
    }

    func channel(_ id: String) -> SignageChannel? {
        channels.first { $0.id == id }
    }

    var isAnyScreenLive: Bool {
        screenAssignments.values.contains { loops[$0] != nil }
    }

    func screenNames(showing channelID: String) -> [String] {
        let showing = screenAssignments.filter { $0.value == channelID }.map(\.key)
        return render.outputs.placeholderScreens
            .filter { showing.contains($0.id) }
            .map(\.name)
    }

    func setSource(_ channelID: String?, forScreen screenID: UUID) {
        let resolved = (channelID?.isEmpty ?? true) ? nil : channelID
        if let resolved, channel(resolved) == nil {
            return DiagnosticsStore.shared.note("signage.channel.missing", detail: resolved)
        }
        if let resolved {
            screenAssignments[screenID] = resolved
        } else {
            screenAssignments.removeValue(forKey: screenID)
        }
        persistScreenSources()
        DiagnosticsStore.shared.note(
            "signage.screen", detail: "\(screenID) → \(resolved ?? "program")")
        rebuild()
    }

    var hasAnyChannelContent: Bool {
        channels.contains { !($0.playlistId?.isEmpty ?? true) }
    }

    func clearAllChannels() {
        guard hasAnyChannelContent else { return }
        appModel.updateSignageBoard { board in
            for index in board.signages.indices {
                board.signages[index].playlistId = nil
            }
        }
        DiagnosticsStore.shared.note("signage.clear", detail: "all channels dark")
        rebuild()
    }

    func assign(playlistID: String?, toSignage channelID: String) {
        let resolved = (playlistID?.isEmpty ?? true) ? nil : playlistID
        guard channel(channelID) != nil else {
            return DiagnosticsStore.shared.note("signage.channel.missing", detail: channelID)
        }
        if let resolved, (try? appModel.playlist(resolved)) == nil {
            return DiagnosticsStore.shared.note("signage.playlist.missing", detail: resolved)
        }
        appModel.updateSignageBoard { board in
            guard let index = board.signages.firstIndex(where: { $0.id == channelID })
            else { return }
            board.signages[index].playlistId = resolved
        }
        DiagnosticsStore.shared.note(
            "signage.assign", detail: "\(channelID) ← \(resolved ?? "dark")")
        rebuild()
    }

    @discardableResult
    func addChannel(named name: String? = nil) -> String {
        let id = UUID().uuidString
        appModel.updateSignageBoard { board in
            let fallback = "Signage \(board.signages.count + 1)"
            board.signages.append(SignageChannel(id: id, name: name ?? fallback))
        }
        return id
    }

    func renameChannel(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appModel.updateSignageBoard { board in
            guard let index = board.signages.firstIndex(where: { $0.id == id }) else { return }
            board.signages[index].name = trimmed
        }
    }

    func removeChannel(_ id: String) {
        appModel.updateSignageBoard { board in
            board.signages.removeAll { $0.id == id }
        }
        rebuild()
    }

    private func rebuild() {
        let wantedChannels = Set(screenAssignments.values)
        var wanted: [String: String] = [:]  
        for channelID in wantedChannels {
            if let playlistID = channel(channelID)?.playlistId, !playlistID.isEmpty {
                wanted[channelID] = playlistID
            }
        }
        for (channelID, loop) in loops where wanted[channelID] != loop.playlistID {
            stopLoop(loop)
            loops.removeValue(forKey: channelID)
        }
        for (channelID, playlistID) in wanted {
            if let existing = loops[channelID], existing.playlistID == playlistID {

                if let items = resolveItems(playlistID: playlistID) {
                    loops[channelID]?.items = items
                }
                continue
            }
            guard let items = resolveItems(playlistID: playlistID), !items.isEmpty else {
                DiagnosticsStore.shared.note("signage.playlist.empty", detail: playlistID)
                continue
            }
            var loop = ChannelLoop(
                playlistID: playlistID, items: items, index: 0,
                startedAt: Date(), engineID: ""
            )
            startItem(at: 0, of: &loop, channelID: channelID)
            loops[channelID] = loop
        }
        publish()
        syncAdvanceTask()
    }

    private func resolveItems(playlistID: String) -> [SignageItem]? {
        guard let playlist = try? appModel.playlist(playlistID) else { return nil }
        return playlist.entries.compactMap { entry in
            guard entry.refKind == .media,
                  let item = appModel.media(entry.refId)
            else { return nil }
            let isVideo = item.mediaKind == .video

            let override = entry.autoAdvanceDelaySeconds ?? playlist.autoAdvanceDelaySeconds
            return SignageItem(
                mediaID: item.id,
                isVideo: isVideo,
                duration: isVideo
                    ? (item.durationSeconds ?? Self.stillDwellSeconds)
                    : max(override ?? Self.stillDwellSeconds,
                          MediaAutoAdvance.minimumStillDwellSeconds),
                extraDelay: isVideo ? max(override ?? 0, 0) : 0
            )
        }
    }

    private func startItem(at index: Int, of loop: inout ChannelLoop, channelID: String) {
        let item = loop.items[index]
        let engineID = "signage::\(channelID)::\(index)"
        let previous = loop.engineID
        loop.index = index
        loop.startedAt = Date()
        loop.engineID = engineID
        let loopInEngine = loop.items.count == 1
        guard let blobs = appModel.blobs,
              let media = appModel.media(item.mediaID),
              let url = blobs.url(forHash: media.fileHash)
        else {
            DiagnosticsStore.shared.note("signage.media.missing", detail: item.mediaID)
            return
        }
        let render = render
        Task { @MainActor [weak self] in
            if item.isVideo {
                if let prepared = try? await render.media.prepare(url: url) {
                    let options = PlaybackOptions(
                        inPoint: media.inPoint, outPoint: media.outPoint,
                        rate: media.playRate
                    )
                    render.media.play(prepared, id: engineID, loop: loopInEngine, options: options)

                    self?.loops[channelID]?.items[index].duration = options.effectiveWallClockDuration(
                        duration: prepared.duration, frameDuration: prepared.frameDuration
                    )
                }
            } else {
                _ = try? await render.media.showStill(url: url, id: engineID)
            }
            if !previous.isEmpty, previous != engineID {
                render.media.stop(id: previous)
            }
            self?.publish()
        }
    }

    private func stopLoop(_ loop: ChannelLoop) {
        if !loop.engineID.isEmpty {
            render.media.stop(id: loop.engineID)
        }
    }

    private func publish() {
        var frames: [UUID: SignageFrame] = [:]
        for (screenID, channelID) in screenAssignments {
            guard let loop = loops[channelID], !loop.engineID.isEmpty else { continue }
            let screen = render.outputs.placeholderScreens.first { $0.id == screenID }
            frames[screenID] = SignageFrame(
                engineID: loop.engineID,
                canvasSize: screen.map { CGSize(width: $0.width, height: $0.height) }
                    ?? CGSize(width: 1920, height: 1080)
            )
        }
        render.signageBox.value = frames
    }

    private func syncAdvanceTask() {
        let needsTicks = loops.values.contains { $0.items.count > 1 }
        if !needsTicks {
            advanceTask?.cancel()
            advanceTask = nil
            return
        }
        guard advanceTask == nil else { return }
        advanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.advanceDueLoops()
            }
        }
    }

    private func advanceDueLoops() {
        let now = Date()
        for (channelID, loop) in loops {
            guard loop.items.count > 1, loop.items.indices.contains(loop.index) else { continue }
            let item = loop.items[loop.index]
            let due = loop.startedAt.addingTimeInterval(item.duration + item.extraDelay)
            guard now >= due else { continue }
            var updated = loop
            startItem(at: (loop.index + 1) % loop.items.count, of: &updated, channelID: channelID)
            loops[channelID] = updated
        }
        syncAdvanceTask()
    }

    private func restoreScreenSources() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.screenSourcesKey)
            as? [String: String]
        else { return }
        for (key, channelID) in stored {
            guard let screenID = UUID(uuidString: key) else { continue }
            screenAssignments[screenID] = channelID
        }
    }

    private func persistScreenSources() {
        let stored = Dictionary(
            uniqueKeysWithValues: screenAssignments.map { ($0.key.uuidString, $0.value) }
        )
        UserDefaults.standard.set(stored, forKey: Self.screenSourcesKey)
    }

    private func armMutationWatch() {
        withObservationTracking {

            _ = appModel.version(of: .signageBoard)
            _ = appModel.version(of: .playlist)
            _ = appModel.version(of: .media)
            _ = appModel.version(of: .audio)

            _ = appModel.fillVersion(of: .signageBoard)
            _ = appModel.fillVersion(of: .playlist)
            _ = appModel.fillVersion(of: .media)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rebuild()
                self.armMutationWatch()
            }
        }
    }
}

private struct SignageControllerKey: EnvironmentKey {
    static let defaultValue: SignageController? = nil
}

extension EnvironmentValues {
    var signage: SignageController? {
        get { self[SignageControllerKey.self] }
        set { self[SignageControllerKey.self] = newValue }
    }
}
