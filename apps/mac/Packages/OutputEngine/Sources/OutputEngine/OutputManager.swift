import AppKit
import Observation
import RenderEngine

public enum ScreenRole: String, Sendable, CaseIterable {
    case audience
    case confidence

    public var displayName: String {
        switch self {
        case .audience: "Audience"
        case .confidence: "Confidence Monitor"
        }
    }
}

@MainActor
@Observable
public final class OutputManager {
    public private(set) var displays: [DisplaySnapshot] = []

    public private(set) var assignedDisplays: Set<DisplayUUID> = []
    public private(set) var windows: [DisplayUUID: OutputWindowController] = [:]
    public private(set) var placeholderScreens: [PlaceholderScreen] = []

    public private(set) var placeholderDevices: [UUID: DisplayUUID] = [:]

    public private(set) var placeholderDeviceNames: [UUID: String] = [:]
    public private(set) var placeholderWindows: [DisplayUUID: OutputWindowController] = [:]

    private var placeholderWindowSlices: [DisplayUUID: Set<UUID>] = [:]

    public var placeholderConfigurationChanged: (() -> Void)?

    public private(set) var reconfigurationCount = 0

    public let sleepProofing: SleepProofing

    public var sceneProvider: (@Sendable () -> RenderScene)?

    public var confidenceSceneProvider: (@Sendable (UUID) -> RenderScene)?

    public var signageSceneProvider: (@Sendable (UUID) -> RenderScene?)?

    public private(set) var screenRoles: [UUID: ScreenRole] = [:]
    private let roleBox = Locked<[UUID: ScreenRole]>([:])

    public func role(forScreen id: UUID) -> ScreenRole {
        screenRoles[id] ?? .audience
    }

    public func setRole(_ role: ScreenRole, forScreen id: UUID) {
        guard self.role(forScreen: id) != role else { return }
        if role == .audience {
            screenRoles.removeValue(forKey: id)
        } else {
            screenRoles[id] = role
        }
        roleBox.value = screenRoles
        placeholderConfigurationChanged?()
    }

    public private(set) var outputAdjustments: [UUID: OutputAdjustments] = [:]
    private let adjustmentsBox = Locked<[UUID: OutputAdjustments]>([:])

    public func adjustments(forScreen id: UUID) -> OutputAdjustments {
        outputAdjustments[id] ?? OutputAdjustments()
    }

    public func setAdjustments(_ adjustments: OutputAdjustments, forScreen id: UUID) {
        guard self.adjustments(forScreen: id) != adjustments else { return }
        if adjustments == OutputAdjustments() {
            outputAdjustments.removeValue(forKey: id)
        } else {
            outputAdjustments[id] = adjustments
        }
        adjustmentsBox.value = outputAdjustments
        pushAdjustments(forScreen: id)
        placeholderConfigurationChanged?()
    }

    public func adjustmentsProvider(for targetID: String) -> @Sendable () -> OutputAdjustments? {
        let box = adjustmentsBox
        let screenID = UUID(uuidString: targetID)
        return {
            guard let screenID else { return nil }
            return box.value[screenID].flatMap { $0.isNeutral ? nil : $0 }
        }
    }

    public private(set) var screenSlices: [UUID: [OutputSliceState]] = [:]

    public func slices(forScreen id: UUID) -> [OutputSliceState] {
        guard placeholderScreens.contains(where: { $0.id == id }) else { return [] }
        return [OutputSliceState(id: id, name: nil, sourceRect: Compositor.fullSourceRect)]
            + (screenSlices[id] ?? [])
    }

    public func sliceInfo(
        for id: UUID
    ) -> (screenID: UUID, sourceRect: CGRect, width: Int, height: Int, name: String?)? {
        if let screen = placeholderScreens.first(where: { $0.id == id }) {
            return (id, Compositor.fullSourceRect, screen.width, screen.height, nil)
        }
        for (screenID, extras) in screenSlices {
            guard let slice = extras.first(where: { $0.id == id }),
                  let screen = placeholderScreens.first(where: { $0.id == screenID })
            else { continue }
            return (
                screenID, slice.sourceRect,
                max(1, Int((Double(screen.width) * slice.sourceRect.width).rounded())),
                max(1, Int((Double(screen.height) * slice.sourceRect.height).rounded())),
                slice.name
            )
        }
        return nil
    }

