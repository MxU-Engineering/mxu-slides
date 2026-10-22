import Foundation

public enum ThumbnailResolution {

    public static let base = 480
    public static let steps = [480, 960, 1920]

    public static func pixelWidth(tileWidth: CGFloat?, scale: CGFloat) -> Int {
        if let tileWidth, tileWidth > 0 {
            let needed = Int((tileWidth * max(scale, 1)).rounded(.up))
            return steps.first { $0 >= needed } ?? steps[steps.count - 1]
        } else {
            return base
        }
    }

    public static func posterPixels(forWidth pixelWidth: Int) -> Int {
        pixelWidth > base ? pixelWidth : PosterDecode.maxPixelSize
    }
}
