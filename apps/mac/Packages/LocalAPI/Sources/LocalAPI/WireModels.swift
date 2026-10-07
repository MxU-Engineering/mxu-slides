import Foundation

public struct APIError: Error, Codable, Sendable {
    public var status: Int
    public var code: String
    public var message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public static func badRequest(_ message: String) -> APIError {
        APIError(status: 400, code: "bad_request", message: message)
    }

    public static func notFound(_ message: String) -> APIError {
        APIError(status: 404, code: "not_found", message: message)
    }

    public static func unauthorized(_ message: String = "Missing or invalid token.") -> APIError {
        APIError(status: 401, code: "unauthorized", message: message)
    }

    public static func forbidden(_ required: APIScope) -> APIError {
        APIError(
            status: 403, code: "insufficient_scope",
            message: "This endpoint requires the \(required.rawValue) scope."
        )
    }
}

public enum APIDocumentKind: String, Codable, CaseIterable, Sendable {
    case presentations, services, themes, media, audio, playlists, overlays
    case alertPresets = "alert-presets"
    case outputPresets = "output-presets"
    case streamPresets = "stream-presets"
    case actionCombos = "action-combos"
    case scheduleTriggers = "schedule-triggers"
    case confidenceLayouts = "confidence-layouts"
}

public struct APILibraryEntry: Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var folder: String?
    public var updatedAt: Date?

    public init(id: String, name: String, kind: String, folder: String?, updatedAt: Date?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.folder = folder
        self.updatedAt = updatedAt
    }
}

public struct APILibrarySummary: Codable, Sendable {
    public var counts: [String: Int]

    public init(counts: [String: Int]) {
        self.counts = counts
    }
}

public struct APICreatedResponse: Codable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct APIOKResponse: Codable, Sendable {
    public var ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}

public struct APIShowStatus: Codable, Sendable {
    public struct LiveSlide: Codable, Sendable {
        public var presentationId: String
        public var presentationName: String?
        public var slideId: String
        public var slideIndex: Int?
        public var slideName: String?
        public var serviceItemId: String?
        public var occurrence: Int?

        public var stepIndex: Int?

        public var stepCount: Int?

        public var text: String?

        public var slideCount: Int?

        public init(
            presentationId: String, presentationName: String?, slideId: String,
            slideIndex: Int?, slideName: String?, serviceItemId: String?, occurrence: Int?,
            stepIndex: Int? = nil, stepCount: Int? = nil,
            text: String? = nil, slideCount: Int? = nil
        ) {
            self.presentationId = presentationId
            self.presentationName = presentationName
            self.slideId = slideId
            self.slideIndex = slideIndex
            self.slideName = slideName
            self.serviceItemId = serviceItemId
            self.occurrence = occurrence
            self.stepIndex = stepIndex
            self.stepCount = stepCount
            self.text = text
            self.slideCount = slideCount
        }
    }

    public struct ServiceRef: Codable, Sendable, Equatable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct NextSlide: Codable, Sendable, Equatable {
        public var text: String?
        public var presentationId: String?
        public var slideId: String?
        public var slideIndex: Int?

        public init(text: String?, presentationId: String? = nil, slideId: String? = nil, slideIndex: Int? = nil) {
            self.text = text
            self.presentationId = presentationId
            self.slideId = slideId
            self.slideIndex = slideIndex
        }
    }

    public struct Position: Codable, Sendable, Equatable {
        public var currentItemName: String?
        public var nextItemName: String?

        public init(currentItemName: String?, nextItemName: String?) {
            self.currentItemName = currentItemName
            self.nextItemName = nextItemName
        }
    }

    public struct Overlay: Codable, Sendable {
        public var id: String
        public var name: String
        public var layer: String?

        public init(id: String, name: String, layer: String?) {
            self.id = id
            self.name = name
            self.layer = layer
        }
    }

    public struct Alert: Codable, Sendable {
        public var id: String
        public var message: String
        public var behavior: String
        public var target: String
        public var layer: String?

