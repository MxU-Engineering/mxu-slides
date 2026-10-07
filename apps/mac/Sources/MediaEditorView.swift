import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

@MainActor
@Observable
final class MediaPreviewPlayer {
    let player = AVPlayer()
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false

    private(set) var frameRate: Double?
    private(set) var codec: String?
    private(set) var naturalWidth: Double?

    var trimWindow: ClosedRange<Double>?

    var playRate: Double = 1

    private var pollTimer: Timer?

    private var seekInFlight = false
    private var pendingSeekSeconds: Double?

    private var resumeAfterScrub = false

    private var lastAppliedEffects: [SceneEffect]?

    init() {

        let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard player.currentItem != nil else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite, !seekInFlight { elapsed = max(0, seconds) }
        isPlaying = player.rate != 0

        if isPlaying, let window = trimWindow, elapsed >= window.upperBound - 0.06 {
            seek(to: window.lowerBound, final: true)
        }
    }

    func load(url: URL) async {
        player.pause()
        elapsed = 0
        duration = 0
        frameRate = nil
        codec = nil
        naturalWidth = nil
        seekInFlight = false
        pendingSeekSeconds = nil
        resumeAfterScrub = false
        lastAppliedEffects = nil
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        duration = (try? await asset.load(.duration).seconds) ?? 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            frameRate = (try? await track.load(.nominalFrameRate)).map(Double.init)
            naturalWidth = (try? await track.load(.naturalSize)).map { Double($0.width) }
            if let descriptions = try? await track.load(.formatDescriptions),
               let first = descriptions.first {
                let sub = CMFormatDescriptionGetMediaSubType(first)
                codec = String(fourCharCode: sub)
            }
        }
    }

    func applyEffects(_ effects: [SceneEffect], canvasWidth: Double) {
        guard let item = player.currentItem else { return }

        guard effects != lastAppliedEffects else { return }
        lastAppliedEffects = effects
        guard !effects.isEmpty else {
            item.videoComposition = nil
            return
        }

        let feedback = EffectPreviewFeedback()

        let factor: CGFloat = (naturalWidth ?? 0) > 2048 ? 1920 / (naturalWidth ?? 1920) : 1
        let composition = AVMutableVideoComposition(asset: item.asset) { request in
            let source = factor < 1
                ? request.sourceImage.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                : request.sourceImage
            let frame = CGRect(
                origin: .zero,
                size: CGSize(
                    width: source.extent.width.rounded(), height: source.extent.height.rounded()
                )
            )

            let scale = Double(frame.width) / canvasWidth
            let out = EffectPreviewRenderer.apply(
                effects, to: source.cropped(to: frame), scale: scale,
                time: request.compositionTime.seconds, feedback: feedback
            )
            request.finish(with: out.cropped(to: frame), context: EffectPreviewRenderer.context)
        }
        if factor < 1 {
            composition.renderSize = CGSize(
                width: (composition.renderSize.width * factor).rounded(),
                height: (composition.renderSize.height * factor).rounded()
            )
        }
        item.videoComposition = composition
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false

            resumeAfterScrub = false
        } else {

            if let window = trimWindow {
                if elapsed < window.lowerBound - 0.05 || elapsed >= window.upperBound - 0.1 {
                    seek(to: window.lowerBound, final: true)
                }
            } else if duration > 0, elapsed >= duration - 0.05 {
                seek(to: 0, final: true)
            }
            player.rate = Float(playRate)
            isPlaying = true
        }
    }

    func seek(to seconds: TimeInterval, final: Bool) {
        elapsed = max(0, seconds)
        if !final, player.rate != 0 {
            player.pause()
            isPlaying = false
            resumeAfterScrub = true
        }
        if final {
            pendingSeekSeconds = nil
            performSeek(seconds, precise: true)
        } else if seekInFlight {
            pendingSeekSeconds = seconds
        } else {
            performSeek(seconds, precise: false)
        }
    }

    private func performSeek(_ seconds: TimeInterval, precise: Bool) {
        seekInFlight = true
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance: CMTime = precise ? .zero : CMTime(value: 1, timescale: 30)
        player.seek(
            to: time, toleranceBefore: tolerance, toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeekSeconds {
                    self.pendingSeekSeconds = nil
                    self.performSeek(next, precise: false)
                } else if precise, self.resumeAfterScrub {

                    self.resumeAfterScrub = false
                    self.player.rate = Float(self.playRate)
                    self.isPlaying = true
                }
            }
        }
    }

    func teardown() {
        player.pause()
        pollTimer?.invalidate()
        pollTimer = nil
        player.replaceCurrentItem(with: nil)
    }
}

