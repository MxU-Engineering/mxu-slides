import Foundation
import RenderEngine

public enum TransportOrigin: Int, Sendable, Equatable, Comparable {
    case backgroundCue = 0
    case backgroundServiceItem
    case foregroundCue
    case foregroundServiceItem
    case slides
    case overlays
    case alerts

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TransportCandidate: Sendable, Equatable {
    public var mediaID: String

    public var layerID: String
    public var origin: TransportOrigin
    public var isLooping: Bool
    public var firedAt: Date

    public init(
        mediaID: String, layerID: String, origin: TransportOrigin,
        isLooping: Bool, firedAt: Date
    ) {
        self.mediaID = mediaID
        self.layerID = layerID
        self.origin = origin
        self.isLooping = isLooping
        self.firedAt = firedAt
    }
}

public enum TransportTarget {

    public static let defaultLayer = LayerKind.videos.rawValue

    public static let simultaneityWindow: TimeInterval = 1.0

    public static func resolve(
        candidates: [TransportCandidate],
        viewedLayer: String = defaultLayer,
        pinnedID: String? = nil,
        preferNonLooping: Bool = true
    ) -> TransportCandidate? {
        if let pinnedID, let pinned = candidates.first(where: { $0.mediaID == pinnedID }) {
            return pinned
        }
        var pool = candidates.filter { $0.layerID == viewedLayer }
        if preferNonLooping, pool.contains(where: { !$0.isLooping }) {
            pool.removeAll(where: \.isLooping)
        }

        guard let earliest = pool.map(\.firedAt).min() else { return nil }
        let contenders = pool.filter {
            $0.firedAt.timeIntervalSince(earliest) <= simultaneityWindow
        }
        var best: TransportCandidate?
        for candidate in contenders {

            if best == nil || candidate.origin > best!.origin {
                best = candidate
            }
        }
        return best
    }

    public static func pickerLayers(stack: [RenderLayer], carrying: Set<String>) -> [RenderLayer] {
        let fixed: Set<LayerKind> = [.alerts, .overlays, .slide, .videos, .loopingVideos]
        return stack.filter { layer in
            layer.kind.map(fixed.contains) == true || carrying.contains(layer.id)
        }
    }

    public static func countdownTarget(
        candidates: [TransportCandidate], layer: String = defaultLayer
    ) -> TransportCandidate? {
        resolve(
            candidates: candidates, viewedLayer: layer,
            pinnedID: nil, preferNonLooping: true
        )
    }
}

public struct TransportSeed: Sendable, Equatable {
    public var mediaID: String

    public var layerID: String
    public var origin: TransportOrigin

    public init(mediaID: String, layerID: String, origin: TransportOrigin) {
        self.mediaID = mediaID
        self.layerID = layerID
        self.origin = origin
    }
}

extension ShowState {

    public func transportSeeds() -> [TransportSeed] {
        var seeds: [TransportSeed] = []
        var seen = Set<String>()

        let foreground = [LayerKind.videos.rawValue] + customLayers.map(\.id)
        for layer in [LayerKind.videoInput, .loopingVideos, .stillGraphics, .videos].map(\.rawValue)
            + customLayers.map(\.id) {
            guard let media = liveMedia[layer], !media.mediaId.isEmpty,
                  seen.insert(media.mediaId).inserted else { continue }
            let direct = directMediaFires.contains(layer)
            let origin: TransportOrigin = foreground.contains(layer)
                ? (direct ? .foregroundServiceItem : .foregroundCue)
                : (direct ? .backgroundServiceItem : .backgroundCue)
            seeds.append(TransportSeed(mediaID: media.mediaId, layerID: layer, origin: origin))
        }
        if let live = liveSlide {
            var objects = live.slide.objects
            if let template = SlideSceneBuilder.themeSlide(for: live.slide, theme: live.theme) {
                objects += template.objects
            }

            for object in objects {
                if let id = SlideSceneBuilder.fillMediaID(object), seen.insert(id).inserted {
                    seeds.append(TransportSeed(mediaID: id, layerID: LayerKind.slide.rawValue, origin: .slides))
                }
            }
        }
        for overlay in liveOverlays {
            let layer = overlay.layer.flatMap(LayerKind.init(rawValue:)) ?? .overlays
            for object in overlay.objects {
                if let id = SlideSceneBuilder.fillMediaID(object), seen.insert(id).inserted {
                    seeds.append(TransportSeed(mediaID: id, layerID: layer.rawValue, origin: .overlays))
                }
            }
        }
        if let alert = liveAlert, alert.showsOnAudience,
           let template = AlertSceneBuilder.alertsThemeSlide(in: alert.theme) {
            for object in template.objects {
                if let id = SlideSceneBuilder.fillMediaID(object), seen.insert(id).inserted {
                    seeds.append(TransportSeed(mediaID: id, layerID: (alert.layer ?? .alerts).rawValue, origin: .alerts))
                }
            }
        }
        return seeds
    }
}