    @discardableResult
    public func addSlice(
        toScreen screenID: UUID, id: UUID = UUID(), name: String? = nil,
        sourceRect: CGRect = Compositor.fullSourceRect
    ) -> OutputSliceState? {
        guard placeholderScreens.contains(where: { $0.id == screenID }) else { return nil }
        let slice = OutputSliceState(id: id, name: name, sourceRect: clampedUnit(sourceRect))
        screenSlices[screenID, default: []].append(slice)
        placeholderConfigurationChanged?()
        return slice
    }

    public func removeSlice(id: UUID) {
        guard let screenID = sliceInfo(for: id)?.screenID, screenID != id else { return }
        screenSlices[screenID]?.removeAll { $0.id == id }
        if screenSlices[screenID]?.isEmpty == true { screenSlices.removeValue(forKey: screenID) }
        clearSliceState(id)
        reconcilePlaceholderWindows()
        placeholderConfigurationChanged?()
    }

    public func setSliceSourceRect(_ rect: CGRect, forSlice id: UUID) {
        guard let screenID = sliceInfo(for: id)?.screenID, screenID != id,
              let index = screenSlices[screenID]?.firstIndex(where: { $0.id == id })
        else { return }
        let clamped = clampedUnit(rect)
        guard screenSlices[screenID]?[index].sourceRect != clamped else { return }
        screenSlices[screenID]?[index].sourceRect = clamped
        if let display = placeholderDevices[id] {
            if placeholderWindowSlices[display]?.count ?? 0 > 1 {
                configureWindow(display)
            } else {
                placeholderWindows[display]?.sceneView.outputSourceRect =
                    clamped == Compositor.fullSourceRect ? nil : clamped
            }
        }
        placeholderConfigurationChanged?()
    }

    public func setSliceName(_ name: String?, forSlice id: UUID) {
        guard let screenID = sliceInfo(for: id)?.screenID, screenID != id,
              let index = screenSlices[screenID]?.firstIndex(where: { $0.id == id })
        else { return }
        let trimmed = name.flatMap { $0.isEmpty ? nil : $0 }
        guard screenSlices[screenID]?[index].name != trimmed else { return }
        screenSlices[screenID]?[index].name = trimmed
        placeholderConfigurationChanged?()
    }

    public private(set) var slicePlacements: [UUID: OutputPlacement] = [:]

    public func placement(forSlice id: UUID) -> OutputPlacement? {
        slicePlacements[id]
    }

    public func setPlacement(_ placement: OutputPlacement?, forSlice id: UUID) {
        let normalized = placement.flatMap { $0.isFill ? nil : $0 }
        guard slicePlacements[id] != normalized else { return }
        if let normalized {
            slicePlacements[id] = normalized
        } else {
            slicePlacements.removeValue(forKey: id)
        }
        pushPlacement(forSlice: id)
        placeholderConfigurationChanged?()
    }

    private func pushPlacement(forSlice id: UUID) {
        if let display = placeholderDevices[id] {
            if placeholderWindowSlices[display]?.count ?? 0 > 1 {
                configureWindow(display)
            } else {
                placeholderWindows[display]?.sceneView.outputPlacement =
                    slicePlacements[id]?.unitRect
            }
        }
    }

    private func clampedUnit(_ rect: CGRect) -> CGRect {
        let x = min(max(rect.minX, 0), 1)
        let y = min(max(rect.minY, 0), 1)
        return CGRect(
            x: x, y: y,
            width: min(max(rect.width, 0.01), 1 - x),
            height: min(max(rect.height, 0.01), 1 - y)
        )
    }

    private func clearSliceState(_ id: UUID) {
        placeholderDevices.removeValue(forKey: id)
        placeholderDeviceNames.removeValue(forKey: id)
        videoDelays.removeValue(forKey: id)
        videoDelayBox.value = videoDelays
        outputAdjustments.removeValue(forKey: id)
        adjustmentsBox.value = outputAdjustments
        maskTextureBox.withLock { $0.removeValue(forKey: id) }
        maskRasterCache.removeValue(forKey: id)
        slicePlacements.removeValue(forKey: id)
    }

    public private(set) var testPatternScreens: Set<UUID> = []
    private let testPatternBox = Locked<Set<UUID>>([])

    public func setTestPattern(_ on: Bool, forScreen id: UUID) {
        if on { testPatternScreens.insert(id) } else { testPatternScreens.remove(id) }
        testPatternBox.value = testPatternScreens
    }