extension Array {

    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension EffectKind {

    static var addable: [EffectKind] {
        allCases.filter { $0 != .hueRotate }
    }

    var displayName: String {
        switch self {
        case .blur: "Blur"
        case .colorAdjust: "Color Adjust"
        case .hueRotate: "Hue"
        case .invert: "Invert"
        case .posterize: "Posterize"
        case .pixelate: "Pixelate"
        case .vignette: "Vignette"
        case .warp: "Warp"
        case .echo: "Echo"
        case .scatter: "Scatter"
        case .stainedGlass: "Stained Glass"
        case .grain: "Grain"
        case .ghostTrails: "Ghost Trails"
        }
    }

    var amountControl: (label: String, range: ClosedRange<Double>, step: Double, fallback: Double)? {
        switch self {
        case .hueRotate: ("Shift", -180 ... 180, 1, 90)
        case .posterize: ("Levels", 2 ... 32, 1, 6)
        case .pixelate: ("Size", 1 ... 200, 1, 16)
        case .vignette: ("Strength", 0 ... 1.5, 0.02, 0.8)
        case .warp: ("Amount", 0 ... 300, 1, 40)
        case .echo: ("Length", 0 ... 20, 0.05, 1)
        case .scatter: ("Amount", 0 ... 200, 0.5, 8)
        case .stainedGlass: ("Jitter", 0 ... 1, 0.02, 0.8)
        case .grain: ("Amount", 0 ... 1, 0.02, 0.3)
        case .ghostTrails: ("Drift", 0 ... 60, 0.5, 6)
        case .blur, .colorAdjust, .invert: nil
        }
    }

    struct DialControl: Identifiable {
        let label: String
        let keyPath: WritableKeyPath<Effect, Double?>
        let range: ClosedRange<Double>
        let step: Double
        let fallback: Double
        var id: String { label }
    }

    var extraControls: [DialControl] {
        switch self {
        case .warp: [
            DialControl(label: "Scale", keyPath: \.scale, range: 20 ... 1000, step: 5, fallback: 240),
            DialControl(label: "Speed", keyPath: \.speed, range: 0 ... 4, step: 0.05, fallback: 0.5),
        ]
        case .scatter: [

            DialControl(label: "Size", keyPath: \.scale, range: 1 ... 2.5, step: 0.05, fallback: 1),
            DialControl(label: "Smooth", keyPath: \.smooth, range: 0 ... 1, step: 0.02, fallback: 0),
            DialControl(label: "Speed", keyPath: \.speed, range: 0 ... 1, step: 0.02, fallback: 1),
        ]
        case .stainedGlass: [
            DialControl(label: "Cell Size", keyPath: \.scale, range: 8 ... 400, step: 1, fallback: 80),
            DialControl(label: "Leading", keyPath: \.radius, range: 0 ... 20, step: 0.25, fallback: 3),
            DialControl(label: "Speed", keyPath: \.speed, range: 0 ... 2, step: 0.05, fallback: 0),
        ]
        case .grain: [
            DialControl(label: "Size", keyPath: \.scale, range: 1 ... 8, step: 0.25, fallback: 1),
            DialControl(label: "Speed", keyPath: \.speed, range: 0 ... 1, step: 0.02, fallback: 1),
        ]
        case .ghostTrails: [
            DialControl(label: "Length", keyPath: \.fade, range: 0 ... 20, step: 0.05, fallback: 1.5),
            DialControl(label: "Scale", keyPath: \.scale, range: 20 ... 600, step: 5, fallback: 160),
            DialControl(label: "Speed", keyPath: \.speed, range: 0 ... 4, step: 0.05, fallback: 0.5),
        ]
        default: []
        }
    }

    var freshEffect: Effect {
        switch self {
        case .blur: return Effect(effectKind: .blur, radius: 12)
        case .colorAdjust:
            return Effect(effectKind: .colorAdjust, brightness: 0, contrast: 0, saturation: 1)
        default:
            var effect = Effect(effectKind: self, amount: amountControl?.fallback)
            for control in extraControls { effect[keyPath: control.keyPath] = control.fallback }
            return effect
        }
    }
}

struct EffectPresetsMenu: View {
    let model: AppModel
    let currentChain: [Effect]
    let apply: ([Effect]) -> Void
    let add: ([Effect]) -> Void
    @Binding var presetNamePrompt: Bool

    var body: some View {
        Menu("Presets") {
            Menu("Recommended") {
                ForEach(EffectPreset.recommendedGroups) { group in
                    if group.presets.count == 1, let only = group.presets.first {
                        presetItems(only, builtIn: true, title: group.name)
                    } else {
                        Menu(group.name) {
                            ForEach(group.presets) { preset in
                                presetItems(preset, builtIn: true)
                            }
                        }
                    }
                }
            }
            let presets = model.effectPresetBoard.presets
            if !presets.isEmpty { Divider() }
            ForEach(presets) { preset in
                presetItems(preset, builtIn: false)
            }
            Divider()
            Button("Save as Preset…") { presetNamePrompt = true }
                .disabled(currentChain.isEmpty)
        }
    }

    @ViewBuilder
    private func presetItems(_ preset: EffectPreset, builtIn: Bool, title: String? = nil) -> some View {
        Menu(title ?? preset.name) {
            Button("Apply") { apply(preset.effects) }
            Button("Add") { add(preset.effects) }
            if !builtIn {
                Button("Save Over") {
                    model.overwriteEffectPreset(id: preset.id, effects: currentChain)
                }
                .disabled(currentChain.isEmpty)
                Divider()
                Button("Delete", role: .destructive) {
                    model.deleteEffectPreset(id: preset.id)
                }
            }
        }
    }
}

final class EffectPreviewFeedback: @unchecked Sendable {
    private struct Entry {
        let image: CIImage
        let time: Double
    }