        public init(id: String, message: String, behavior: String, target: String, layer: String?) {
            self.id = id
            self.message = message
            self.behavior = behavior
            self.target = target
            self.layer = layer
        }
    }

    public struct LayerContent: Codable, Sendable {
        public var mediaId: String
        public var mediaName: String?
        public var loops: Bool?

        public init(mediaId: String, mediaName: String?, loops: Bool?) {
            self.mediaId = mediaId
            self.mediaName = mediaName
            self.loops = loops
        }
    }

    public var liveSlide: LiveSlide?
    public var nextSlideText: String?

    public var mediaLayers: [String: LayerContent]
    public var overlays: [Overlay]
    public var alert: Alert?
    public var currentServiceId: String?
    public var service: ServiceRef?
    public var nextSlide: NextSlide?
    public var position: Position?

    public init(
        liveSlide: LiveSlide?, nextSlideText: String?,
        mediaLayers: [String: LayerContent], overlays: [Overlay],
        alert: Alert?, currentServiceId: String?,
        service: ServiceRef? = nil, nextSlide: NextSlide? = nil, position: Position? = nil
    ) {
        self.liveSlide = liveSlide
        self.nextSlideText = nextSlideText
        self.mediaLayers = mediaLayers
        self.overlays = overlays
        self.alert = alert
        self.currentServiceId = currentServiceId
        self.service = service
        self.nextSlide = nextSlide
        self.position = position
    }
}

public struct APISchedulerStatus: Codable, Sendable {

    public var enabled: Bool
    public var nextFire: APISchedulerUpcoming?
    public var triggers: [APISchedulerTriggerStatus]

    public init(
        enabled: Bool, nextFire: APISchedulerUpcoming?, triggers: [APISchedulerTriggerStatus]
    ) {
        self.enabled = enabled
        self.nextFire = nextFire
        self.triggers = triggers
    }
}

public struct APISchedulerUpcoming: Codable, Sendable {
    public var triggerId: String
    public var name: String
    public var at: Date

    public init(triggerId: String, name: String, at: Date) {
        self.triggerId = triggerId
        self.name = name
        self.at = at
    }
}

public struct APISchedulerTriggerStatus: Codable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var folderEnabled: Bool
    public var folderId: String?
    public var folderName: String?
    public var nextFire: Date?
    public var lastFired: Date?

    public var archived: Bool?

    public init(
        id: String, name: String, enabled: Bool, folderEnabled: Bool,
        folderId: String?, folderName: String?, nextFire: Date?, lastFired: Date?,
        archived: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.folderEnabled = folderEnabled
        self.folderId = folderId
        self.folderName = folderName
        self.nextFire = nextFire
        self.lastFired = lastFired
        self.archived = archived
    }
}

public struct APISchedulerEnableCommand: Codable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct APITimerStatus: Codable, Sendable {
    public struct Warning: Codable, Sendable, Equatable {
        public var remainingSeconds: Double
        public var colorHex: String

        public init(remainingSeconds: Double, colorHex: String) {
            self.remainingSeconds = remainingSeconds
            self.colorHex = colorHex
        }
    }

    public var id: String
    public var name: String
    public var mode: String
    public var running: Bool
    public var displaySeconds: Int
    public var overrun: Bool
    public var folderId: String?
    public var folderName: String?

    public var runningSince: Date?
    public var bankedSeconds: Double?
    public var durationSeconds: Double?
    public var targetTime: Date?
    public var armedAt: Date?
    public var warnings: [Warning]?

    public init(
        id: String, name: String, mode: String, running: Bool,
        displaySeconds: Int, overrun: Bool, folderId: String?, folderName: String?,
        runningSince: Date? = nil, bankedSeconds: Double? = nil, durationSeconds: Double? = nil,
        targetTime: Date? = nil, armedAt: Date? = nil, warnings: [Warning]? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.running = running
        self.displaySeconds = displaySeconds
        self.overrun = overrun
        self.folderId = folderId
        self.folderName = folderName
        self.runningSince = runningSince
        self.bankedSeconds = bankedSeconds
        self.durationSeconds = durationSeconds
        self.targetTime = targetTime
        self.armedAt = armedAt
        self.warnings = warnings
    }
}