    public private(set) var syncTestScreens: Set<UUID> = []
    private let syncTestBox = Locked<Set<UUID>>([])
    public static let syncTestMediaID = "test-pattern.sync"
    public var syncTestPlayback: (@MainActor (Bool) -> Void)?

    public func setSyncTest(_ on: Bool, forScreen id: UUID) {
        let wasPlaying = !syncTestScreens.isEmpty
        if on { syncTestScreens.insert(id) } else { syncTestScreens.remove(id) }
        syncTestBox.value = syncTestScreens
        let playing = !syncTestScreens.isEmpty
        if playing != wasPlaying { syncTestPlayback?(playing) }
    }

    static func syncTestScene(canvasSize: CGSize) -> RenderScene {
        var scene = RenderScene(canvasSize: canvasSize)
        scene.background = SceneColor(red: 0.06, green: 0.06, blue: 0.06)
        scene.addItem(
            RenderItem(
                id: syncTestMediaID, frame: CGRect(origin: .zero, size: canvasSize),
                content: .media(id: syncTestMediaID, scaleMode: .fit, sourceRect: nil)),
            to: .videos)
        return scene
    }

    static func alignmentGrid(canvasSize: CGSize) -> RenderScene {
        var scene = RenderScene(canvasSize: canvasSize)
        scene.background = SceneColor(red: 0.12, green: 0.12, blue: 0.12)
        let line = SceneColor(red: 0.85, green: 0.85, blue: 0.85)
        let accent = SceneColor(red: 0.2, green: 0.85, blue: 0.4)
        var index = 0
        func add(_ frame: CGRect, _ color: SceneColor) {
            scene.addItem(
                RenderItem(id: "grid-\(index)", frame: frame, content: .solid(color)),
                to: .slide
            )
            index += 1
        }
        let w = canvasSize.width
        let h = canvasSize.height
        let thin = max(1, (w / 960).rounded())
        for step in 1..<10 {
            let fraction = Double(step) / 10
            add(CGRect(x: w * fraction - thin / 2, y: 0, width: thin, height: h), line)
            add(CGRect(x: 0, y: h * fraction - thin / 2, width: w, height: thin), line)
        }

        add(CGRect(x: 0, y: 0, width: w, height: thin * 2), line)
        add(CGRect(x: 0, y: h - thin * 2, width: w, height: thin * 2), line)
        add(CGRect(x: 0, y: 0, width: thin * 2, height: h), line)
        add(CGRect(x: w - thin * 2, y: 0, width: thin * 2, height: h), line)

        let diagonalLength = (w * w + h * h).squareRoot()
        let diagonalAngle = Foundation.atan2(h, w) * 180 / .pi
        for angle in [diagonalAngle, -diagonalAngle] {
            var diagonal = RenderItem(
                id: "grid-diag-\(index)",
                frame: CGRect(
                    x: (w - diagonalLength) / 2, y: h / 2 - thin / 2,
                    width: diagonalLength, height: thin
                ),
                content: .solid(line)
            )
            diagonal.rotationDegrees = angle
            scene.addItem(diagonal, to: .slide)
            index += 1
        }

        let diameter = h * 0.6
        scene.addItem(
            RenderItem(
                id: "grid-circle",
                frame: CGRect(
                    x: w / 2 - diameter / 2, y: h / 2 - diameter / 2,
                    width: diameter, height: diameter
                ),
                content: .shape(ShapeStyle(
                    kind: .ellipse, fill: .none,
                    stroke: SceneStroke(color: line, width: thin * 2)
                ))
            ),
            to: .slide
        )

        add(CGRect(x: w / 2 - thin * 2, y: 0, width: thin * 4, height: h), accent)
        add(CGRect(x: 0, y: h / 2 - thin * 2, width: w, height: thin * 4), accent)
        return scene
    }

    public private(set) var screenMasks: [UUID: [OutputMask]] = [:]

    private var activeMaskIDs: [UUID: Set<UUID>] = [:]

    private let maskTextureBox = Locked<[UUID: MaskTextureHolder]>([:])

    private var maskRasterCache: [UUID: (fingerprint: String, texture: MTLTexture)] = [:]

    private final class MaskTextureHolder: @unchecked Sendable {
        let texture: MTLTexture
        init(_ texture: MTLTexture) { self.texture = texture }
    }