    private var entries: [Int: Entry] = [:]
    private let lock = NSLock()

    func trail(at index: Int, time: Double, fade: Double, extent: CGRect) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[index], entry.image.extent == extent else { return nil }
        let elapsed = time - entry.time
        guard elapsed > 0, elapsed <= Compositor.historyGap else { return nil }
        let keep = CGFloat(pow(0.1, max(elapsed, 1.0 / 240) / max(fade, 0.01)))
        return entry.image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: keep),
        ])
    }

    func store(_ image: CIImage, at index: Int, time: Double) {
        guard let rendered = EffectPreviewRenderer.context.createCGImage(image, from: image.extent)
        else { return }
        let flat = CIImage(cgImage: rendered).transformed(
            by: CGAffineTransform(translationX: image.extent.origin.x, y: image.extent.origin.y)
        )
        lock.lock()
        entries[index] = Entry(image: flat, time: time)
        lock.unlock()
    }
}

enum EffectPreviewRenderer {

    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .workingFormat: CIFormat.RGBA8,
        .cacheIntermediates: false,
    ])

    static let warpKernel: CIWarpKernel? = previewKernel("warpEffect")
    static let scatterKernel: CIWarpKernel? = previewKernel("scatterEffect")
    static let stainedGlassKernel: CIKernel? = previewKernel("stainedGlassEffect")
    static let grainKernel: CIColorKernel? = previewKernel("grainEffect")

    private static let kernelLibrary: Data? = {
        for library in ["EffectPreviewKernels.ci", "default.ci", "default"] {
            if let url = Bundle.main.url(forResource: library, withExtension: "metallib"),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }()

    private static func previewKernel<K: CIKernel>(_ name: String) -> K? {
        guard let data = kernelLibrary else { return nil }
        return try? K(functionName: name, fromMetalLibraryData: data)
    }

    static func apply(
        _ effects: [SceneEffect], to source: CIImage, scale: Double,
        time: Double = 0, feedback: EffectPreviewFeedback? = nil
    ) -> CIImage {
        var current = source
        for (index, effect) in effects.enumerated() {
            var processed: CIImage
            switch effect.kind {
            case .warp(let amount, let noiseScale, let speed):

                let pixels = CGFloat(amount * scale)
                guard pixels >= 0.5, let kernel = warpKernel else { processed = current; break }
                let extent = current.extent
                let params = CIVector(
                    x: pixels, y: CGFloat(max(noiseScale * scale, 1)),
                    z: CGFloat(time * speed), w: extent.height
                )
                let warped = kernel.apply(
                    extent: extent,
                    roiCallback: { _, rect in rect.insetBy(dx: -pixels - 1, dy: -pixels - 1) },
                    image: current.clampedToExtent(),
                    arguments: [params]
                )
                processed = (warped ?? current).cropped(to: extent)
            case .scatter(let amount, let size, let speed, let smooth):
                let pixels = CGFloat(amount * scale)
                guard pixels >= 0.5, let kernel = scatterKernel else { processed = current; break }
                let extent = current.extent
                let roll = speed > 0.001 ? floor(time * 60 * speed) : 0
                let params = CIVector(
                    x: pixels, y: CGFloat(roll), z: CGFloat(max(size * scale, 1)), w: extent.height
                )
                let scattered = kernel.apply(
                    extent: extent,
                    roiCallback: { _, rect in rect.insetBy(dx: -pixels - 1, dy: -pixels - 1) },
                    image: current.clampedToExtent(),
                    arguments: [params, Float(smooth)]
                )
                processed = (scattered ?? current).cropped(to: extent)
            case .stainedGlass(let cellSize, let leading, let jitter, let speed):
                guard let kernel = stainedGlassKernel else { processed = current; break }
                let extent = current.extent
                let cellPx = CGFloat(max(cellSize * scale, 2))
                let params = CIVector(
                    x: cellPx, y: CGFloat(leading * scale), z: CGFloat(jitter), w: CGFloat(time * speed)
                )
                let panes = kernel.apply(
                    extent: extent,
                    roiCallback: { _, rect in rect.insetBy(dx: -cellPx * 2, dy: -cellPx * 2) },
                    arguments: [current.clampedToExtent(), params, Float(extent.height)]
                )
                processed = (panes ?? current).cropped(to: extent)
            case .grain(let amount, let size, let speed):
                guard let kernel = grainKernel else { processed = current; break }
                let extent = current.extent
                let roll = speed > 0.001 ? floor(time * 60 * speed) : 0
                let params = CIVector(
                    x: CGFloat(amount), y: CGFloat(max(size * scale, 1)), z: CGFloat(roll), w: extent.height
                )
                processed = kernel.apply(extent: extent, arguments: [current, params]) ?? current
            case .echo, .ghostTrails:
                guard let feedback else { processed = current; break }
                let fade: Double
                var driftField: (pixels: CGFloat, cell: CGFloat, phase: Double)?
                switch effect.kind {
                case .ghostTrails(let f, let drift, let fieldScale, let speed):
                    fade = f
                    driftField = (CGFloat(drift * scale), CGFloat(max(fieldScale * scale, 1)), time * speed)
                case .echo(let f): fade = f
                default: fade = 1
                }
                if var trail = feedback.trail(at: index, time: time, fade: fade, extent: current.extent) {
                    if let driftField, driftField.pixels >= 0.5, let kernel = warpKernel {

                        let extent = current.extent
                        let params = CIVector(
                            x: driftField.pixels, y: driftField.cell,
                            z: CGFloat(driftField.phase), w: extent.height
                        )
                        let pad = driftField.pixels + 1
                        trail = kernel.apply(
                            extent: extent,
                            roiCallback: { _, rect in rect.insetBy(dx: -pad, dy: -pad) },
                            image: trail.clampedToExtent(), arguments: [params, Float(0)]
                        )?.cropped(to: extent) ?? trail
                    }

                    let filter = CIFilter.lightenBlendMode()
                    filter.inputImage = current
                    filter.backgroundImage = trail
                    processed = filter.outputImage ?? current
                } else {
                    processed = current
                }
                feedback.store(processed, at: index, time: time)
            case .blur(let radius):
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = current.clampedToExtent()
                filter.radius = Float(max(0, radius * scale))
                processed = (filter.outputImage ?? current).cropped(to: current.extent)
            case .hueRotate(let degrees):
                let filter = CIFilter.hueAdjust()
                filter.inputImage = current
                filter.angle = Float(degrees * .pi / 180)
                processed = filter.outputImage ?? current
            case .invert:
                let filter = CIFilter.colorInvert()
                filter.inputImage = current
                processed = filter.outputImage ?? current
            case .posterize(let levels):
                let filter = CIFilter.colorPosterize()
                filter.inputImage = current
                filter.levels = Float(min(max(levels, 2), 32))
                processed = filter.outputImage ?? current
            case .pixelate(let size):
                let filter = CIFilter.pixellate()
                filter.inputImage = current.clampedToExtent()
                filter.scale = Float(max(size * scale, 1))
                filter.center = CGPoint(x: current.extent.midX, y: current.extent.midY)
                processed = (filter.outputImage ?? current).cropped(to: current.extent)
            case .vignette(let strength):

                let filter = CIFilter.vignette()
                filter.inputImage = current
                filter.intensity = Float(min(max(strength, 0), 1.5))
                filter.radius = 1.6
                processed = filter.outputImage ?? current
            case .colorAdjust(let brightness, let contrast, let saturation, let hue):
                if abs(hue) > 0.01 {
                    let rotate = CIFilter.hueAdjust()
                    rotate.inputImage = current
                    rotate.angle = Float(hue * .pi / 180)
                    current = rotate.outputImage ?? current
                }

                let k = 1.0 + contrast
                let s = saturation
                let luma = SIMD3(0.2126, 0.7152, 0.0722)
                let bias = CGFloat(0.5 - 0.5 * k + brightness)
                func row(_ channel: Int) -> CIVector {
                    var v = SIMD3(repeating: 0.0)
                    v[channel] = s
                    let mixed = v + (1 - s) * luma
                    return CIVector(
                        x: CGFloat(k * mixed.x), y: CGFloat(k * mixed.y),
                        z: CGFloat(k * mixed.z), w: 0
                    )
                }
                let filter = CIFilter.colorMatrix()
                filter.inputImage = current
                filter.rVector = row(0)
                filter.gVector = row(1)
                filter.bVector = row(2)
                filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
                filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
                processed = filter.outputImage ?? current
            case .glitch, .burn, .tint:

                processed = current
            }
            if effect.opacity < 0.999 {

                let faded = processed.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(effect.opacity)),
                ])
                current = faded.composited(over: current)
            } else {
                current = processed
            }
        }
        return current
    }

    static func still(_ image: CGImage, effects: [SceneEffect], scale: Double) -> CGImage? {
        guard !effects.isEmpty else { return image }
        let source = CIImage(cgImage: image)
        let out = apply(effects, to: source, scale: scale)
        return context.createCGImage(out, from: source.extent)
    }
}

