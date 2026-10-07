import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum EditorPaste {
    public enum Source: Equatable, Sendable {
        case objects, slides, files, image
    }

    public static let objectsType = "com.example.mxuslides.slide-objects"
    public static let slideType = "com.example.mxuslides.slide"
    public static let slidesType = "com.example.mxuslides.slides"

    public static func source(types: [String]) -> Source? {
        if types.contains(objectsType) {
            .objects
        } else if types.contains(slideType) || types.contains(slidesType) {
            .slides
        } else if types.contains(UTType.fileURL.identifier) {
            .files
        } else if imageType(in: types) != nil {
            .image
        } else {
            nil
        }
    }

    static let keptImageTypes: [UTType] = [.png, .jpeg, .heic, .gif]

    public static func imageType(in types: [String]) -> String? {
        (keptImageTypes + [.tiff]).map(\.identifier).first(where: types.contains)
    }

    public static func writeImage(_ data: Data, type: String, into directory: URL) -> URL? {
        let kept = keptImageTypes.first { $0.identifier == type }
        let fileType = kept ?? .png
        let url = directory.appendingPathComponent("Pasted Image", conformingTo: fileType)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
            if kept != nil {
                return (try? data.write(to: url)) != nil ? url : nil
            } else if let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImageFromSource(destination, source, 0, nil)
                return CGImageDestinationFinalize(destination) ? url : nil
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
}