    public func masks(forScreen id: UUID) -> [OutputMask] {
        screenMasks[id] ?? []
    }

    public func setMasks(_ masks: [OutputMask], forScreen id: UUID) {
        guard self.masks(forScreen: id) != masks else { return }
        if masks.isEmpty {
            screenMasks.removeValue(forKey: id)
        } else {
            screenMasks[id] = masks
        }
        pushMasks(forScreen: id)
        placeholderConfigurationChanged?()
    }

    public func setActiveMaskIDs(_ ids: Set<UUID>, forScreen id: UUID) {
        guard activeMaskIDs[id] ?? [] != ids else { return }
        if ids.isEmpty {
            activeMaskIDs.removeValue(forKey: id)
        } else {
            activeMaskIDs[id] = ids
        }
        pushMasks(forScreen: id)
    }

    public func activeMasks(forScreen id: UUID) -> [OutputMask] {
        let activated = activeMaskIDs[id] ?? []
        return masks(forScreen: id).filter { $0.alwaysOn || activated.contains($0.id) }
    }

    private func pushMasks(forScreen id: UUID) {
        guard let screenID = sliceInfo(for: id)?.screenID else { return }
        for slice in slices(forScreen: screenID) {
            let texture = maskTexture(forScreen: screenID, slice: slice.id)
            maskTextureBox.withLock { box in
                box[slice.id] = texture.map(MaskTextureHolder.init)
            }
            if slice.id == screenID {
                placeholderScreens.first { $0.id == screenID }?.outputMask = texture
            }
            if let display = placeholderDevices[slice.id] {
                if placeholderWindowSlices[display]?.count ?? 0 > 1 {
                    configureWindow(display)
                } else {
                    placeholderWindows[display]?.sceneView.outputMask = texture
                }
            }
        }
    }

    private func maskTexture(forScreen screenID: UUID, slice sliceID: UUID) -> MTLTexture? {
        guard let screen = placeholderScreens.first(where: { $0.id == screenID }) else {
            maskRasterCache.removeValue(forKey: sliceID)
            return nil
        }
        let active = activeMasks(forScreen: screenID).filter {
            $0.sliceIds == nil || $0.sliceIds?.contains(sliceID) == true
        }
        guard !active.isEmpty else {
            maskRasterCache.removeValue(forKey: sliceID)
            return nil
        }
        let fingerprint = active.map {
            "\($0.id)|\($0.pathData)|\($0.mode.rawValue)|\($0.feather)"
        }.joined(separator: "·") + "@\(screen.width)x\(screen.height)"
        if let cached = maskRasterCache[sliceID], cached.fingerprint == fingerprint {
            return cached.texture
        }

        if let shared = maskRasterCache.values.first(where: { $0.fingerprint == fingerprint }) {
            maskRasterCache[sliceID] = shared
            return shared.texture
        }
        guard let texture = OutputMaskRaster.texture(
            masks: active, width: screen.width, height: screen.height,
            device: compositor.device
        ) else {
            maskRasterCache.removeValue(forKey: sliceID)
            return nil
        }
        maskRasterCache[sliceID] = (fingerprint, texture)
        return texture
    }

    public func setCanvasWake(_ awake: Bool, forScreen id: UUID) {
        guard let screen = placeholderScreens.first(where: { $0.id == id }) else { return }
        if awake {
            screen.start()
        } else if placeholderDevices[id] != nil {
            screen.stop()
        }
    }

    public func maskProvider(for targetID: String) -> @Sendable () -> MTLTexture? {
        let box = maskTextureBox
        let screenID = UUID(uuidString: targetID)
        return {
            guard let screenID else { return nil }
            return box.value[screenID]?.texture
        }
    }

    private func pushAdjustments(forScreen id: UUID) {
        let value = outputAdjustments[id].flatMap { $0.isNeutral ? nil : $0 }
        placeholderScreens.first { $0.id == id }?.outputAdjustments = value
        if let display = placeholderDevices[id] {
            if placeholderWindowSlices[display]?.count ?? 0 > 1 {
                configureWindow(display)
            } else {
                placeholderWindows[display]?.sceneView.outputAdjustments = value
            }
        }
    }

