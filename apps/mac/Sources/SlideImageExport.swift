import AVFoundation
import AppKit
import CoreText
import ImageIO
import PresenterCore
import RenderEngine
import SlideScene
import UniformTypeIdentifiers

@MainActor
final class SlideImageExport {
    struct Item {
        var slide: Slide
        var label: String?
    }

    private let model: AppModel
    private let render: RenderContext
    private let bundle: DeckBundle
    private let includeMedia: Bool
    let items: [Item]
    private let carried: [String: [LayerKind: String]]

    private let stillPrefix = "export::\(UUID().uuidString)::"
    private nonisolated static let renderQueue = DispatchQueue(
        label: "io.prodcontrol.mxupresenter.slideExport", qos: .userInitiated)

    init(model: AppModel, render: RenderContext, bundle: DeckBundle, includeMedia: Bool) {
        self.model = model
        self.render = render
        self.bundle = bundle
        self.includeMedia = includeMedia
        let presentation = bundle.presentation
        let arrangementId = presentation.defaultArrangementId
        let sections = Dictionary((presentation.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        items = SlideSceneBuilder.arrangedSlides(for: presentation, arrangementId: arrangementId).map { slide in
            let section = slide.sectionId.flatMap { sections[$0] }
            return Item(slide: slide, label: slide.name.isEmpty ? section : slide.name)
        }
        carried = includeMedia
            ? SlideSceneBuilder.carriedMediaMap(for: presentation, arrangementId: arrangementId) { [bundle] id in
                bundle.media[id].map { ($0.mediaKind, $0.classification) }
            }
            : [:]
    }

    var canvas: CGSize { SlideSceneBuilder.canvasSize(for: bundle.presentation) }

    private enum Backdrop: Sendable {
        case checker
        case color(CGColor)
    }

    func tileBackground(for slide: Slide) -> CGColor {
        if let theme = bundle.themes[bundle.presentation.themeId(for: slide)],
           let color = ColorHex.color(theme.backgroundColorHex) {
            CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        } else {
            CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
    }

    func image(of item: Item, width: Int, transparent: Bool? = nil) async -> CGImage? {
        let slide = item.slide
        let theme = bundle.themes[bundle.presentation.themeId(for: slide)]
        var built = SlideSceneBuilder.peakLook(SlideSceneBuilder.scene(
            for: slide, theme: theme, presentation: bundle.presentation,
            arrangementId: bundle.presentation.defaultArrangementId,
            canvasSize: canvas, animationContext: .settled,
            carriedMedia: carried[slide.id] ?? [:]
        ))
        .applyingMediaEffects { [model] in model.mediaSceneEffects(id: $0) }
        if !includeMedia {
            built.layers = built.layers.filter { $0.kind == .slide }
        }
        var ids = Set<String>()
        _ = built.remappingMediaIDs { ids.insert($0); return $0 }
        for id in ids.sorted() where LiveInputPlaceholder.remap(id) == nil {
            await registerStill(id)
        }
        let scene = built.remappingMediaIDs { id in
            if let placeholder = LiveInputPlaceholder.remap(id) {
                placeholder
            } else if render.media.hasStill(id: stillPrefix + id) {
                stillPrefix + id
            } else {
                id
            }
        }
        let height = max(1, Int((CGFloat(width) * canvas.height / max(1, canvas.width)).rounded()))
        let compositor = render.compositor
        let transparent = transparent ?? !includeMedia
        return await withCheckedContinuation { continuation in
            Self.renderQueue.async {
                let frame = try? compositor.renderFrame(
                    scene: scene, width: width, height: height, transparentBackground: transparent)
                continuation.resume(returning: frame?.cgImage.flatMap(Self.eightBit))
            }
        }
    }

    func finish() {
        render.media.stopAll(withPrefix: stillPrefix)
    }

    private func registerStill(_ id: String) async {
        if !render.media.hasStill(id: stillPrefix + id), let item = bundle.media[id],
           let url = model.blobs?.url(forHash: item.fileHash) {
            let maxPixels = Int(max(canvas.width, canvas.height))
            let kind = item.mediaKind
            let inPoint = item.inPoint ?? 0
            let frame = await Task.detached(priority: .userInitiated) {
                await Self.frame(of: url, kind: kind, at: inPoint, maxPixels: maxPixels)
            }.value
            if let frame {
                _ = try? await render.media.showStill(
                    image: frame, cacheKey: "\(item.fileHash)|\(inPoint)|\(maxPixels)", id: stillPrefix + id)
            }
        }
    }

    private nonisolated static func frame(of url: URL, kind: MediaKind, at seconds: Double, maxPixels: Int) async -> CGImage? {
        switch kind {
        case .image:
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                ] as CFDictionary)
            } else {
                nil
            }
        case .video:
            await videoFrame(of: url, at: seconds, maxPixels: maxPixels)
        }
    }