extension String {

    init(fourCharCode: FourCharCode) {
        let bytes = [
            UInt8((fourCharCode >> 24) & 0xFF), UInt8((fourCharCode >> 16) & 0xFF),
            UInt8((fourCharCode >> 8) & 0xFF), UInt8(fourCharCode & 0xFF),
        ]
        let printable = bytes.allSatisfy { (0x20...0x7E).contains($0) }
        self = printable
            ? String(decoding: bytes, as: UTF8.self)
            : String(fourCharCode)
    }
}

private struct VideoPreviewSurface: NSViewRepresentable {
    let player: AVPlayer

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

struct MediaEditorView: View {
    let model: AppModel
    let entry: LibraryIndex.Entry

    @State private var preview = MediaPreviewPlayer()

    @State private var baseStill: CGImage?
    @State private var stillImage: CGImage?
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    @State private var effectScrubbing = false

    @State private var transitionScrubbing = false
    @State private var presetNamePrompt = false
    @State private var presetNameDraft = ""

    @AppStorage("editor.inspectorWidth") private var inspectorWidth = PanelWidthGrip.minPanelWidth

    @State private var cachedMedia: MediaItem?
    @State private var cachedAudio: AudioItem?

    @State private var loadedHash: String?

    private var fileHash: String? {
        cachedMedia?.fileHash ?? cachedAudio?.fileHash
    }
    private var isVideo: Bool { cachedMedia?.mediaKind == .video }
    private var isTimeBased: Bool { isVideo || entry.kind == .audio }