    private func configureWindow(_ display: DisplayUUID) {
        guard let controller = placeholderWindows[display],
              let members = placeholderWindowSlices[display]
        else { return }
        let targets = members.compactMap { sliceID -> (slice: UUID, screen: UUID)? in
            sliceInfo(for: sliceID).map { (sliceID, $0.screenID) }
        }.sorted { $0.slice.uuidString < $1.slice.uuidString }
        if targets.count <= 1 {
            guard let target = targets.first else { return }
            let rect = sliceInfo(for: target.slice)?.sourceRect ?? Compositor.fullSourceRect
            controller.sceneView.compositeSources = nil
            controller.sceneView.outputSourceRect =
                rect == Compositor.fullSourceRect ? nil : rect
            controller.sceneView.outputPlacement = slicePlacements[target.slice]?.unitRect
            controller.sceneView.outputAdjustments =
                outputAdjustments[target.slice].flatMap { $0.isNeutral ? nil : $0 }
            controller.sceneView.outputMask = maskTexture(
                forScreen: target.screen, slice: target.slice)
            return
        }
        controller.sceneView.compositeSources = targets.map { target in
            let info = sliceInfo(for: target.slice)
            let rect = info?.sourceRect ?? Compositor.fullSourceRect
            return MetalSceneView.CompositeSource(
                provider: provider(for: target.screen.uuidString),
                sourceRect: rect == Compositor.fullSourceRect ? nil : rect,
                placement: slicePlacements[target.slice]?.unitRect,
                adjustments: outputAdjustments[target.slice]
                    .flatMap { $0.isNeutral ? nil : $0 },
                mask: maskTexture(forScreen: target.screen, slice: target.slice)
            )
        }
    }

    public private(set) var videoDelays: [UUID: Int] = [:]
    private let videoDelayBox = Locked<[UUID: Int]>([:])

    public static let maxVideoDelayFrames = 15

    public func videoDelay(forScreen id: UUID) -> Int {
        videoDelays[id] ?? 0
    }

    public func setVideoDelay(_ frames: Int, forScreen id: UUID) {
        let clamped = max(0, min(frames, Self.maxVideoDelayFrames))
        guard videoDelay(forScreen: id) != clamped else { return }
        if clamped == 0 {
            videoDelays.removeValue(forKey: id)
        } else {
            videoDelays[id] = clamped
        }
        videoDelayBox.value = videoDelays
        pushVideoDelay(forScreen: id)
        placeholderConfigurationChanged?()
    }

    private func pushVideoDelay(forScreen id: UUID) {
        if let display = placeholderDevices[id] {
            placeholderWindows[display]?.sceneView.videoDelayFrames = videoDelay(forScreen: id)
        }
    }

    public func videoDelayProvider(for targetID: String) -> @Sendable () -> Int {
        let box = videoDelayBox
        let screenID = UUID(uuidString: targetID)
        return {
            guard let screenID else { return 0 }
            return box.value[screenID] ?? 0
        }
    }

    private let layerRouting = Locked<[String: Set<String>]>([:])

    public func setLayerRouting(_ routing: [String: Set<String>]) {
        layerRouting.value = routing
    }

    private let slideThemeRouting = Locked<[String: String]>([:])

    public func setSlideThemeRouting(_ routing: [String: String]) {
        slideThemeRouting.value = routing
    }

    public var variantSceneProvider: (@Sendable (String) -> RenderScene?)?

    public func previewProvider(for targetID: String) -> @Sendable () -> RenderScene {
        provider(for: targetID)
    }

    private func provider(for targetID: String) -> @Sendable () -> RenderScene {
        let base = sceneProvider ?? { .empty }
        let confidence = confidenceSceneProvider
        let signage = signageSceneProvider
        let variants = variantSceneProvider
        let routing = layerRouting
        let themeRouting = slideThemeRouting
        let roles = roleBox

        let screenID = UUID(uuidString: targetID).map { sliceInfo(for: $0)?.screenID ?? $0 }
        let routingKey = screenID?.uuidString ?? targetID

        let patterns = testPatternBox
        let syncTests = syncTestBox
        let canvasSize = screenID
            .flatMap { id in placeholderScreens.first { $0.id == id } }
            .map { CGSize(width: $0.width, height: $0.height) }
        let grid = canvasSize.map { Self.alignmentGrid(canvasSize: $0) }
        let syncTest = canvasSize.map { Self.syncTestScene(canvasSize: $0) }
        return {
            if let screenID, let grid, patterns.value.contains(screenID) {
                return grid
            }
            if let screenID, let syncTest, syncTests.value.contains(screenID) {
                return syncTest
            }

            if let screenID, let signage, let scene = signage(screenID) {
                return scene
            }
            if let screenID, let confidence, roles.value[screenID] == .confidence {
                return confidence(screenID)
            }

            var scene: RenderScene
            if let variants, let themeID = themeRouting.value[routingKey],
               let variant = variants(themeID) {
                scene = variant
            } else {
                scene = base()
            }
            guard let enabled = routing.value[routingKey] else { return scene }
            for index in scene.layers.indices
            where !enabled.contains(scene.layers[index].kind.rawValue) {
                scene.layers[index].isHidden = true
            }
            return scene
        }
    }

