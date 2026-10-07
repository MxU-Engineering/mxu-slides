import CoreMIDI
import Foundation
import PresenterCore
import SlideScene

final class MIDIInService: @unchecked Sendable {
    static let shared = MIDIInService()

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var ready = false
    private var wanted = Set<Int32>()
    private var connected: [Int32: MIDIEndpointRef] = [:]
    private var handler: (@Sendable (Int32, UInt8, UInt8, UInt8) -> Void)?
    private let lock = NSLock()

    private init() {}

    func setHandler(_ handler: @escaping @Sendable (Int32, UInt8, UInt8, UInt8) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setSources(_ uids: Set<Int32>) {
        lock.lock()
        wanted = uids
        lock.unlock()
        syncConnections()
    }

    private func syncConnections() {
        lock.lock()
        defer { lock.unlock() }

        guard !wanted.isEmpty || ready else { return }
        guard ensureReady() else { return }
        var present: [Int32: MIDIEndpointRef] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            var uid: Int32 = 0
            guard MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uid) == noErr
            else { continue }
            if wanted.contains(uid) { present[uid] = source }
        }
        for (uid, endpoint) in connected where present[uid] != endpoint {
            MIDIPortDisconnectSource(port, endpoint)
            connected[uid] = nil
        }
        for (uid, endpoint) in present where connected[uid] == nil {

            let refCon = UnsafeMutableRawPointer(bitPattern: Int(uid))
            if MIDIPortConnectSource(port, endpoint, refCon) == noErr {
                connected[uid] = endpoint
            }
        }
    }

    private func ensureReady() -> Bool {
        if ready { return true }
        let clientStatus = MIDIClientCreateWithBlock(
            "MxU Slides In" as CFString, &client
        ) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                self?.syncConnections()
            }
        }
        guard clientStatus == noErr,
              MIDIInputPortCreateWithBlock(
                  client, "MxU Slides In Port" as CFString, &port,
                  { [weak self] packetList, refCon in self?.receive(packetList, refCon) }
              ) == noErr
        else { return false }
        ready = true
        return true
    }

    private func receive(_ packetList: UnsafePointer<MIDIPacketList>, _ refCon: UnsafeMutableRawPointer?) {
        lock.lock()
        let handler = handler
        lock.unlock()
        guard let handler else { return }
        let sourceUid = Int32(truncatingIfNeeded: refCon.map { Int(bitPattern: $0) } ?? 0)
        for packet in packetList.unsafeSequence() {
            let length = Int(packet.pointee.length)
            let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(length)) }
            for message in MIDIParse.channelMessages(in: bytes) {
                handler(sourceUid, message.status, message.data1, message.data2)
            }
        }
    }
}

@MainActor
final class MIDIInController {
    private let model: AppModel
    private let controls: ServiceControls
    private let router: ActionRouter

    private let bridge: AppAPIBridge

    init(model: AppModel, controls: ServiceControls, router: ActionRouter, bridge: AppAPIBridge) {
        self.model = model
        self.controls = controls
        self.router = router
        self.bridge = bridge
    }

    private var selectedServiceItemID: String?
    private var selectedMediaPlaylistID: String?
    private var selectedAudioPlaylistID: String?
    private var selectedOverlayFolder: String?
    private var selectedComboFolderID: String?

    func attach() {
        MIDIInService.shared.setHandler { sourceUid, status, data1, data2 in
            Task { @MainActor in
                self.receive(sourceUid: sourceUid, status: status, data1: data1, data2: data2)
            }
        }
        MIDIInService.shared.setSources(MIDIDeviceInventory.shared.items.inputSourceUIDs)
    }

    private func receive(sourceUid: Int32, status: UInt8, data1: UInt8, data2: UInt8) {

        if let device = MIDIDeviceInventory.shared.items.first(where: {
            $0.sourceUID == sourceUid
        }), !device.acceptsChannel(ofStatus: status) {
            return
        }
        guard let (command, velocity) = MIDICommandMapStore.shared.map.resolve(
            status: status, data1: data1, data2: data2
        ) else { return }
        DiagnosticsStore.shared.note("midi.in", detail: "\(command.rawValue) v\(velocity)")
        handle(command, velocity: velocity)
    }