public struct APIVideoCountdown: Codable, Sendable, Equatable {
    public var layer: String
    public var name: String
    public var duration: Double
    public var position: Double
    public var anchoredAt: Date
    public var isPlaying: Bool

    public var serviceItemId: String?

    public init(
        layer: String, name: String, duration: Double, position: Double, anchoredAt: Date, isPlaying: Bool,
        serviceItemId: String? = nil
    ) {
        self.layer = layer
        self.name = name
        self.duration = duration
        self.position = position
        self.anchoredAt = anchoredAt
        self.isPlaying = isPlaying
        self.serviceItemId = serviceItemId
    }
}

public struct APITimersDocument: Codable, Sendable {
    public var timers: [APITimerStatus]
    public var videoCountdowns: [APIVideoCountdown]

    public init(timers: [APITimerStatus], videoCountdowns: [APIVideoCountdown]) {
        self.timers = timers
        self.videoCountdowns = videoCountdowns
    }
}

public struct APIServiceSnapshot: Codable, Sendable, Equatable {
    public struct Size: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct SlideRef: Codable, Sendable, Equatable {
        public var id: String
        public var index: Int
        public var label: String?
        public var group: String?
        public var groupColorHex: String?
        public var text: String?
        public var thumbnailChecksum: String?
        public var size: Size

        public init(
            id: String, index: Int, label: String?, group: String?, groupColorHex: String?,
            text: String?, thumbnailChecksum: String?, size: Size
        ) {
            self.id = id
            self.index = index
            self.label = label
            self.group = group
            self.groupColorHex = groupColorHex
            self.text = text
            self.thumbnailChecksum = thumbnailChecksum
            self.size = size
        }
    }

    public struct PresentationRef: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var arrangementId: String?
        public var arrangementName: String?
        public var slides: [SlideRef]

        public init(id: String, name: String, arrangementId: String?, arrangementName: String?, slides: [SlideRef]) {
            self.id = id
            self.name = name
            self.arrangementId = arrangementId
            self.arrangementName = arrangementName
            self.slides = slides
        }
    }

    public struct MediaRef: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var durationSeconds: Int?
        public var thumbnailChecksum: String?

        public init(id: String, name: String, durationSeconds: Int?, thumbnailChecksum: String?) {
            self.id = id
            self.name = name
            self.durationSeconds = durationSeconds
            self.thumbnailChecksum = thumbnailChecksum
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var kind: String
        public var colorHex: String?
        public var presentation: PresentationRef?
        public var media: MediaRef?

        public init(
            id: String, name: String, kind: String, colorHex: String?,
            presentation: PresentationRef? = nil, media: MediaRef? = nil
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.colorHex = colorHex
            self.presentation = presentation
            self.media = media
        }
    }

    public var service: APIShowStatus.ServiceRef
    public var items: [Item]

    public init(service: APIShowStatus.ServiceRef, items: [Item]) {
        self.service = service
        self.items = items
    }
}

public enum APIJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public struct APIVideoInputStatus: Codable, Sendable {
    public var id: String
    public var name: String

    public var kind: String?
    public var sourceId: String?

    public var audioInputId: String?

    public var delayFrames: Int?

    public init(
        id: String, name: String, kind: String? = nil,
        sourceId: String? = nil, audioInputId: String? = nil,
        delayFrames: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sourceId = sourceId
        self.audioInputId = audioInputId
        self.delayFrames = delayFrames
    }
}

public struct APIAudioInputStatus: Codable, Sendable {
    public var id: String
    public var name: String

    public var deviceUid: String?

    public var live: Bool

    public var enabled: Bool
    public var gain: Double
    public var muted: Bool

