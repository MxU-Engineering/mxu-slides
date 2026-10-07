import Foundation
import Testing

@Suite struct ThumbnailStampSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func asyncLoadedLibraryFacesKeyThumbnailsOnTheirLoadedStamp() throws {
        let file = appSources.appendingPathComponent("LibraryView.swift")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("struct LibraryItemFace") }) else {
            Issue.record("LibraryItemFace not found")
            return
        }
        var found = 0
        var violations: [String] = []
        for (offset, line) in lines[start...].enumerated() where line.contains("SlideThumbnailView(") {
            found += 1

            var call: [String] = []
            for later in lines[(start + offset + 1)...] {
                call.append(later)
                if later.trimmingCharacters(in: .whitespaces) == ")" { break }
            }
            if !call.joined(separator: "\n").contains("contentStamp: loadedStamp") {
                violations.append("LibraryView.swift:\(start + offset + 1) keys on the index stamp")
            }
        }
        #expect(found >= 3, "presentation, overlay and confidence faces expected (\(found))")
        #expect(violations.isEmpty, "\(violations)")
    }
}
