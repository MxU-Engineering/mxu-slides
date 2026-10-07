import Foundation
import Testing

@Suite struct RenderCacheSeamSweepTests {
    private var renderEngine: URL {
        SourceSweep.macRoot().appendingPathComponent("Packages/RenderEngine", isDirectory: true)
    }

    @Test func everyFrameCacheHasASweptCountSeamATestReads() throws {
        let compositor = try SourceSweep(root: renderEngine.appendingPathComponent("Sources/RenderEngine"))
        let file = try #require(compositor.file("Compositor.swift"))
        let text = file.text
        let tests = try SourceSweep(root: renderEngine.appendingPathComponent("Tests"))
        let testText = tests.files.map(\.text).joined(separator: "\n")
        let caches = file.codeLines.compactMap { line in
            line.firstMatch(of: /private var ([a-z][A-Za-z0-9]*s): \[[A-Za-z0-9_.]+: Cached[A-Za-z0-9]+\]/).map { String($0.1) }
        }
        #expect(caches.count >= 4, "the sweep should see the compositor's frame caches (\(caches))")
        let evict = try #require(file.lines.firstIndex { $0.contains("func evictStaleEntries(") })
        let sweepBody = file.block(from: evict).map { file.lines[$0] }.joined(separator: "\n")
        for cache in caches {

            let seam = String(cache.dropLast()) + "Count"
            #expect(text.contains("var \(seam): Int"), "\(cache) needs a `\(seam)` test seam")
            #expect(text.contains("return \(cache).count"), "`\(seam)` must count \(cache)")
            #expect(sweepBody.contains(cache), "\(cache) must age out in evictStaleEntries (the 17 GB lesson)")
            #expect(testText.contains(".\(seam)"), "a RenderEngine test must read `\(seam)`: pin the hit rate of \(cache)")
        }
    }

    @Test func aMovingTickerHoldsOneFlatPath() throws {
        let tests = try SourceSweep(root: renderEngine.appendingPathComponent("Tests"))
        let pathText = try #require(tests.file("PathTextTests.swift")).text
        let test = try #require(pathText.range(of: "func testMovingTickerHoldsExactlyOneStripEntry"))
        #expect(String(pathText[test.upperBound...].prefix(4000)).contains("flatPathCount"))
    }
}