    private nonisolated static func videoFrame(of url: URL, at seconds: Double, maxPixels: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    private nonisolated static func eightBit(_ image: CGImage) -> CGImage? {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context?.makeImage()
    }

    func writeImages(to folder: URL, progress: (Int, Int) -> Void) async throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = PresentationExport.imageFileNames(labels: items.map(\.label))
        var written = 0
        for (index, item) in items.enumerated() {
            progress(index, items.count)
            if let image = await image(of: item, width: Int(canvas.width)) {
                let url = folder.appendingPathComponent(names[index])
                try await Task.detached(priority: .userInitiated) { try Self.writePNG(image, to: url) }.value
                written += 1
            }
        }
        return written
    }

    private nonisolated static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
    }

    private struct Tile: @unchecked Sendable {
        var image: CGImage
        var caption: String
    }

    func writePDF(
        to url: URL, columns: Int, roundedCorners: Bool, progress: (Int, Int) -> Void
    ) async throws {
        let sheet = PresentationExport.Sheet(
            pageSize: NSPrintInfo.shared.paperSize, columns: columns,
            aspect: canvas.width / max(1, canvas.height))

        let width = min(Int(canvas.width), Int((sheet.tileSize.width * 3).rounded()))
        let checker = UserDefaults.standard.object(forKey: "slideGrid.transparencyGrid") as? Bool ?? true
        var tiles: [Tile] = []
        for (index, item) in items.enumerated() {
            progress(index, items.count)
            let backdrop = checker ? Backdrop.checker : .color(tileBackground(for: item.slide))

            if let image = await image(of: item, width: width, transparent: true),
               let flat = await Task.detached(priority: .userInitiated, operation: {
                   Self.jpegBacked(image, over: backdrop)
               }).value {
                tiles.append(Tile(image: flat, caption: item.label.map { "\(index + 1)  \($0)" } ?? "\(index + 1)"))
            }
        }
        let title = bundle.presentation.name
        let radius = roundedCorners ? sheet.cornerRadius : 0
        try await Task.detached(priority: .userInitiated) {
            try Self.drawPDF(tiles, sheet: sheet, title: title, cornerRadius: radius, to: url)
        }.value
    }

    private nonisolated static func jpegBacked(_ image: CGImage, over backdrop: Backdrop) -> CGImage? {
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        if let context {
            switch backdrop {
            case .checker:
                StationThumbnailExporter.drawChecker(in: context, frame: frame)
            case .color(let color):
                context.setFillColor(color)
                context.fill(frame)
            }
        }
        context?.draw(image, in: frame)
        let data = NSMutableData()
        if let flat = context?.makeImage(),
           let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data) {
                return CGImage(
                    jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        return nil
    }

    private nonisolated static func drawPDF(
        _ tiles: [Tile], sheet: PresentationExport.Sheet, title: String, cornerRadius: CGFloat, to url: URL
    ) throws {
        var mediaBox = CGRect(origin: .zero, size: sheet.pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, [kCGPDFContextTitle: title] as CFDictionary)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
        let pages = sheet.pages(count: tiles.count)
        var next = 0
        for (page, rects) in pages.enumerated() {
            context.beginPDFPage(nil)
            if page == 0 {
                drawText(
                    title, size: 16, weight: .semibold, gray: 0, in: context,
                    at: CGPoint(
                        x: PresentationExport.Sheet.margin,
                        y: sheet.pageSize.height - PresentationExport.Sheet.margin - 16),
                    width: sheet.pageSize.width - 2 * PresentationExport.Sheet.margin)
            }
            for rect in rects {
                let tile = tiles[next]
                next += 1
                let shape = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                context.saveGState()
                context.addPath(shape)
                context.clip()
                context.draw(tile.image, in: rect)
                context.restoreGState()
                context.addPath(shape)
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
                context.setLineWidth(0.5)
                context.strokePath()
                drawText(
                    tile.caption, size: 8, weight: .regular, gray: 0.35, in: context,
                    at: CGPoint(x: rect.minX, y: rect.minY - PresentationExport.Sheet.captionHeight + 4),
                    width: rect.width)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private nonisolated static func drawText(
        _ text: String, size: CGFloat, weight: NSFont.Weight, gray: CGFloat,
        in context: CGContext, at point: CGPoint, width: CGFloat
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
        let ellipsis = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "…" as CFString, attributes))
        let fitted = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
        context.textPosition = point
        CTLineDraw(fitted, context)
    }
}
