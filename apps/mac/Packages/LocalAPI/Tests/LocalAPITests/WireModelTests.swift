import XCTest

@testable import LocalAPI

final class ShowStatusWireTests: XCTestCase {
    func testShowStatusCarriesServiceNextSlideAndPosition() throws {
        let status = APIShowStatus(
            liveSlide: APIShowStatus.LiveSlide(
                presentationId: "p1", presentationName: "Way Maker", slideId: "s1",
                slideIndex: 2, slideName: nil, serviceItemId: "i1", occurrence: 2,
                text: "Way maker", slideCount: 9),
            nextSlideText: "Miracle worker", mediaLayers: [:], overlays: [], alert: nil,
            currentServiceId: "svc",
            service: .init(id: "svc", name: "Sunday"),
            nextSlide: .init(text: "Miracle worker"),
            position: .init(currentItemName: "Way Maker", nextItemName: "Welcome"))

        let json = try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(status)) as? [String: Any]
        let live = json?["liveSlide"] as? [String: Any]
        XCTAssertEqual(live?["text"] as? String, "Way maker")
        XCTAssertEqual(live?["slideCount"] as? Int, 9)
        XCTAssertEqual((json?["service"] as? [String: Any])?["name"] as? String, "Sunday")
        XCTAssertEqual((json?["position"] as? [String: Any])?["nextItemName"] as? String, "Welcome")
        XCTAssertEqual((json?["nextSlide"] as? [String: Any])?["text"] as? String, "Miracle worker")
    }

    func testTimersDocumentEncodesAnchorsAsISODates() throws {
        let document = APITimersDocument(
            timers: [APITimerStatus(
                id: "t1", name: "Sermon", mode: "countdown", running: true, displaySeconds: 1799,
                overrun: false, folderId: nil, folderName: nil,
                runningSince: Date(timeIntervalSince1970: 0), bankedSeconds: 1, durationSeconds: 1800,
                warnings: [.init(remainingSeconds: 30, colorHex: "#FFAA00")])],
            videoCountdowns: [APIVideoCountdown(
                layer: "videos", name: "Bumper", duration: 60, position: 12,
                anchoredAt: Date(timeIntervalSince1970: 0), isPlaying: true, serviceItemId: "i2")])

        let json = try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(document)) as? [String: Any]
        let timer = (json?["timers"] as? [[String: Any]])?.first
        XCTAssertEqual(timer?["runningSince"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual((timer?["warnings"] as? [[String: Any]])?.first?["colorHex"] as? String, "#FFAA00")
        let countdown = (json?["videoCountdowns"] as? [[String: Any]])?.first
        XCTAssertEqual(countdown?["layer"] as? String, "videos")
        XCTAssertEqual(countdown?["isPlaying"] as? Bool, true)
        XCTAssertEqual(countdown?["serviceItemId"] as? String, "i2")
        XCTAssertNoThrow(try JSONDecoder.iso8601.decode(APITimersDocument.self, from: APIJSON.encoder().encode(document)))
    }
}

final class ServiceSnapshotWireTests: XCTestCase {
    func testSnapshotEncodesItemsSlidesAndChecksums() throws {
        let snapshot = APIServiceSnapshot(
            service: .init(id: "svc", name: "Sunday"),
            items: [
                .init(id: "i1", name: "Way Maker", kind: "presentation", colorHex: nil,
                      presentation: .init(id: "p1", name: "Way Maker", arrangementId: nil, arrangementName: nil, slides: [
                        .init(id: "s1", index: 0, label: nil, group: "Verse 1", groupColorHex: "#336699", text: "Way maker", thumbnailChecksum: "abc==", size: .init(width: 1920, height: 1080)),
                      ])),
                .init(id: "i2", name: "Bumper", kind: "media", colorHex: nil, media: .init(id: "m1", name: "Bumper", durationSeconds: 90, thumbnailChecksum: nil)),
            ])

        let json = try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(snapshot)) as? [String: Any]
        let items = json?["items"] as? [[String: Any]]
        let slide = ((items?[0]["presentation"] as? [String: Any])?["slides"] as? [[String: Any]])?.first
        XCTAssertEqual(slide?["thumbnailChecksum"] as? String, "abc==")
        XCTAssertEqual(slide?["group"] as? String, "Verse 1")
        XCTAssertEqual((items?[1]["media"] as? [String: Any])?["durationSeconds"] as? Int, 90)
        XCTAssertEqual((json?["service"] as? [String: Any])?["name"] as? String, "Sunday")
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