    var body: some View {
        HStack(spacing: CornerStandard.panelInset) {
            VStack(spacing: 0) {

                Color.clear
                    .frame(height: ShellView.headerHeight - CornerStandard.panelInset)
                previewArea
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 0) {

                Color.clear
                    .frame(height: ShellView.headerHeight - CornerStandard.panelInset)
                settingsPanel
            }

            .frame(width: max(inspectorWidth, PanelWidthGrip.minPanelWidth))
            .floatingPanel()
            .overlay(alignment: .leading) {
                PanelWidthGrip(width: $inspectorWidth)
            }
        }
        .navigationTitle(entry.name)
        .task(id: entry.id) {
            nameDraft = entry.name
            await refresh(reloadMedia: true)
        }

        .onChange(of: model.listVersion) {
            Task { await refresh(reloadMedia: false) }
        }
        .onDisappear { preview.teardown() }
        .alert("New Effect Preset", isPresented: $presetNamePrompt) {
            TextField("Name", text: $presetNameDraft)
            Button("Save") {
                let name = presetNameDraft.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    model.saveEffectPreset(name: name, effects: cachedMedia?.effects ?? [])
                }
                presetNameDraft = ""
            }
            Button("Cancel", role: .cancel) { presetNameDraft = "" }
        }
    }

    private func refresh(reloadMedia: Bool) async {

        await model.resident.ready([entry.kind])
        switch entry.kind {
        case .media: cachedMedia = model.media(entry.id)
        case .audio: cachedAudio = model.audio(entry.id)
        default: break
        }
        let hash = fileHash
        if reloadMedia || hash != loadedHash {
            loadedHash = hash
            baseStill = nil
            stillImage = nil
            if let hash, let url = model.blobs?.url(forHash: hash) {
                if isTimeBased {
                    await preview.load(url: url)
                } else {
                    baseStill = await Self.downsampledStill(url: url)
                }
            }
        }
        applyPreviewShaping()
    }

