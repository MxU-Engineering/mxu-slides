import Foundation
import MediaEngine
import Observation
import OutputEngine
import PresenterCore
import RenderEngine
import SlideScene

struct SignageFrame: Sendable, Equatable {
    var engineID: String
    var canvasSize: CGSize
}

@MainActor
@Observable
final class RenderContext {
    let compositor: Compositor
    let media: MediaEngine
    let outputs: OutputManager
    let soak = MediaSoak()
    let sceneBox: Locked<RenderScene>

    let liveBox: Locked<RenderScene>

    let transitions = SceneTransitionEngine()

    private let variantEngines = Locked<[String: SceneTransitionEngine]>([:])

    let confidenceBox: Locked<ConfidenceInfo>

    let confidenceLayoutsBox: Locked<[UUID: ConfidenceLayout]>

    let previewLayoutsBox: Locked<[String: ConfidenceLayout]>

    let signageBox: Locked<[UUID: SignageFrame]>

    @ObservationIgnored weak var canvasView: MetalSceneView?

    var scene: RenderScene {
        didSet { sceneBox.value = scene }
    }

    var nextLiveTransitions: [LayerKind: SceneTransition] = [:]

    static func roomDefault(for layer: LayerKind) -> SceneTransition? {
        let defaults = UserDefaults.standard
        switch layer {
        case .slide:
            guard let raw = defaults.string(forKey: "transition.slide.kind"),
                  let kind = TransitionKind(rawValue: raw)
            else { return nil }
            var stored = MediaTransition(transitionKind: kind)
            stored.durationSeconds =
                defaults.object(forKey: "transition.slide.duration") as? Double ?? 0.5
            return sceneTransition(from: stored)
        case .loopingVideos, .stillGraphics, .videos:

            let kind: TransitionKind
            if let raw = defaults.string(forKey: "transition.media.kind") {
                kind = TransitionKind(rawValue: raw) ?? .cut
            } else {
                kind = .dissolve
            }
            guard kind != .cut else { return nil }
            var stored = MediaTransition(transitionKind: kind)
            stored.durationSeconds =
                defaults.object(forKey: "transition.media.duration") as? Double ?? 0.7
            return sceneTransition(from: stored)
        default:
            return nil
        }
    }

    static func sceneTransition(from transition: MediaTransition?) -> SceneTransition? {
        guard let transition else { return nil }
        let duration = transition.durationSeconds ?? 0.5

        guard duration >= 0.05 else { return .cut }
        switch transition.transitionKind {
        case .cut: return .cut
        case .dissolve: return SceneTransition(kind: .dissolve, duration: duration)
        case .fadeBlack: return SceneTransition(kind: .fade(.black), duration: duration)
        case .fadeWhite: return SceneTransition(kind: .fade(.white), duration: duration)
        case .fadeColor:
            let plate = transition.colorHex.flatMap { ColorHex.color($0) } ?? .black
            return SceneTransition(kind: .fade(plate), duration: duration)
        case .blurDissolve: return SceneTransition(kind: .blurDissolve, duration: duration)
        case .filmBurn: return SceneTransition(kind: .filmBurn, duration: duration)
        }
    }

    var liveScene: RenderScene {
        didSet {
            liveBox.value = liveScene
            let stash = nextLiveTransitions
            nextLiveTransitions = [:]
            transitions.push(liveScene) { layer in
                stash[layer] ?? Self.roomDefault(for: layer)
            }
        }
    }

    func setLiveScenes(_ scene: RenderScene, variants: [String: RenderScene]) {
        let stash = nextLiveTransitions
        variantEngines.withLock { engines in
            for key in engines.keys where variants[key] == nil {
                engines.removeValue(forKey: key)
            }
            for (themeID, variant) in variants {
                let engine = engines[themeID] ?? SceneTransitionEngine(initial: variant)
                engines[themeID] = engine
                engine.push(variant) { layer in
                    stash[layer] ?? Self.roomDefault(for: layer)
                }
            }
        }
        liveScene = scene
    }

