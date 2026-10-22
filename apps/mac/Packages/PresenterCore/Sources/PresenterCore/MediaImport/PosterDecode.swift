import CoreGraphics
import Foundation
import ImageIO

public enum PosterDecode {

    public static let maxPixelSize = 512

    public static func image(original: URL, diskPoster: URL?, maxPixelSize size: Int = maxPixelSize) -> CGImage? {
        let source = CGImageSourceCreateWithURL(original as CFURL, nil)
        let opaque = source.map { !hasAlpha($0) } ?? false
        if size <= maxPixelSize, opaque, let diskPoster, FileManager.default.fileExists(atPath: diskPoster.path) {
            return downsampled(url: diskPoster) ?? source.flatMap { downsampled(source: $0, maxPixelSize: size) }
        } else {
            return source.flatMap { downsampled(source: $0, maxPixelSize: size) }
        }
    }

    public static func downsampled(url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { downsampled(source: $0) }
    }

    static func hasAlpha(_ source: CGImageSource) -> Bool {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        } else {
            return true
        }
    }

    static func downsampled(source: CGImageSource, maxPixelSize size: Int = maxPixelSize) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