    private func applyPreviewShaping() {
        let canvasWidth = Double(SlideSceneBuilder.canvasSize.width)
        let effects = SlideSceneBuilder.sceneEffects(cachedMedia?.effects)
        if isTimeBased {
            let inPoint = max(trimIn ?? 0, 0)
            let outPoint = min(trimOut ?? preview.duration, preview.duration)
            preview.trimWindow =
                (inPoint > 0.05 || outPoint < preview.duration - 0.05) && outPoint > inPoint
                    ? inPoint ... outPoint : nil
            preview.playRate = cachedMedia?.playRate ?? 1
            if isVideo {
                preview.applyEffects(effects, canvasWidth: canvasWidth)
            }
        }
        if let baseStill {
            stillImage = EffectPreviewRenderer.still(
                baseStill, effects: effects,
                scale: Double(baseStill.width) / canvasWidth
            ) ?? baseStill
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        ZStack {

            Rectangle().fill(.black)
            if isVideo {
                VideoPreviewSurface(player: preview.player)
            } else if let stillImage {
                Image(decorative: stillImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if entry.kind == .audio {
                audioIdentity
            } else {
                ProgressView()
            }
        }

        .overlay(alignment: .bottom) {
            if isTimeBased {
                TransportPill(
                    preview: preview, trimRange: editorTrimRange,
                    onTrimChange: { range, final in

                        guard final, preview.duration > 0 else { return }
                        let duration = preview.duration
                        let inPoint: Double? = range.lowerBound * duration > 0.05
                            ? tidy(range.lowerBound * duration) : nil
                        let outPoint: Double? = range.upperBound * duration < duration - 0.05
                            ? tidy(range.upperBound * duration) : nil
                        writeTrim(inPoint: .some(inPoint), outPoint: .some(outPoint))
                    }
                )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color.black.opacity(0.55),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .clipShape(RoundedRectangle.standard(CornerStandard.panel))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, CornerStandard.panelInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var audioIdentity: some View {
        VStack(spacing: 10) {
            Glyph(kind: .audio, size: 44)
                .foregroundStyle(.secondary)
            Text(entry.name)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if preview.duration > 0 {
                Text(Self.timecode(preview.duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private struct TransportPill: View {
        let preview: MediaPreviewPlayer
        var trimRange: ClosedRange<Double>?
        var onTrimChange: ((ClosedRange<Double>, Bool) -> Void)?

        var body: some View {
            HStack(spacing: 12) {
                Button {
                    preview.togglePlay()
                } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(preview.duration <= 0)
                .help(preview.isPlaying ? "Pause preview" : "Play preview")
                ScrubBar(
                    elapsed: preview.elapsed,
                    duration: preview.duration,
                    isPlaying: preview.isPlaying,
                    showsTimes: true,
                    trimRange: trimRange,
                    onTrimChange: onTrimChange,

                    liveSeekInterval: .milliseconds(33)
                ) { seconds, final in
                    preview.seek(to: seconds, final: final)
                }
            }
        }
    }

    private var settingsPanel: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $nameDraft)
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            }
            if let item = cachedMedia {
                mediaSections(item)
            } else if cachedAudio != nil {
                audioSections()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func mediaSections(_ item: MediaItem) -> some View {
        Section("Behavior") {

            Picker("Classification", selection: mediaBinding(item, \.classification)) {
                Text("Background").tag(MediaClassification.background)
                Text("Foreground").tag(MediaClassification.foreground)
            }
            if item.mediaKind == .video {
                Toggle("Loops", isOn: mediaBinding(item, \.loops))
                playRatePicker(item)
            }
            transitionRows
        }
        if item.mediaKind == .video {
            trimSection
        }
        mediaEffectsSection(item)
        Section("Organization") {
            Toggle("Favorite", isOn: mediaBinding(item, \.favorite))
            TagsField(tags: mediaBinding(item, \.tags))
        }
        Section("File") {
            LabeledContent("Kind", value: item.mediaKind.rawValue.capitalized)
            LabeledContent("Original name", value: item.fileName)
            if let w = item.pixelWidth, let h = item.pixelHeight {
                LabeledContent("Dimensions", value: "\(w) × \(h)")
            }
            if let duration = item.durationSeconds {
                LabeledContent("Duration", value: Self.timecode(duration))
            }
            if let fps = preview.frameRate, fps > 0 {
                LabeledContent("Frame rate", value: String(format: "%.3g fps", fps))
            }
            if let codec = preview.codec {
                LabeledContent("Codec", value: codec)
            }
            fileStatusRow(item)
            replaceFileButton(item)
            showInFinderButton
        }
    }

    @ViewBuilder
    private func audioSections() -> some View {
        trimSection
        Section("Organization") {
            Toggle("Favorite", isOn: Binding(
                get: { cachedAudio?.favorite ?? false },
                set: { v in
                    cachedAudio?.favorite = v
                    model.updateAudio(entry.id) { $0.favorite = v }
                }
            ))
            TagsField(tags: Binding(
                get: { cachedAudio?.tags ?? [] },
                set: { v in
                    cachedAudio?.tags = v
                    model.updateAudio(entry.id) { $0.tags = v }
                }
            ))
        }
        Section("File") {
            if let item = cachedAudio {
                LabeledContent("Original name", value: item.fileName)
                if let duration = item.durationSeconds {
                    LabeledContent("Duration", value: Self.timecode(duration))
                }
            }
            showInFinderButton
        }
    }

    @ViewBuilder
    private func fileStatusRow(_ item: MediaItem) -> some View {
        LabeledContent("Status") {

            if model.isMediaFileMissing(item) {
                Text("Missing — the file isn't on this Mac").foregroundStyle(.red)
            } else {
                switch item.fileStatus {
                case .ready: Text("Ready").foregroundStyle(.green)
                case .needsTranscode:
                    Text("Needs transcode — \(item.statusDetail)").foregroundStyle(.orange)
                case .transcoding: Text("Transcoding…")
                case .transcodeFailed:
                    Text("Transcode failed — \(item.statusDetail)").foregroundStyle(.red)
                }
            }
        }
        if item.fileStatus == .needsTranscode || item.fileStatus == .transcodeFailed,
           !model.isMediaFileMissing(item) {
            Button("Transcode Now") {
                Task { _ = await model.transcodeQueue?.transcode(itemID: item.id) }
            }
            .disabled(model.isTranscoding)
        }
    }

    private func replaceFileButton(_ item: MediaItem) -> some View {
        Button("Replace Media File…") {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.image, .movie]
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    if let carried = await model.replaceMediaFile(item.id, with: url) {
                        MediaRelinkAlerts.carriedSettingsWarning(itemName: item.name, carried: carried)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var showInFinderButton: some View {
        if let fileHash {
            if let url = model.blobs?.url(forHash: fileHash) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else {

                Button("Show in Finder") {}
                    .disabled(true)
                    .help("The file isn't on this Mac.")
            }
        }
    }

    @ViewBuilder
    private func mediaEffectsSection(_ item: MediaItem) -> some View {
        let effects = cachedMedia?.effects ?? []
        Section("Effects") {
            ForEach(Array(effects.enumerated()), id: \.offset) { index, effect in
                HStack {

                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Toggle("", isOn: Binding(
                        get: { (cachedMedia?.effects?[safe: index]?.enabled) ?? true },
                        set: { on in
                            writeEffects { effects in
                                guard effects.indices.contains(index) else { return }
                                effects[index].enabled = on ? nil : false
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(.green)
                    .help("Bypass keeps the effect's settings")
                    Text(effect.effectKind.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(effect.enabled ?? true ? .primary : .tertiary)
                    Spacer()
                    Button {
                        writeEffects { effects in
                            guard effects.indices.contains(index) else { return }
                            effects.remove(at: index)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this effect")
                }
                .contentShape(Rectangle())
                .draggable("fx:media:\(index)")
                .dropDestination(for: String.self) { payloads, _ in
                    guard let source = Self.effectDragIndex(payloads, prefix: "fx:media:")
                    else { return false }
                    moveEffect(from: source, to: index)
                    return true
                }
                switch effect.effectKind {
                case .blur:
                    effectNumber("Radius", index: index, \.radius, default: 12, range: 0 ... 200)
                case .colorAdjust:
                    effectNumber(
                        "Hue", index: index, \.hue, default: 0,
                        range: -180 ... 180, step: 1
                    )
                    effectNumber(
                        "Brightness", index: index, \.brightness, default: 0,
                        range: -1 ... 1, step: 0.02
                    )
                    effectNumber(
                        "Contrast", index: index, \.contrast, default: 0,
                        range: -1 ... 1, step: 0.02
                    )
                    effectNumber(
                        "Saturation", index: index, \.saturation, default: 1,
                        range: 0 ... 2, step: 0.02
                    )
                default:
                    if let control = effect.effectKind.amountControl {
                        effectNumber(
                            control.label, index: index, \.amount,
                            default: control.fallback, range: control.range, step: control.step
                        )
                    }
                    ForEach(effect.effectKind.extraControls) { control in
                        effectNumber(
                            control.label, index: index, control.keyPath,
                            default: control.fallback, range: control.range, step: control.step
                        )
                    }
                }
                effectNumber("Mix", index: index, \.opacity, default: 1, range: 0 ... 1, step: 0.02)
            }
            HStack {
                Menu("Add Effect") {
                    ForEach(EffectKind.addable, id: \.self) { kind in
                        Button(kind.displayName) {
                            writeEffects { $0.append(kind.freshEffect) }
                        }
                    }
                }
                Spacer()
                EffectPresetsMenu(
                    model: model, currentChain: effects,
                    apply: { chain in writeEffects { $0 = chain } },
                    add: { chain in writeEffects { $0.append(contentsOf: chain) } },
                    presetNamePrompt: $presetNamePrompt
                )
            }
        }
    }

    private func moveEffect(from source: Int, to target: Int) {
        writeEffects { effects in
            guard effects.indices.contains(source), source != target else { return }
            let moved = effects.remove(at: source)
            effects.insert(moved, at: target > source ? target - 1 : target)
        }
    }

    static func effectDragIndex(_ payloads: [String], prefix: String) -> Int? {
        guard let payload = payloads.first, payload.hasPrefix(prefix) else { return nil }
        return Int(payload.dropFirst(prefix.count))
    }

    private func effectNumber(
        _ label: String, index: Int, _ keyPath: WritableKeyPath<Effect, Double?>,
        default fallback: Double, range: ClosedRange<Double>, step: Double = 1
    ) -> some View {

        BoundedSliderRow(
            label: label,
            value: Binding(
                get: { cachedMedia?.effects?[safe: index]?[keyPath: keyPath] ?? fallback },
                set: { value in
                    writeEffects(commit: !effectScrubbing) { effects in
                        guard effects.indices.contains(index) else { return }
                        effects[index][keyPath: keyPath] = value
                    }
                }
            ),
            range: range, step: step,
            onScrubPhase: { began in effectScrubbing = began }
        )
    }

    private func writeEffects(commit: Bool = true, _ mutate: (inout [Effect]) -> Void) {
        var effects = cachedMedia?.effects ?? []
        mutate(&effects)
        let stored: [Effect]? = effects.isEmpty ? nil : effects
        cachedMedia?.effects = stored
        if commit {
            model.updateMedia(entry.id) { $0.effects = stored }
        } else {
            applyPreviewShaping()
        }
    }

    private var trimIn: Double? { cachedMedia?.inPoint ?? cachedAudio?.inPoint }
    private var trimOut: Double? { cachedMedia?.outPoint ?? cachedAudio?.outPoint }

    private var editorTrimRange: ClosedRange<Double>? {
        guard preview.duration > 0 else { return nil }
        let inP = max(trimIn ?? 0, 0)
        let outP = min(trimOut ?? preview.duration, preview.duration)
        guard inP > 0.05 || outP < preview.duration - 0.05, outP > inP else { return nil }
        return (inP / preview.duration) ... (outP / preview.duration)
    }

    private var trimSection: some View {
        Section("Trim") {
            LabeledContent("In Point") {
                trimControls(
                    value: trimIn,
                    set: {
                        let t = tidy(preview.elapsed)

                        if let out = trimOut, t >= out { writeTrim(inPoint: t, outPoint: .some(nil)) }
                        else { writeTrim(inPoint: t) }
                    },
                    clear: { writeTrim(inPoint: .some(nil)) }
                )
            }
            LabeledContent("Out Point") {
                trimControls(
                    value: trimOut,
                    set: {
                        let t = tidy(preview.elapsed)
                        guard t > (trimIn ?? 0) + 0.05 else { return }
                        writeTrim(outPoint: t)
                    },
                    clear: { writeTrim(outPoint: .some(nil)) }
                )
            }
            if trimIn != nil || trimOut != nil, preview.duration > 0 {
                let length = min(trimOut ?? preview.duration, preview.duration) - max(trimIn ?? 0, 0)
                let rate = cachedMedia?.playRate ?? 1
                LabeledContent(
                    "Plays",
                    value: Self.timecode(max(0, length) / max(rate, 0.01))
                )
            }
        }
    }

    private func trimControls(
        value: Double?, set: @escaping () -> Void, clear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(value.map(Self.preciseTimecode) ?? "—")
                .font(.body.monospacedDigit())
                .foregroundStyle(value == nil ? .tertiary : .primary)
            Button("Set") { set() }
                .help("Set at the preview playhead")
            if value != nil {
                Button {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
    }

    private func writeTrim(inPoint: Double?? = nil, outPoint: Double?? = nil) {
        if entry.kind == .media {
            if let inPoint { cachedMedia?.inPoint = inPoint }
            if let outPoint { cachedMedia?.outPoint = outPoint }
            model.updateMedia(entry.id) {
                if let inPoint { $0.inPoint = inPoint }
                if let outPoint { $0.outPoint = outPoint }
            }
        } else {
            if let inPoint { cachedAudio?.inPoint = inPoint }
            if let outPoint { cachedAudio?.outPoint = outPoint }
            model.updateAudio(entry.id) {
                if let inPoint { $0.inPoint = inPoint }
                if let outPoint { $0.outPoint = outPoint }
            }
        }
    }

    @ViewBuilder
    private var transitionRows: some View {
        let transition = cachedMedia?.transition
        Picker("Transition", selection: Binding(
            get: { transition?.transitionKind.rawValue ?? "" },
            set: { raw in
                let stored: MediaTransition? = TransitionKind(rawValue: raw).map {
                    MediaTransition(
                        transitionKind: $0,
                        durationSeconds: transition?.durationSeconds,
                        colorHex: transition?.colorHex
                    )
                }
                cachedMedia?.transition = stored
                model.updateMedia(entry.id) { $0.transition = stored }
            }
        )) {
            Text("Cut").tag("")
            Text("Dissolve").tag(TransitionKind.dissolve.rawValue)
            Text("Fade Black").tag(TransitionKind.fadeBlack.rawValue)
            Text("Fade White").tag(TransitionKind.fadeWhite.rawValue)
            Text("Fade Color").tag(TransitionKind.fadeColor.rawValue)
            Text("Blur Dissolve").tag(TransitionKind.blurDissolve.rawValue)
            Text("Film Burn").tag(TransitionKind.filmBurn.rawValue)
        }
        if let transition, transition.transitionKind != .cut {
            BoundedSliderRow(
                label: "Duration",
                value: Binding(
                    get: { cachedMedia?.transition?.durationSeconds ?? 0.5 },
                    set: { v in
                        cachedMedia?.transition?.durationSeconds = v
                        if !transitionScrubbing {
                            model.updateMedia(entry.id) { $0.transition?.durationSeconds = v }
                        }
                    }
                ),
                range: 0 ... 5, step: 0.05,
                onScrubPhase: { began in transitionScrubbing = began }
            )
            if transition.transitionKind == .fadeColor {

                CommittedTextField("Plate Color (hex)", text: Binding(
                    get: { cachedMedia?.transition?.colorHex ?? "#000000" },
                    set: { v in
                        cachedMedia?.transition?.colorHex = v
                        model.updateMedia(entry.id) { $0.transition?.colorHex = v }
                    }
                ))
            }
        }
    }

    private static let rateChoices: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    private func playRatePicker(_ item: MediaItem) -> some View {
        Picker("Play Rate", selection: Binding(
            get: { cachedMedia?.playRate ?? 1 },
            set: { v in

                let stored: Double? = v == 1 ? nil : v
                cachedMedia?.playRate = stored
                model.updateMedia(item.id) { $0.playRate = stored }
            }
        )) {
            ForEach(Self.rateChoices, id: \.self) { rate in
                Text(rate == 1 ? "Normal" : String(format: "%g×", rate)).tag(rate)
            }
        }
    }

    private func tidy(_ seconds: Double) -> Double {
        (seconds * 100).rounded() / 100
    }

    private static func preciseTimecode(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }

    private func mediaBinding<T: Equatable & Sendable>(
        _ item: MediaItem, _ keyPath: WritableKeyPath<MediaItem, T> & Sendable
    ) -> Binding<T> {
        Binding(
            get: { cachedMedia?[keyPath: keyPath] ?? item[keyPath: keyPath] },
            set: { newValue in
                cachedMedia?[keyPath: keyPath] = newValue
                model.updateMedia(item.id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != entry.name else {
            nameDraft = entry.name
            return
        }
        model.rename(entry, to: trimmed)
    }

    private nonisolated static func downsampledStill(url: URL) async -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