    public var mixId: String?

    public var delayMs: Int?

    public init(
        id: String, name: String, deviceUid: String? = nil,
        live: Bool, enabled: Bool, gain: Double, muted: Bool,
        mixId: String? = nil, delayMs: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.deviceUid = deviceUid
        self.live = live
        self.enabled = enabled
        self.gain = gain
        self.muted = muted
        self.mixId = mixId
        self.delayMs = delayMs
    }
}

public struct APIAudioMixStatus: Codable, Sendable {
    public var id: String
    public var name: String

    public var deviceUid: String?
    public var channelOffset: Int
    public var gain: Double
    public var muted: Bool

    public var outputIds: [String]?

    public init(
        id: String, name: String, deviceUid: String? = nil,
        channelOffset: Int, gain: Double, muted: Bool,
        outputIds: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.deviceUid = deviceUid
        self.channelOffset = channelOffset
        self.gain = gain
        self.muted = muted
        self.outputIds = outputIds
    }
}

public struct APIMixerInputCommand: Codable, Sendable {
    public var enabled: Bool?
    public var gain: Double?
    public var muted: Bool?

    public var delayMs: Int?

    public init(
        enabled: Bool? = nil, gain: Double? = nil, muted: Bool? = nil,
        delayMs: Int? = nil
    ) {
        self.enabled = enabled
        self.gain = gain
        self.muted = muted
        self.delayMs = delayMs
    }
}

public struct APIAudioStatus: Codable, Sendable {
    public struct Bus: Codable, Sendable {
        public var playlistId: String?
        public var audioItemId: String?
        public var trackName: String?
        public var playing: Bool
        public var position: Double?
        public var duration: Double?

        public init(
            playlistId: String?, audioItemId: String?, trackName: String?,
            playing: Bool, position: Double?, duration: Double?
        ) {
            self.playlistId = playlistId
            self.audioItemId = audioItemId
            self.trackName = trackName
            self.playing = playing
            self.position = position
            self.duration = duration
        }
    }

    public var buses: [Bus]

    public init(buses: [Bus]) {
        self.buses = buses
    }
}

public struct APITransportRow: Codable, Sendable {
    public var mediaId: String
    public var name: String
    public var layer: String
    public var playing: Bool
    public var looping: Bool
    public var position: Double
    public var duration: Double

    public init(
        mediaId: String, name: String, layer: String, playing: Bool,
        looping: Bool, position: Double, duration: Double
    ) {
        self.mediaId = mediaId
        self.name = name
        self.layer = layer
        self.playing = playing
        self.looping = looping
        self.position = position
        self.duration = duration
    }
}

public struct APIOutputsStatus: Codable, Sendable {

    public struct Output: Codable, Sendable {
        public var id: String
        public var name: String?

        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public var backing: String

        public var adjusted: Bool

        public init(
            id: String, name: String?, x: Double, y: Double,
            width: Double, height: Double, backing: String, adjusted: Bool
        ) {
            self.id = id
            self.name = name
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.backing = backing
            self.adjusted = adjusted
        }
    }

    public struct Screen: Codable, Sendable {
        public var id: String
        public var name: String
        public var role: String
        public var backed: Bool
        public var width: Int
        public var height: Int
        public var outputs: [Output]

        public var activeMasks: [String]

        public init(
            id: String, name: String, role: String, backed: Bool,
            width: Int, height: Int, outputs: [Output], activeMasks: [String]
        ) {
            self.id = id
            self.name = name
            self.role = role
            self.backed = backed
            self.width = width
            self.height = height
            self.outputs = outputs
            self.activeMasks = activeMasks
        }
    }

    public struct Preset: Codable, Sendable {
        public var id: String
        public var name: String
        public var active: Bool

        public init(id: String, name: String, active: Bool) {
            self.id = id
            self.name = name
            self.active = active
        }
    }

    public var screens: [Screen]
    public var presets: [Preset]