    private let compositor: Compositor
    private var screenParametersObserver: NSObjectProtocol?

    public init(compositor: Compositor, powerAssertions: (any PowerAsserting)? = nil) {
        self.compositor = compositor
        sleepProofing = SleepProofing(
            assertions: powerAssertions ?? SystemPowerAssertions()
        )
        displays = DisplaySnapshot.connectedDisplays()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconfigurationCount += 1
                self.reconcile()
            }
        }
    }

    public func isLive(_ uuid: DisplayUUID) -> Bool {
        assignedDisplays.contains(uuid)
    }

    public func setLive(_ uuid: DisplayUUID, _ live: Bool) {

        if live, let claimant = placeholderDevices.first(where: { $0.value == uuid })?.key {
            placeholderDevices.removeValue(forKey: claimant)
            placeholderDeviceNames.removeValue(forKey: claimant)
            placeholderConfigurationChanged?()
        }
        if live {
            assignedDisplays.insert(uuid)
        } else {
            assignedDisplays.remove(uuid)
        }
        reconcile()
    }

    private func reconcile() {
        displays = DisplaySnapshot.connectedDisplays()
        let changes = OutputTopology.reconcile(
            assigned: assignedDisplays,
            openWindows: windows.mapValues(\.frame),
            connected: displays
        )
        for change in changes {
            switch change {
            case .close(let uuid):
                windows.removeValue(forKey: uuid)?.close()
            case .reframe(let uuid, let frame):
                windows[uuid]?.reframe(to: frame)
            case .open(let uuid):
                guard let display = displays.first(where: { $0.uuid == uuid }),
                      let screen = display.currentScreen()
                else { continue }
                windows[uuid] = OutputWindowController(
                    display: display,
                    screen: screen,
                    compositor: compositor,
                    sceneProvider: provider(for: uuid),
                    onUserClose: { [weak self] uuid in self?.setLive(uuid, false) }
                )
            }
        }
        reconcilePlaceholderWindows()
    }

    @discardableResult
    public func addPlaceholderScreen(
        id: UUID = UUID(),
        name: String,
        width: Int,
        height: Int,
        framesPerSecond: Int = 30
    ) -> PlaceholderScreen? {
        guard let screen = PlaceholderScreen(
            compositor: compositor,
            id: id,
            name: name,
            width: width,
            height: height,
            framesPerSecond: framesPerSecond
        ) else { return nil }
        screen.sceneProvider = provider(for: screen.id.uuidString)
        screen.start()
        placeholderScreens.append(screen)
        pushAdjustments(forScreen: screen.id)
        pushMasks(forScreen: screen.id)
        updateSleepProofing()
        placeholderConfigurationChanged?()
        return screen
    }

    public func assignPlaceholderDevice(
        placeholderID: UUID, displayUUID: DisplayUUID?, displayName: String? = nil,
        exclusive: Bool = true
    ) {
        if let displayUUID {

            if exclusive {
                placeholderDevices = placeholderDevices.filter { $0.value != displayUUID }
            }
            placeholderDevices[placeholderID] = displayUUID
            if let name = displayName
                ?? displays.first(where: { $0.uuid == displayUUID })?.name {
                placeholderDeviceNames[placeholderID] = name
            }
            if assignedDisplays.contains(displayUUID) {
                assignedDisplays.remove(displayUUID)
                reconcile() 
                placeholderConfigurationChanged?()
                return
            }
        } else {
            placeholderDevices.removeValue(forKey: placeholderID)
            placeholderDeviceNames.removeValue(forKey: placeholderID)
        }
        reconcilePlaceholderWindows()
        placeholderConfigurationChanged?()
    }

    private func reconcilePlaceholderWindows() {

        var wanted: [DisplayUUID: [(sliceID: UUID, screenID: UUID)]] = [:]
        for screen in placeholderScreens {
            for slice in slices(forScreen: screen.id) {
                if let displayUUID = placeholderDevices[slice.id] {
                    wanted[displayUUID, default: []].append((slice.id, screen.id))
                }
            }
        }
        for (uuid, controller) in placeholderWindows
        where placeholderWindowSlices[uuid] != wanted[uuid].map({ Set($0.map(\.sliceID)) }) {
            controller.close()
            placeholderWindows.removeValue(forKey: uuid)
            placeholderWindowSlices.removeValue(forKey: uuid)
        }
        for (uuid, targets) in wanted {
            guard let display = displays.first(where: { $0.uuid == uuid }) else {
                placeholderWindows.removeValue(forKey: uuid)?.close()
                placeholderWindowSlices.removeValue(forKey: uuid)
                continue
            }
            if let existing = placeholderWindows[uuid] {
                if existing.frame != display.frame { existing.reframe(to: display.frame) }
            } else if let screen = display.currentScreen(), let first = targets.first {

                let controller = OutputWindowController(
                    display: display,
                    screen: screen,
                    compositor: compositor,
                    sceneProvider: provider(for: first.screenID.uuidString),
                    onUserClose: { [weak self] uuid in
                        guard let self else { return }

                        for claimant in self.placeholderDevices
                            .filter({ $0.value == uuid }).keys {
                            self.assignPlaceholderDevice(
                                placeholderID: claimant, displayUUID: nil
                            )
                        }
                    }
                )
                placeholderWindows[uuid] = controller
                placeholderWindowSlices[uuid] = Set(targets.map(\.sliceID))
                configureWindow(uuid)
                for target in targets {
                    pushVideoDelay(forScreen: target.sliceID)
                }
            }
        }

        for screen in placeholderScreens {
            let claimed = slices(forScreen: screen.id)
                .contains { placeholderDevices[$0.id] != nil }
            if claimed {
                screen.stop()
            } else if !screen.isRunning {
                screen.start()
            }
        }
        updateSleepProofing()
    }

    @discardableResult
    public func reconfigurePlaceholderScreen(
        id: PlaceholderScreen.ID,
        name: String,
        width: Int,
        height: Int,
        framesPerSecond: Int = 30
    ) -> PlaceholderScreen? {
        guard let index = placeholderScreens.firstIndex(where: { $0.id == id }),
              let screen = PlaceholderScreen(
                  compositor: compositor,
                  id: id,
                  name: name,
                  width: width,
                  height: height,
                  framesPerSecond: framesPerSecond
              )
        else { return nil }
        placeholderScreens[index].stop()
        screen.sceneProvider = provider(for: id.uuidString)

        if placeholderDevices[id] == nil { screen.start() }
        placeholderScreens[index] = screen
        pushAdjustments(forScreen: id)
        pushMasks(forScreen: id)  
        updateSleepProofing()
        placeholderConfigurationChanged?()
        return screen
    }

    public func removePlaceholderScreen(id: PlaceholderScreen.ID) {
        guard let index = placeholderScreens.firstIndex(where: { $0.id == id }) else { return }
        placeholderScreens[index].stop()
        placeholderScreens.remove(at: index)
        placeholderDevices.removeValue(forKey: id)
        placeholderDeviceNames.removeValue(forKey: id)
        screenRoles.removeValue(forKey: id)
        roleBox.value = screenRoles
        videoDelays.removeValue(forKey: id)
        videoDelayBox.value = videoDelays
        outputAdjustments.removeValue(forKey: id)
        adjustmentsBox.value = outputAdjustments
        screenMasks.removeValue(forKey: id)
        activeMaskIDs.removeValue(forKey: id)
        maskRasterCache.removeValue(forKey: id)
        maskTextureBox.withLock { $0.removeValue(forKey: id) }
        for slice in screenSlices[id] ?? [] { clearSliceState(slice.id) }
        screenSlices.removeValue(forKey: id)
        slicePlacements.removeValue(forKey: id)
        reconcilePlaceholderWindows()
        placeholderConfigurationChanged?()
    }

    private func updateSleepProofing() {
        let live = windows.count + placeholderWindows.count
            + placeholderScreens.count(where: \.isRunning)
        sleepProofing.setLiveOutputCount(live)
    }
}
