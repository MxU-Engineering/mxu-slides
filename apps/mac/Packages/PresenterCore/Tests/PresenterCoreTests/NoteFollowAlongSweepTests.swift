import Foundation
import Testing

@Suite struct NoteFollowAlongSweepTests {
    private func body(_ file: SourceSweep.File, _ signature: String) throws -> String {
        let start = try #require(file.lines.firstIndex { $0.contains(signature) }, "\(signature)")
        return file.lines[file.block(from: start)].joined(separator: "\n")
    }

    @Test func onlyTheLeavesReadTheLiveSlide() throws {
        let view = try #require(try SourceSweep.app().file("NoteFollowAlongView.swift"))
        let main = try body(view, "struct NoteFollowAlongView: View, Equatable {")

        #expect(!main.contains("@ObservedObject") && main.contains("    let live: NoteSlideLive"))
        #expect(!main.contains("controls?.liveSlideID") && !main.contains("controls.liveSlideID"))

        for leaf in ["private struct NoteFollowTile: View {", "private struct NoteFollowLiveTag: View {"] {
            #expect(try body(view, leaf).contains("@ObservedObject var live: NoteSlideLive"), "\(leaf)")
        }
        #expect(main.contains("lhs.follow.version == rhs.follow.version"))
    }

    @Test func theReaderHostsItEquatableAndScrollsThroughTheHandle() throws {
        let reader = try #require(try SourceSweep.app().file("NoteReaderView.swift"))
        #expect(reader.text.contains("live: live, scroller: followScroller)\n                .equatable()"))
        #expect(reader.text.contains("if let line = follow.lineBySlide[slideID] { followScroller.scrollTo?(line) }"))
        let rebuild = try body(reader, "private func rebuildFollow() {")
        #expect(rebuild.contains("NoteFollowAlong.items("))
        #expect(!rebuild.contains("loadValue") && !rebuild.contains("library.open("))
    }
}