    func handle(_ command: MIDICommand, velocity: Int) {

        let index = velocity - 1
        switch command {
        case .clearAll:
            controls.clearAll()
        case .clearSlides:
            controls.clear(function: .slides)
        case .clearMedia:
            controls.clear(function: .media)
        case .clearOverlays:
            controls.clear(function: .overlays)
        case .clearAudio:
            controls.clear(function: .audio)
        case .clearAlerts:
            controls.clear(function: .alerts)
        case .clearSignage:
            controls.clear(function: .signage)
        case .videoGoToBeginning:
            for row in controls.media.rows { controls.media.resetToStart(row.id) }
        case .videoPlayPause:
            for row in controls.media.rows { controls.media.togglePlayPause(row.id) }
        case .videoPlay:
            for row in controls.media.rows where !row.state.isPlaying {
                controls.media.togglePlayPause(row.id)
            }
        case .videoPause:
            for row in controls.media.rows where row.state.isPlaying {
                controls.media.togglePlayPause(row.id)
            }
        case .nextSlide:
            bridge.advanceIgnoringErrors(steps: 1, settled: false)
        case .previousSlide:
            bridge.advanceIgnoringErrors(steps: -1, settled: false)
        case .nextServiceItem:
            try? bridge.advanceServiceItem(steps: 1)
        case .previousServiceItem:
            try? bridge.advanceServiceItem(steps: -1)
        case .selectService:
            let services = model.entries(in: .services)
            guard services.indices.contains(index) else { return miss(command, "index \(index)") }
            selectedServiceItemID = nil
            try? bridge.selectService(id: services[index].id)
        case .selectServiceItem:
            guard let items = currentServiceItems() else { return miss(command, "no service") }
            guard items.indices.contains(index) else { return miss(command, "index \(index)") }
            let item = items[index]
            if item.itemKind == .media {

                selectedServiceItemID = nil
                guard let media = model.media(item.refId) else { return miss(command, "media missing") }
                controls.fire(mediaItem: media, context: .serviceItem(id: item.id))
                return
            }
            selectedServiceItemID = item.id
        case .triggerSlide:

            if let selection = selectedServiceItem() {
                let slides = SlideSceneBuilder.arrangedSlides(
                    for: selection.presentation, arrangementId: selection.item.arrangementId)
                guard slides.indices.contains(index) else {
                    return miss(command, "index \(index)")
                }
                controls.fire(
                    slide: slides[index], in: selection.presentation,
                    arrangementId: selection.item.arrangementId,
                    contextID: selection.item.id, occurrence: index
                )
                return
            }
            guard let live = controls.state.liveSlide, let presentation = live.presentation
            else { return miss(command, "nothing live or selected") }
            let slides = SlideSceneBuilder.arrangedSlides(
                for: presentation, arrangementId: live.arrangementId)
            guard slides.indices.contains(index) else { return miss(command, "index \(index)") }
            controls.fire(
                slide: slides[index], in: presentation, arrangementId: live.arrangementId,
                contextID: controls.liveContextID, occurrence: index
            )
        case .selectMediaPlaylist:
            let playlists = model.playlists(in: .media)
            guard playlists.indices.contains(index) else { return miss(command, "index \(index)") }
            selectedMediaPlaylistID = playlists[index].id
        case .triggerMedia:
            guard let playlistID = selectedMediaPlaylistID,
                  let playlist = try? model.playlist(playlistID)
            else { return miss(command, "no playlist selected") }
            guard playlist.entries.indices.contains(index) else {
                return miss(command, "index \(index)")
            }
            guard let item = model.media(playlist.entries[index].refId) else {
                return miss(command, "mediaId")
            }
            controls.fire(mediaItem: item)
        case .selectAudioPlaylist:
            let playlists = model.playlists(in: .audio)
            guard playlists.indices.contains(index) else { return miss(command, "index \(index)") }
            selectedAudioPlaylistID = playlists[index].id
        case .triggerAudio:
            guard let playlistID = selectedAudioPlaylistID,
                  let playlist = try? model.playlist(playlistID)
            else { return miss(command, "no playlist selected") }
            guard playlist.entries.indices.contains(index) else {
                return miss(command, "index \(index)")
            }
            controls.fire(playlist: playlist, startAt: playlist.entries[index].id)
        case .toggleOverlay:
            let overlays = overlayEntries()
            guard overlays.indices.contains(index) else { return miss(command, "index \(index)") }
            let id = overlays[index].id
            if controls.state.liveOverlays.contains(where: { $0.id == id }) {
                controls.dismissOverlay(id: id)
            } else if let overlay = model.overlay(id) {
                controls.fire(overlay: overlay)
            } else {
                miss(command, "overlayId")
            }
        case .selectOverlayFolder:
            let folders = model.folders(in: .overlays)
            guard folders.indices.contains(index) else { return miss(command, "index \(index)") }
            selectedOverlayFolder = folders[index]
        case .fireAlert:
            let presets = model.entries(of: .alertPreset)
            guard presets.indices.contains(index) else { return miss(command, "index \(index)") }
            guard let preset = try? model.alertPreset(presets[index].id)
            else { return miss(command, "alertId") }
            controls.fire(alertPreset: preset)
        case .startTimer, .stopTimer, .resetTimer:
            let timers = controls.timers.timers
            guard timers.indices.contains(index) else { return miss(command, "index \(index)") }
            let id = timers[index].id
            switch command {
            case .startTimer: controls.timers.start(id: id)
            case .stopTimer: controls.timers.pause(id: id)
            default: controls.timers.reset(id: id)
            }
        case .selectActionComboFolder:

            let folders = model.comboBoard.orderedFolders
            guard folders.indices.contains(index) else { return miss(command, "index \(index)") }
            selectedComboFolderID = folders[index].id
        case .triggerActionCombo:
            let board = model.comboBoard
            let comboIDs: [String]
            if let folderID = selectedComboFolderID {

                guard let folder = board.folder(id: folderID) else {
                    return miss(command, "folder gone")
                }
                comboIDs = folder.itemIds
            } else {
                comboIDs = board.allItemIDs
            }
            guard comboIDs.indices.contains(index) else { return miss(command, "index \(index)") }
            router.fire(comboID: comboIDs[index])
        }
    }

    private func currentServiceItems() -> [ServiceItem]? {
        guard let serviceID = model.currentServiceID,
              let service = try? model.service(serviceID)
        else { return nil }
        return model.fireableItems(service)
    }

    private func selectedServiceItem() -> (item: ServiceItem, presentation: Presentation)? {
        guard let itemID = selectedServiceItemID,
              let item = currentServiceItems()?.first(where: { $0.id == itemID }),
              item.itemKind == .presentation,

              let presentation = model.presentation(item.refId)
        else { return nil }
        return (item, presentation)
    }

    private func overlayEntries() -> [LibraryIndex.Entry] {
        if let folder = selectedOverlayFolder {
            model.entries(of: .overlay, subkind: folder)
        } else {
            model.entries(of: .overlay)
        }
    }

    private func miss(_ command: MIDICommand, _ detail: String) {
        DiagnosticsStore.shared.note("midi.in.skipped", detail: "\(command.rawValue) \(detail)")
    }
}