    public init(screens: [Screen], presets: [Preset]) {
        self.screens = screens
        self.presets = presets
    }
}

public struct APIFireSlideCommand: Codable, Sendable {
    public var presentationId: String?
    public var slideId: String?
    public var slideIndex: Int?
    public var arrangementId: String?

    public var serviceItemId: String?
    public var occurrence: Int?

    public init(
        presentationId: String? = nil, slideId: String? = nil, slideIndex: Int? = nil,
        arrangementId: String? = nil, serviceItemId: String? = nil, occurrence: Int? = nil
    ) {
        self.presentationId = presentationId
        self.slideId = slideId
        self.slideIndex = slideIndex
        self.arrangementId = arrangementId
        self.serviceItemId = serviceItemId
        self.occurrence = occurrence
    }
}

public struct APIAdvanceCommand: Codable, Sendable {

    public var steps: Int?

    public var settled: Bool?

    public init(steps: Int? = nil, settled: Bool? = nil) {
        self.steps = steps
        self.settled = settled
    }
}

public struct APIClearCommand: Codable, Sendable {

    public var function: String?
    public var layer: String?

    public init(function: String? = nil, layer: String? = nil) {
        self.function = function
        self.layer = layer
    }
}

public struct APIFireAlertCommand: Codable, Sendable {
    public var presetId: String?
    public var message: String?

    public var tokens: [String: String]?
    public var behavior: String?
    public var target: String?
    public var themeId: String?

    public init(
        presetId: String? = nil, message: String? = nil, tokens: [String: String]? = nil,
        behavior: String? = nil, target: String? = nil, themeId: String? = nil
    ) {
        self.presetId = presetId
        self.message = message
        self.tokens = tokens
        self.behavior = behavior
        self.target = target
        self.themeId = themeId
    }
}

public enum APITimerAction: String, Codable, Sendable {
    case play, pause, reset
}

public struct APIAudioFireCommand: Codable, Sendable {
    public var startAtEntryId: String?

    public init(startAtEntryId: String? = nil) {
        self.startAtEntryId = startAtEntryId
    }
}

public struct APIAudioStopCommand: Codable, Sendable {
    public var playlistId: String?
    public var audioItemId: String?

    public init(playlistId: String? = nil, audioItemId: String? = nil) {
        self.playlistId = playlistId
        self.audioItemId = audioItemId
    }
}

public struct APIAudioTransportCommand: Codable, Sendable {

    public var action: String
    public var position: Double?

    public init(action: String, position: Double? = nil) {
        self.action = action
        self.position = position
    }
}

public struct APIMediaTransportCommand: Codable, Sendable {

    public var action: String
    public var position: Double?

    public init(action: String, position: Double? = nil) {
        self.action = action
        self.position = position
    }
}

public struct APIMIDIDeviceStatus: Codable, Sendable {

    public var id: String
    public var name: String
    public var enabled: Bool

    public var direction: String

    public var channel: Int?
    public var connected: Bool

    public var destinationUid: Int?
    public var sourceUid: Int?

    public init(
        id: String, name: String, enabled: Bool, direction: String,
        channel: Int? = nil, connected: Bool,
        destinationUid: Int? = nil, sourceUid: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.direction = direction
        self.channel = channel
        self.connected = connected
        self.destinationUid = destinationUid
        self.sourceUid = sourceUid
    }
}

public struct APIMIDIDeviceEnableCommand: Codable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct APIAddServiceItemCommand: Codable, Sendable {
    public var refId: String
    public var index: Int?

    public init(refId: String, index: Int? = nil) {
        self.refId = refId
        self.index = index
    }
}

public struct APIServerInfo: Codable, Sendable {
    public var name: String
    public var product: String
    public var apiVersion: String
    public var schemaVersion: Int

    public init(name: String, product: String, apiVersion: String, schemaVersion: Int) {
        self.name = name
        self.product = product
        self.apiVersion = apiVersion
        self.schemaVersion = schemaVersion
    }
}
