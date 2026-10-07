import Foundation
import Testing
import PresenterCore
@testable import ProImport

@MainActor
struct RealBundleSweep {
    @Test func bundles() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PRO_IMPORT_BUNDLES"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try await Library(rootURL: root)
        let importer = try ProPresenterImporter(client: await started(library))
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "probundle" }
        let summaries = await importer.importItems(at: urls)
        for s in summaries {
            print("== \(s.name): id=\(s.presentationID ?? "SKIPPED") media=\(s.mediaImported) warnings=\(s.warnings)")
            guard let id = s.presentationID else { continue }
            let p = try await library.open(Presentation.self, id: id).value
            print("   slides=\(p.slides.count) sections=\(p.sections?.map(\.name) ?? []) arrangements=\(p.arrangements?.map(\.name) ?? []) ccli=\(String(describing: p.ccli))")
            for slide in p.slides.prefix(3) {
                for o in slide.objects {
                    let styleBits = o.textStyle.map { "font=\($0.fontName ?? "-") size=\($0.fontSize ?? 0) color=\($0.colorHex ?? "-") track=\($0.tracking ?? 0) valign=\(String(describing: $0.verticalAlignment))" } ?? ""
                    print("   [\(o.objectKind.rawValue)] '\(o.name)' frame=(\(o.x ?? -1),\(o.y ?? -1),\(o.width ?? -1),\(o.height ?? -1)) \(styleBits) text=\(o.text.prefix(40))")
                }
                if let bg = slide.background { print("   bg media=\(bg.mediaId) layer=\(String(describing: bg.layer))") }
                if let n = slide.notes { print("   notes=\(n.prefix(80))") }
            }
        }
        #expect(!summaries.isEmpty)
    }
}
