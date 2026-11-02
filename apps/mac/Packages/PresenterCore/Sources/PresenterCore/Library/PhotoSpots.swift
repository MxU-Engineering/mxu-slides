import Foundation

extension Slide {
    public var photoSpots: [SlideObject] {
        objects.filter(\.isPhotoSpot).sorted(by: SlideObject.readsBefore)
    }
}

extension MediaScaleMode {
    public var inPhotoSpot: MediaScaleMode { self == .scaleAndBlur ? .fill : self }
}

public enum PictureShape: String, Sendable {
    case tall, wide

    static let limit = 1.6

    public init?(picture: Double?, spot: Double) {
        guard let picture, picture > 0, spot > 0 else { return nil }
        if spot / picture > Self.limit { self = .tall } else if picture / spot > Self.limit { self = .wide } else { return nil }
    }

    public var caption: String { "Scale and Blur (\(rawValue) picture)" }
}

extension SlideObject {
    public var isPhotoSpot: Bool { photoSpot == true && objectKind == .shape }

    static func readsBefore(_ a: SlideObject, _ b: SlideObject) -> Bool {
        let (ay, ah, by, bh) = (a.y ?? 0, a.height ?? 0, b.y ?? 0, b.height ?? 0)
        let sameRow = ay < by + bh && by < ay + ah
        return sameRow ? (a.x ?? 0) < (b.x ?? 0) : ay < by
    }

    public static func photo(mediaId: String, scale: MediaScaleMode?) -> SlideObject {
        SlideObject(
            id: UUID().uuidString, objectKind: .shape, name: "Photo", text: "",
            fill: ObjectFill(fillKind: .media, mediaId: mediaId, mediaScaleMode: scale == .fill ? nil : scale),
            photoSpot: true)
    }

    public func filled(with photo: SlideObject) -> SlideObject {
        var merged = self
        merged.id = photo.id
        merged.name = photo.name
        merged.fill = photo.fill
        merged.photoSpot = true
        if photo.x != nil, photo.y != nil, photo.width != nil, photo.height != nil {
            (merged.x, merged.y, merged.width, merged.height) = (photo.x, photo.y, photo.width, photo.height)
        }
        if let steps = photo.animationSteps, !steps.isEmpty { merged.animationSteps = steps }
        return merged
    }
}
