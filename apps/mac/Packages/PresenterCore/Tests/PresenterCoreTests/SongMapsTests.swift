import Compression
import Foundation
import Testing
@testable import PresenterCore

private let runToTheFather: [(Double, String)] = [
    (354, "Count Off"), (0, "Count Off"), (6, "Intro"), (18, "Intro"), (30, "Verse 1"), (54, "Verse 2"), (78, "Chorus"),
    (102, "Refrain"), (114, "Verse 3"), (138, "Verse 4"), (162, "Chorus"), (186, "Refrain"), (198, "Refrain"),
    (210, "Bridge 1"), (234, "Bridge 2"), (258, "Chorus"), (282, "Chorus"), (306, "Refrain"), (318, "Refrain"),
    (330, "Outro"), (342, "Ending"),
]

private func liveSet(_ locators: [(Double, String)]) -> Data {
    let tempo = [(-63_072_000.0, 68.5), (336, 68.5), (336, 65.3538666), (337.5, 65.3538666), (337.5, 61.7001839),
                 (339, 61.7001839), (339, 52.5598602), (340.5, 52.5598602), (340.5, 37.4808044), (342, 37.4808044),
                 (342, 68.4999924)]
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Ableton><LiveSet><MasterTrack><DeviceChain><Mixer><Tempo><LomId Value="0" /><Manual Value="68.5" />
    <ArrangerAutomation><Events>\(tempo.map { "<FloatEvent Time=\"\($0.0)\" Value=\"\($0.1)\" />" }.joined())</Events></ArrangerAutomation>
    </Tempo></Mixer></DeviceChain></MasterTrack>
    <Locators><Locators>\(locators.map { "<Locator><LomId Value=\"0\" /><Time Value=\"\($0.0)\" /><Name Value=\"\($0.1)\" /></Locator>" }.joined())</Locators></Locators>
    </LiveSet></Ableton>
    """
    return gzip(Data(xml.utf8))
}

private func gzip(_ data: Data) -> Data {
    let input = [UInt8](data)
    var out = [UInt8](repeating: 0, count: input.count + 1024)
    let size = compression_encode_buffer(&out, out.count, input, input.count, nil, COMPRESSION_ZLIB)
    var file: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + out.prefix(size) + [0, 0, 0, 0]
    let length = UInt32(input.count)
    file += [UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)]
    return Data(file)
}

private func ids() -> () -> String {
    var count = 0
    return { count += 1; return "a\(count)" }
}

@Test func aMultiTracksSetGivesItsSectionsInSongSeconds() throws {
    let set = try #require(SongMaps.abletonSet(liveSet(runToTheFather)))
    #expect(set.locators.count == 21)
    #expect(set.locators.first?.beats == 0)
    let sections = SongMaps.sections(from: set, bpm: 68.5, recordingEnd: 309.14, newID: ids())

    #expect(sections.count == 20)
    #expect(sections.map(\.name).prefix(6) == ["Count Off", "Intro", "Intro", "Verse 1", "Verse 2", "Chorus"])
    #expect(abs(sections[3].start - 26.277) < 0.001)
    #expect(abs(sections[18].start - 289.051) < 0.001)

    #expect(abs(sections[19].start - 301.256) < 0.001)
}

@Test func tempoRampsAndStepsAndTheFolderNamesTempo() {
    let ramp = [SongMaps.TempoPoint(beat: 0, bpm: 60), SongMaps.TempoPoint(beat: 4, bpm: 120)]

    #expect(abs(SongMaps.seconds(beats: 4, tempo: ramp, bpm: 100) - 4 * log(2.0)) < 1e-9)
    #expect(abs(SongMaps.seconds(beats: 6, tempo: ramp, bpm: 100) - (4 * log(2.0) + 1)) < 1e-9)
    #expect(SongMaps.seconds(beats: 8, tempo: [], bpm: 120) == 4)
    #expect(SongMaps.bpm(folderName: "Run To The Father-Run to the Father-C-68.50bpm") == 68.5)
    #expect(SongMaps.bpm(folderName: "Way Maker") == nil)
    #expect(SongMaps.abletonSet(Data("not a set".utf8)) == nil)
}

@Test func sectionsLinkToSlideSectionsByName() {
    let slides = [PresentationSection(id: "v1", name: "Verse 1"), PresentationSection(id: "c", name: "Chorus"),
                  PresentationSection(id: "b1", name: "Bridge")]
    let linked = SongMaps.linked([
        AudioSection(id: "1", name: "VERSE 1", start: 0), AudioSection(id: "2", name: "Chorus", start: 10),
        AudioSection(id: "3", name: "Bridge 1", start: 20), AudioSection(id: "4", name: "Count Off", start: 30),
        AudioSection(id: "5", name: "Chorus", start: 40, sectionId: "v1"),
    ], to: slides)
    #expect(linked.map(\.sectionId) == ["v1", "c", "b1", nil, "v1"])
}

private func song() -> SongMap {
    let stem = TimelineCue(id: "stem", lane: TimelineTracks.lane(for: "keys"), at: 0, duration: 50, mediaId: "keys")
    let slides = [(4.0, "v", 0), (14, "c", 0), (24, "v", 1), (34, "c", 1)].map { at, section, occurrence in
        TimelineCue(id: "s\(at)", lane: TimelineLane.slide.rawValue, at: at, sectionId: section,
                    sectionOccurrence: occurrence == 0 ? nil : occurrence, slideId: "\(section)-1")
    }
    let sections = [("i", "Intro", 0.0, nil), ("v1", "Verse", 4, "v"), ("c1", "Chorus", 14, "c"), ("v2", "Verse", 24, "v"),
                    ("c2", "Chorus", 34, "c"), ("c3", "Chorus", 39, "c"), ("e", "Ending", 44, nil)]
        .map { AudioSection(id: $0.0, name: $0.1, start: $0.2, sectionId: $0.3) }
    return SongMap(recording: [stem] + slides, sections: sections)
}

private func blocks(_ order: [String]) -> [TimelinePlayedBlock] {
    order.map { TimelinePlayedBlock(sectionId: $0, slideIds: ["\($0)-1"]) }
}

@Test func theRecordingsOwnOrderLaysOutAsRecorded() throws {
    let map = song()
    let layout = SongMaps.layout(map, blocks: blocks(["v", "c", "v", "c"]))

    #expect(layout.map(\.audioSectionIds) == [["i"], ["v1"], ["c1"], ["v2"], ["c2", "c3", "e"]])
    #expect(layout.map(\.start) == [0, 4, 14, 24, 34])
    let timeline = PresentationTimeline(id: "t", timecodeEnabled: false, timecodeStart: 0, cues: [])
    let laid = try #require(SongMaps.laidOut(map, blocks: blocks(["v", "c", "v", "c"]), timeline: timeline, newID: ids()))
    let stems = TimelineTracks.stems(laid.cues)

    #expect(stems.map(\.at) == [0, 4, 14, 24, 34])
    #expect(stems.map { $0.inPoint ?? 0 } == [0, 4, 14, 24, 34])
    #expect(TimelineClips.edges(of: stems[2], in: laid.cues) == (false, false))
    #expect(laid.cues.filter { $0.kind == .slide }.map(\.at) == [4, 14, 24, 34])

    var unlinked = map
    unlinked.sections = unlinked.sections.map { var section = $0; section.sectionId = nil; return section }
    #expect(SongMaps.laidOut(unlinked, blocks: blocks(["v"]), timeline: timeline) == nil)

    #expect(SongMaps.laidOut(map, blocks: blocks(["v", "c", "v", "c"]), timeline: laid) == nil)
}

@Test func anArrangementPlaysItsSectionsAudioInItsOrder() throws {
    let map = song()

    let order = blocks(["v", "c", "c"])
    let layout = SongMaps.layout(map, blocks: order)
    #expect(layout.map(\.audioSectionIds) == [["i"], ["v1"], ["c1"], ["c2", "c3", "e"]])
    #expect(layout.map(\.start) == [0, 4, 14, 24])
    let laid = try #require(SongMaps.laidOut(
        map, blocks: order, timeline: PresentationTimeline(id: "t", timecodeEnabled: false, timecodeStart: 0, cues: []), newID: ids()))
    let stems = TimelineTracks.stems(laid.cues)

    #expect(stems.map(\.at) == [0, 4, 14, 24])
    #expect(stems.last?.inPoint == 34 && stems.last?.duration == 16)
    #expect(TimelineClips.edges(of: stems[3], in: laid.cues).start)

    let slides = laid.cues.filter { $0.kind == .slide }
    #expect(slides.map(\.at) == [4, 14, 24])
    #expect(slides.last?.sectionOccurrence == 1)
}

@Test func editsStayWithTheirBlockWhenTheOrderChanges() throws {
    let map = song()
    let empty = PresentationTimeline(id: "t", timecodeEnabled: false, timecodeStart: 0, cues: [])
    var laid = try #require(SongMaps.laidOut(map, blocks: blocks(["v", "c", "v", "c"]), timeline: empty, newID: ids()))

    let chorus = try #require(laid.cues.firstIndex { $0.trackChannelId != nil && $0.at == 14 })
    laid.cues[chorus].fadeOut = ClipFade(seconds: 2)

    let relaid = try #require(SongMaps.laidOut(map, blocks: blocks(["v", "c", "c"]), timeline: laid, newID: ids()))
    let stems = TimelineTracks.stems(relaid.cues)
    #expect(stems.first { $0.at == 14 }?.fadeOut?.seconds == 2)
    #expect(stems.map(\.at) == [0, 4, 14, 24])
}

@Test func theArrangementEditorNamesSectionsWithNoAudio() {
    let map = song()
    let names = ["v": "Verse", "c": "Chorus", "b": "Bridge"]
    #expect(SongMaps.missing(map, blocks: blocks(["v", "c", "v", "c"]), names: names).isEmpty)

    #expect(SongMaps.missing(map, blocks: blocks(["v", "c", "b", "c", "c", "c"]), names: names) == ["Bridge", "Chorus (4th time)"])
    let missing = SongMaps.layout(map, blocks: blocks(["b"]))
    #expect(missing.last?.length == 0 && missing.last?.audioSectionIds == [])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MXU_REAL_ALS"] != nil))
func runToTheFatherReadsAsTwentyOneLocators() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["MXU_REAL_ALS"]!))
    let set = try #require(SongMaps.abletonSet(data))
    #expect(set.locators.count == 21)
    #expect(set.tempo.count == 11)
    let sections = SongMaps.sections(from: set, bpm: 68.5, recordingEnd: 309.139, newID: ids())
    #expect(sections.count == 20)
    #expect(abs(sections[19].start - 301.256) < 0.001)
}

@Test func aMarkerAtThePlayheadLandsWhereItsAudioIs() {
    let map = song()
    let layout = SongMaps.layout(map, blocks: blocks(["v", "c", "c"]))

    #expect(SongMaps.recordingTime(26, map: map, layout: layout) == 36)
    #expect(SongMaps.recordingTime(26, map: map, layout: nil) == 26)
    let marked = SongMaps.adding("Chorus", at: 36, to: map, slideSections: [PresentationSection(id: "c", name: "Chorus")], id: "new")
    #expect(marked.sections.map(\.id) == ["i", "v1", "c1", "v2", "c2", "new", "c3", "e"])
    #expect(marked.sections[5].sectionId == "c")
}