    func heldVariantMediaIDs(at date: Date = Date()) -> Set<String> {
        variantEngines.value.values.reduce(into: Set<String>()) {
            $0.formUnion($1.heldMediaIDs(at: date))
        }
    }

    var confidenceInfo: ConfidenceInfo {
        get { confidenceBox.value }
        set { confidenceBox.value = newValue }
    }

    func previewProvider(for target: String) -> @Sendable () -> RenderScene {
        if let layoutID = PreviewTargetLogic.layoutID(for: target) {
            return { [confidenceBox, previewLayoutsBox] in
                previewLayoutsBox.value[layoutID].map {
                    ConfidenceSceneBuilder.scene(layout: $0, info: confidenceBox.value, at: Date())
                } ?? .empty
            }
        } else {
            return outputs.previewProvider(for: target)
        }
    }

    init?() {
        guard let compositor = try? Compositor(),
              let media = try? MediaEngine(device: compositor.device)
        else { return nil }
        self.compositor = compositor
        self.media = media
        self.outputs = OutputManager(compositor: compositor)
        let initialScene = RenderScene.sampleLyricScene()
        self.scene = initialScene
        self.sceneBox = Locked(initialScene)
        let initialLive = RenderScene(canvasSize: initialScene.canvasSize)
        self.liveScene = initialLive
        self.liveBox = Locked(initialLive)
        self.confidenceBox = Locked(ConfidenceInfo())
        self.confidenceLayoutsBox = Locked([:])
        self.previewLayoutsBox = Locked([:])
        self.signageBox = Locked([:])
        compositor.mediaSource = media

        outputs.sceneProvider = { [transitions, confidenceBox] in
            let now = Date()
            return VisibilityRules.filteredScene(
                transitions.scene(at: now), info: confidenceBox.value, at: now
            )
        }

        outputs.variantSceneProvider = { [variantEngines, confidenceBox] themeID in
            guard let engine = variantEngines.value[themeID] else { return nil }
            let now = Date()
            return VisibilityRules.filteredScene(
                engine.scene(at: now), info: confidenceBox.value, at: now
            )
        }
        outputs.signageSceneProvider = { [signageBox] screenID in
            signageBox.value[screenID].map {
                SignageSceneBuilder.scene(mediaID: $0.engineID, canvasSize: $0.canvasSize)
            }
        }

        SyncTestPlayback.install(outputs: outputs, media: media)
        outputs.confidenceSceneProvider = { [confidenceBox, confidenceLayoutsBox] screenID in
            let info = confidenceBox.value
            if let layout = confidenceLayoutsBox.value[screenID] {
                return ConfidenceSceneBuilder.scene(layout: layout, info: info, at: Date())
            }

            return ConfidenceSceneBuilder.scene(info: info, at: Date())
        }

        restorePlaceholderScreens()

        Task { @MainActor [media] in
            await LiveInputPlaceholder.register(into: media)
            ThumbnailStore.shared.markPlaceholdersReady()
        }

        outputs.placeholderConfigurationChanged = { [weak self] in
            self?.savePlaceholderScreens()
        }
    }

    private struct PlaceholderScreenConfig: Codable {
        var id: UUID
        var name: String
        var width: Int
        var height: Int
        var framesPerSecond: Int
        var deviceDisplayUUID: String?
        var deviceDisplayName: String?

        var role: String?

        var adjustments: OutputAdjustments?

        var videoDelayFrames: Int?

        var masks: [OutputMask]?

        var slices: [OutputSliceConfig]?

        var placement: OutputPlacement?
    }

    private struct OutputSliceConfig: Codable {
        var id: UUID
        var name: String?
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var deviceDisplayUUID: String?
        var deviceDisplayName: String?
        var adjustments: OutputAdjustments?
        var videoDelayFrames: Int?
        var placement: OutputPlacement?
    }

