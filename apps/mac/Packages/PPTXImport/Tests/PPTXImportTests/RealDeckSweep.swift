import Foundation
import Testing
import PresenterCore
@testable import PPTXImport

@MainActor
struct RealDeckSweep {
    @Test func decks() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PPTX_IMPORT_FIXTURE_DIR"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try await Library(rootURL: root)
        let importer = try PPTXImporter(client: await started(library))
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pptx" }
        let summaries = await importer.importItems(at: urls)
        for s in summaries {
            print("== \(s.name): id=\(s.presentationID ?? "SKIPPED") media=\(s.mediaImported)")
            if !s.missingFonts.isEmpty { print("   missingFonts=\(s.missingFonts)") }
            for warning in s.warnings { print("   △ \(warning)") }
            guard let id = s.presentationID else { continue }
            let p = try await library.open(Presentation.self, id: id).value
            print("   slides=\(p.slides.count) canvas=\(p.canvasWidth ?? 1920)x\(p.canvasHeight ?? 1080) sections=\(p.sections?.map(\.name) ?? []) bgFill=\(String(describing: p.backgroundFill?.fillKind))")
            for (index, slide) in p.slides.enumerated() {
                print("   -- slide \(index + 1) '\(slide.name)' objects=\(slide.objects.count) bgFill=\(slide.backgroundFill?.colorHex ?? "-") bgMedia=\(slide.background?.mediaId ?? "-") actions=\(slide.actions?.count ?? 0)")
                for o in slide.objects {
                    let styleBits = o.textStyle.map { "font=\($0.fontName ?? "-") size=\($0.fontSize ?? 0) color=\($0.colorHex ?? "-")" } ?? ""
                    let runBits = (o.styleRuns?.isEmpty == false) ? " runs=\(o.styleRuns!.count)" : ""
                    let shapeBits = o.shapeKind.map { " shape=\($0.rawValue) path=\(o.pathData?.count ?? 0)ch" } ?? ""
                    var mediaBits = o.mediaId.map { " media=\($0) crop=\(o.mediaSourceRect != nil)" } ?? ""
                    if let opacity = o.opacity { mediaBits += " opacity=\(opacity)" }
                    if o.fill?.fillKind == .media {
                        mediaBits += " fillMedia=\(o.fill?.mediaId ?? "-") fillCrop=\(o.fill?.mediaSourceRect != nil)"
                    }
                    print("      [\(o.objectKind.rawValue)] '\(o.name)' frame=(\(Int(o.x ?? -1)),\(Int(o.y ?? -1)),\(Int(o.width ?? -1)),\(Int(o.height ?? -1))) \(styleBits)\(runBits)\(shapeBits)\(mediaBits) text=\(o.text.prefix(36))")
                }
            }
        }
        #expect(!summaries.isEmpty)
    }
}
