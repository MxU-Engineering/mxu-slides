import AppKit
import AVFoundation
import ImageIO
import PresenterCore
import RenderEngine
import SlideScene
import UniformTypeIdentifiers

@MainActor
@Observable
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private(set) var placeholdersReady = false

    func markPlaceholdersReady() { placeholdersReady = true }

    static let contentSize = (width: ThumbnailResolution.base, height: 270)

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let largeImageLimit = 384 * 1024 * 1024

    private static func cost(of image: CGImage, large: Bool) -> Int {
        large ? image.bytesPerRow * image.height : 0
    }

    private static func boundedCache() -> NSCache<NSString, Box> {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = largeImageLimit
        return cache
    }

    private let posters = boundedCache()
    private let contents = boundedCache()
    private var postersInFlight: [String: Task<CGImage?, Never>] = [:]
    private let faceValues = NSCache<NSString, AnyObject>()

    var posterDisk: MediaPosterStore?

    func faceValue<Entity: DocumentEntity & Sendable>(
        _ type: Entity.Type, id: String, updatedAt: TimeInterval, client: LibraryClient
    ) async -> Entity? {
        let key = "\(Entity.documentKind.rawValue)|\(id)|\(updatedAt)" as NSString
        if let hit = faceValues.object(forKey: key) as? FaceBox<Entity> { return hit.value }
        let value = try? await client.loadValue(type, id: id)
        if let value { faceValues.setObject(FaceBox(value), forKey: key) }
        return value
    }

    func cachedFaceValue<Entity: DocumentEntity & Sendable>(
        _ type: Entity.Type, id: String, updatedAt: TimeInterval
    ) -> Entity? {
        let key = "\(Entity.documentKind.rawValue)|\(id)|\(updatedAt)" as NSString
        return (faceValues.object(forKey: key) as? FaceBox<Entity>)?.value
    }

    private final class FaceBox<Entity> {
        let value: Entity
        init(_ value: Entity) { self.value = value }
    }

    func slideContent(
        slide: Slide,
        theme: Theme?,
        render: RenderContext?,
        model: AppModel?,
        canvas: CGSize = SlideSceneBuilder.canvasSize,
        cacheKey baseKey: String,
        identity: String? = nil,
        pixelWidth: Int = ThumbnailResolution.base,
        mediaEffects: (String) -> [SceneEffect] = { _ in [] }
    ) -> CGImage? {
        let large = pixelWidth > ThumbnailResolution.base
        let cacheKey = large ? "\(baseKey)|w\(pixelWidth)" : baseKey

        _ = thumbStillsVersion
        _ = contentsVersion
        _ = placeholdersReady
        if let hit = contents.object(forKey: cacheKey as NSString) { return hit.image }
        guard let compositor = render?.compositor else { return nil }

        let provisional = provisionalContents[cacheKey]
        let provisionalStale = provisional.map {
            $0.stillsVersion != thumbStillsVersion || $0.placeholdersReady != placeholdersReady
        } ?? true
        guard provisionalStale, !contentsInFlight.contains(cacheKey) else {
            return provisional?.image ?? lastFrame(identity)
        }

        var usedPlaceholder = false
        var pendingStill = false

        let built = SlideSceneBuilder.peakLook(SlideSceneBuilder.scene(
            for: slide, theme: theme, canvasSize: canvas, animationContext: .settled
        ))

            .applyingMediaEffects(mediaEffects)

        let slideLayerMedia = Self.mediaIDs(onSlideLayerOf: built)
        let scene = built.remappingMediaIDs { id in
            if let placeholder = LiveInputPlaceholder.remap(id) {
                usedPlaceholder = true
                return placeholder
            }
            guard slideLayerMedia.contains(id) else { return id }

            let stillID = Self.thumbStillID(id, pixelWidth: pixelWidth)
            if thumbStillIsCurrent(stillID, mediaID: id, pixelWidth: pixelWidth, render: render, model: model) {
                return stillID
            } else {

                pendingStill = true
                registerThumbStill(id: id, pixelWidth: pixelWidth, render: render, model: model)
                let smallID = Self.thumbStillID(id, pixelWidth: ThumbnailResolution.base)
                return large && thumbStillIsCurrent(
                    smallID, mediaID: id, pixelWidth: ThumbnailResolution.base, render: render, model: model
                ) ? smallID : id
            }
        }

        let height = max(1, Int((CGFloat(pixelWidth) * canvas.height
            / max(1, canvas.width)).rounded()))
        contentsInFlight.insert(cacheKey)
        let mediaFilesAtBuild = mediaFilesGeneration
        let stillsVersionAtBuild = thumbStillsVersion
        let readyAtBuild = placeholdersReady
        let width = pixelWidth

        let usedPlaceholderAtBuild = usedPlaceholder
        let pendingStillAtBuild = pendingStill
        Self.renderQueue.async {
            let frame = try? compositor.renderFrame(
                scene: scene, width: width, height: height,
                transparentBackground: true
            )
            Task { @MainActor in
                ThumbnailStore.shared.landContent(
                    key: cacheKey, identity: identity, frame: frame, large: large,
                    usedPlaceholder: usedPlaceholderAtBuild, pendingStill: pendingStillAtBuild,
                    stillsVersionAtBuild: stillsVersionAtBuild, readyAtBuild: readyAtBuild,
                    mediaFilesAtBuild: mediaFilesAtBuild
                )
            }
        }
        return provisional?.image ?? lastFrame(identity)
    }

    private let lastFrames = boundedCache()

    private func lastFrame(_ identity: String?) -> CGImage? {
        identity.flatMap { lastFrames.object(forKey: $0 as NSString)?.image }
    }

    private nonisolated static let renderQueue = DispatchQueue(
        label: "com.example.mxuslides.thumbnails", qos: .userInitiated
    )

    private struct ProvisionalContent {
        let image: CGImage
        let stillsVersion: Int
        let placeholdersReady: Bool
    }

    @ObservationIgnored private var provisionalContents: [String: ProvisionalContent] = [:]
    @ObservationIgnored private var contentsInFlight: Set<String> = []

    private(set) var contentsVersion = 0
    @ObservationIgnored private var contentsBumpScheduled = false

    private func scheduleContentsBump() {
        guard !contentsBumpScheduled else { return }
        contentsBumpScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            MainActor.assumeIsolated {
                let store = ThumbnailStore.shared
                store.contentsBumpScheduled = false
                store.contentsVersion += 1
            }
        }
    }

    private func landContent(
        key: String, identity: String?, frame: RenderedFrame?, large: Bool,
        usedPlaceholder: Bool, pendingStill: Bool,
        stillsVersionAtBuild: Int, readyAtBuild: Bool, mediaFilesAtBuild: Int
    ) {
        contentsInFlight.remove(key)

        guard let image = frame?.cgImage, mediaFilesAtBuild == mediaFilesGeneration else { return }

        if (!usedPlaceholder || readyAtBuild), !pendingStill {
            contents.setObject(Box(image), forKey: key as NSString, cost: Self.cost(of: image, large: large))
            provisionalContents.removeValue(forKey: key)

            if let identity {
                lastFrames.setObject(Box(image), forKey: identity as NSString, cost: Self.cost(of: image, large: large))
            }
        } else {

            if provisionalContents.count > 256 { provisionalContents.removeAll() }
            provisionalContents[key] = ProvisionalContent(
                image: image, stillsVersion: stillsVersionAtBuild,
                placeholdersReady: readyAtBuild
            )
        }
        scheduleContentsBump()
    }

    @ObservationIgnored private var backgroundMaps:
        [String: [String: (media: CueMedia, source: SlideSceneBuilder.BackgroundSource)]] = [:]

    func backgroundSource(
        slideID: String, presentation: Presentation?, arrangementId: String?, stamp: String
    ) -> (media: CueMedia, source: SlideSceneBuilder.BackgroundSource)? {
        guard let presentation else { return nil }
        let key = "\(presentation.id)|\(stamp)|\(arrangementId ?? "")"
        if let hit = backgroundMaps[key] { return hit[slideID] }
        let map = SlideSceneBuilder.backgroundSources(
            for: presentation, arrangementId: arrangementId
        )
        if backgroundMaps.count > 32 { backgroundMaps.removeAll() }
        backgroundMaps[key] = map
        return map[slideID]
    }

    @ObservationIgnored private var carriedMaps: [String: [String: [LayerKind: String]]] = [:]

    func carriedMedia(
        slideID: String, presentation: Presentation?, arrangementId: String?, stamp: String,
        model: AppModel
    ) -> [LayerKind: String] {
        guard let presentation else { return [:] }
        let key = "\(presentation.id)|\(stamp)|\(arrangementId ?? "")|\(model.version(of: .media))|\(model.fillVersion(of: .media))"
        if let hit = carriedMaps[key] { return hit[slideID] ?? [:] }
        let map = SlideSceneBuilder.carriedMediaMap(for: presentation, arrangementId: arrangementId) { id in
            model.media(id).map { ($0.mediaKind, $0.classification) }
        }
        if carriedMaps.count > 32 { carriedMaps.removeAll() }
        carriedMaps[key] = map
        return map[slideID] ?? [:]
    }

    static let thumbMediaPrefix = "thumb::"

    static func thumbStillID(_ id: String, pixelWidth: Int) -> String {
        pixelWidth > ThumbnailResolution.base
            ? "\(thumbMediaPrefix)w\(pixelWidth)::\(id)" : thumbMediaPrefix + id
    }

    private var thumbStillsInFlight = Set<String>()

    @ObservationIgnored private var thumbStillKeys: [String: String] = [:]

    @ObservationIgnored private var mediaFilesGeneration = 0

    func mediaFileChanged() {
        mediaFilesGeneration += 1
        contents.removeAllObjects()
        provisionalContents.removeAll()
        contentsVersion += 1
    }

    private func thumbStillIsCurrent(
        _ stillID: String, mediaID: String, pixelWidth: Int, render: RenderContext?, model: AppModel?
    ) -> Bool {
        let resident = render?.media.hasStill(id: stillID) == true
        if resident, let item = model?.media(mediaID) {
            return thumbStillKeys[stillID] == posterKey(
                item, maxPixels: ThumbnailResolution.posterPixels(forWidth: pixelWidth))
        } else {
            return resident
        }
    }

    private(set) var thumbStillsVersion = 0

    private static func mediaIDs(onSlideLayerOf scene: RenderScene) -> Set<String> {
        var ids: Set<String> = []
        for layer in scene.layers where layer.kind == .slide {
            for item in layer.items {
                if case .media(let id, _, _) = item.content { ids.insert(id) }
                if case .shape(let style) = item.content,
                   case .media(let id, _, _) = style.fill { ids.insert(id) }
            }
        }
        return ids
    }

    private func registerThumbStill(id: String, pixelWidth: Int, render: RenderContext?, model: AppModel?) {
        let stillID = Self.thumbStillID(id, pixelWidth: pixelWidth)
        let maxPixels = ThumbnailResolution.posterPixels(forWidth: pixelWidth)
        guard let render, let model, let blobs = model.blobs,
              !thumbStillsInFlight.contains(stillID)
        else { return }
        thumbStillsInFlight.insert(stillID)
        Task {
            defer { thumbStillsInFlight.remove(stillID) }

            await model.resident.ready([.media])

            guard let item = model.media(id),
                  let poster = await poster(for: item, blobs: blobs, maxPixels: maxPixels)
            else { return }
            let key = posterKey(item, maxPixels: maxPixels)
            guard (try? await render.media.showStill(
                image: poster,
                cacheKey: key,
                id: stillID
            )) != nil else { return }
            thumbStillKeys[stillID] = key
            thumbStillsVersion += 1
        }
    }

    func cachedPoster(for item: MediaItem, maxPixels: Int = PosterDecode.maxPixelSize) -> CGImage? {
        posters.object(forKey: posterKey(item, maxPixels: maxPixels) as NSString)?.image
    }

    func poster(
        for item: MediaItem, blobs: BlobStore, priority: TaskPriority = .userInitiated,
        maxPixels: Int = PosterDecode.maxPixelSize
    ) async -> CGImage? {
        let large = maxPixels > PosterDecode.maxPixelSize
        let key = posterKey(item, maxPixels: maxPixels)
        if let hit = posters.object(forKey: key as NSString) { return hit.image }
        if let inFlight = postersInFlight[key] {
            return await inFlight.value
        }
        guard let url = blobs.url(forHash: item.fileHash) else {

            guard let diskURL = posterDisk?.anyPosterURL(id: item.id) else { return nil }
            let image = await Task.detached(priority: priority) {
                Self.downsampledImage(url: diskURL)
            }.value
            if let image { posters.setObject(Box(image), forKey: key as NSString, cost: Self.cost(of: image, large: large)) }
            return image
        }
        let kind = item.mediaKind
        let inPoint = item.inPoint ?? 0
        let diskPoster = posterDisk.map {
            $0.posterURL(id: item.id, fingerprint: MediaPosterStore.fingerprint(
                fileHash: item.fileHash, inPoint: item.inPoint
            ))
        }

        let extraction = Task.detached(priority: priority) { () -> CGImage? in
            switch kind {
            case .image:
                await Self.imageDecodes.withPermit {
                    PosterDecode.image(original: url, diskPoster: diskPoster, maxPixelSize: maxPixels)
                }
            case .video: await Self.videoPoster(url: url, at: inPoint, maxPixels: maxPixels)
            }
        }
        postersInFlight[key] = extraction
        let image = await extraction.value
        postersInFlight[key] = nil
        if let image {
            posters.setObject(Box(image), forKey: key as NSString, cost: Self.cost(of: image, large: large))
            if !large { persistPoster(image, for: item) }
        }
        return image
    }

    private func persistPoster(_ image: CGImage, for item: MediaItem) {
        guard let posterDisk else { return }
        let fingerprint = MediaPosterStore.fingerprint(fileHash: item.fileHash, inPoint: item.inPoint)
        let destination = posterDisk.posterURL(id: item.id, fingerprint: fingerprint)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let id = item.id
        Task.detached(priority: .utility) {
            guard let data = Self.jpegData(image) else { return }
            try? posterDisk.writePoster(data, id: id, fingerprint: fingerprint)
        }
    }

    func cachedSlideContent(cacheKey: String) -> CGImage? {
        contents.object(forKey: cacheKey as NSString)?.image
    }

    nonisolated static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    func tombstonePoster(id: String) async -> CGImage? {
        let key = "tombstone|\(id)"
        if let hit = posters.object(forKey: key as NSString) { return hit.image }
        guard let url = posterDisk?.anyPosterURL(id: id) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            Self.downsampledImage(url: url)
        }.value
        if let image { posters.setObject(Box(image), forKey: key as NSString) }
        return image
    }

    private func posterKey(_ item: MediaItem, maxPixels: Int = PosterDecode.maxPixelSize) -> String {
        let key = "\(item.id)|\(item.fileHash)|\(item.inPoint ?? 0)"
        return maxPixels > PosterDecode.maxPixelSize ? "\(key)|\(maxPixels)" : key
    }

    private nonisolated static let imageDecodes = AsyncLimiter(limit: 2)

    private nonisolated static func downsampledImage(url: URL) -> CGImage? {
        PosterDecode.downsampled(url: url)
    }

    nonisolated static func filePoster(url: URL) async -> CGImage? {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return if type.conforms(to: .image) {
            await Task.detached(priority: .userInitiated) { downsampledImage(url: url) }.value
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            await videoPoster(url: url, at: 0, maxPixels: PosterDecode.maxPixelSize)
        } else {
            nil
        }
    }

    private nonisolated static func videoPoster(url: URL, at seconds: Double, maxPixels: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)

        let time = CMTime(seconds: max(seconds, 0.1), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