    private static let placeholdersKey = "outputs.placeholderScreens"

    private static let placeholdersBackupKey = "outputs.placeholderScreens.backup-m43"

    func savePlaceholderScreens() {
        let configs = outputs.placeholderScreens.map { screen in
            PlaceholderScreenConfig(
                id: screen.id, name: screen.name,
                width: screen.width, height: screen.height,
                framesPerSecond: screen.framesPerSecond,
                deviceDisplayUUID: outputs.placeholderDevices[screen.id],
                deviceDisplayName: outputs.placeholderDeviceNames[screen.id],
                role: outputs.screenRoles[screen.id]?.rawValue,
                adjustments: outputs.outputAdjustments[screen.id],
                videoDelayFrames: outputs.videoDelays[screen.id],
                masks: outputs.screenMasks[screen.id],
                slices: outputs.screenSlices[screen.id].map { extras in
                    extras.map { slice in
                        OutputSliceConfig(
                            id: slice.id, name: slice.name,
                            x: slice.sourceRect.minX, y: slice.sourceRect.minY,
                            width: slice.sourceRect.width, height: slice.sourceRect.height,
                            deviceDisplayUUID: outputs.placeholderDevices[slice.id],
                            deviceDisplayName: outputs.placeholderDeviceNames[slice.id],
                            adjustments: outputs.outputAdjustments[slice.id],
                            videoDelayFrames: outputs.videoDelays[slice.id],
                            placement: outputs.slicePlacements[slice.id]
                        )
                    }
                },
                placement: outputs.slicePlacements[screen.id]
            )
        }
        let defaults = UserDefaults.standard
        if defaults.data(forKey: Self.placeholdersBackupKey) == nil,
           let existing = defaults.data(forKey: Self.placeholdersKey) {
            defaults.set(existing, forKey: Self.placeholdersBackupKey)
        }
        if let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: Self.placeholdersKey)
        }
    }

    private func restorePlaceholderScreens() {
        guard let data = UserDefaults.standard.data(forKey: Self.placeholdersKey),
              let configs = try? JSONDecoder().decode([PlaceholderScreenConfig].self, from: data)
        else { return }
        for config in configs {
            outputs.addPlaceholderScreen(
                id: config.id, name: config.name,
                width: config.width, height: config.height,
                framesPerSecond: config.framesPerSecond
            )
            if let role = config.role.flatMap(ScreenRole.init(rawValue:)) {
                outputs.setRole(role, forScreen: config.id)
            }
            if let adjustments = config.adjustments {
                outputs.setAdjustments(adjustments, forScreen: config.id)
            }
            if let masks = config.masks {
                outputs.setMasks(masks, forScreen: config.id)
            }
            if let placement = config.placement {
                outputs.setPlacement(placement, forSlice: config.id)
            }
            if let delay = config.videoDelayFrames {
                outputs.setVideoDelay(delay, forScreen: config.id)
            }
            if let device = config.deviceDisplayUUID {
                outputs.assignPlaceholderDevice(
                    placeholderID: config.id, displayUUID: device,
                    displayName: config.deviceDisplayName
                )
            }
            for slice in config.slices ?? [] {
                outputs.addSlice(
                    toScreen: config.id, id: slice.id, name: slice.name,
                    sourceRect: CGRect(
                        x: slice.x, y: slice.y, width: slice.width, height: slice.height)
                )
                if let adjustments = slice.adjustments {
                    outputs.setAdjustments(adjustments, forScreen: slice.id)
                }
                if let delay = slice.videoDelayFrames {
                    outputs.setVideoDelay(delay, forScreen: slice.id)
                }
                if let device = slice.deviceDisplayUUID {
                    outputs.assignPlaceholderDevice(
                        placeholderID: slice.id, displayUUID: device,
                        displayName: slice.deviceDisplayName
                    )
                }
                if let placement = slice.placement {
                    outputs.setPlacement(placement, forSlice: slice.id)
                }
            }
        }
    }
}
