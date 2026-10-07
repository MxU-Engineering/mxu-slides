import Foundation
import Testing
@testable import PresenterCore

@Test func customNeedsURLAndKeyExceptSRT() {
    let empty = StreamPresetDestination(id: "d", name: "Destination", transport: .rtmp, url: "")
    #expect(StreamDestinationReadiness.problem(empty) == "Destination: no server URL")
    let noKey = StreamPresetDestination(id: "d", name: "Resi", transport: .rtmps, url: "rtmps://x/app")
    #expect(StreamDestinationReadiness.problem(noKey) == "Resi: no stream key")
    let srt = StreamPresetDestination(id: "d", name: "North", transport: .srt, url: "srt://h:9000")
    #expect(StreamDestinationReadiness.isReady(srt))
    let ok = StreamPresetDestination(id: "d", name: "Resi", transport: .rtmps, url: "rtmps://x/app", streamKey: "k")
    #expect(StreamDestinationReadiness.isReady(ok))
}

@Test func problemsKeepOrder() {
    #expect(StreamDestinationReadiness.problems([
        StreamPresetDestination(id: "a", name: "Resi", transport: .rtmps, url: "rtmps://x/app"),
        StreamPresetDestination(id: "b", name: "North", transport: .srt, url: "srt://h:9000"),
        StreamPresetDestination(id: "c", name: "Decoder", transport: .rtmp, url: ""),
    ]) == ["Resi: no stream key", "Decoder: no server URL"])
}

@Test func startRefusalOnlyWhenNothingCouldStart() {
    let broken = StreamPresetDestination(id: "c", name: "Decoder", transport: .rtmp, url: "")
    #expect(StreamDestinationReadiness.startRefusal(kind: .stream, destinations: [broken]) == "Won't go live: Decoder: no server URL")
    let custom = StreamPresetDestination(id: "c", name: "Resi", transport: .rtmps, url: "rtmps://x/app", streamKey: "k")
    #expect(StreamDestinationReadiness.startRefusal(kind: .stream, destinations: [custom, broken]) == nil, "one ready destination is enough")
    #expect(StreamDestinationReadiness.startRefusal(kind: .stream, destinations: []) == "Won't go live: no destinations selected")
    #expect(StreamDestinationReadiness.startRefusal(kind: .recordOnly, destinations: []) == nil)
}
