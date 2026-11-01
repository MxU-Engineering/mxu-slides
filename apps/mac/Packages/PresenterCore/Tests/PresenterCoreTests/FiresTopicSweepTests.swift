import Foundation
import Testing

@Suite struct FiresTopicSweepTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
    }

    private func allSources() throws -> [String: String] {
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try Dictionary(uniqueKeysWithValues: files.map {
            ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
        })
    }

    private static let sites: [(file: String, publish: String)] = [
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(\n            kind: .slide,"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .step, steps: 1))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .step, steps: -1))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .clear, clear: APIClearCommand(function: function.rawValue)))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .clear, clear: APIClearCommand(layer: layerID)))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .clearAll))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(\n            kind: .media,"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .overlay, id: overlay.id))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .dismissOverlay, id: id))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .dismissOverlay))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(\n            kind: .alert,"),
        ("TimersController.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .timer, id: id, timer: .play))"),
        ("TimersController.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .timer, id: id, timer: .pause))"),
        ("TimersController.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .timer, id: id, timer: .reset))"),
        ("ActionRouter.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .combo, id: comboID))"),
        ("OutputPresetsController.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .outputPreset, id: id))"),

        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .audioPlaylist, id: playlist.id, entryId: entryID))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .audioItem, id: audioItem.id))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .stopAudio, audioStop: APIAudioStopCommand(playlistId: playlistID)))"),
        ("ServiceControls.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .stopAudio, audioStop: APIAudioStopCommand(audioItemId: audioItemID)))"),
        ("AudioController.swift", "APIAudioTransportCommand(action: \"playPause\")"),
        ("AudioController.swift", "APIAudioTransportCommand(action: \"next\")"),
        ("AudioController.swift", "APIAudioTransportCommand(action: \"previous\")"),
        ("AudioController.swift", "APIAudioTransportCommand(action: \"seek\", position: seconds)"),
        ("MediaTransportController.swift", "APIMediaTransportCommand(action: row.state.isPlaying ? \"pause\" : \"resume\")"),
        ("MediaTransportController.swift", "APIMediaTransportCommand(action: \"seek\", position: seconds)"),
        ("MediaTransportController.swift", "APIMediaTransportCommand(action: \"reset\")"),

        ("FollowController.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .role, term: role.term, inCharge: me))"),
        ("StreamingController.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .capture, id: live?.presetID))"),

        ("FollowController.swift", "APIFireFeed.shared.publish(APIFireEvent(kind: .quit))"),
    ]

    @Test func everyFireKindPublishesOnceFromWhereItRuns() throws {
        let all = try allSources()
        for site in Self.sites {
            let text = try #require(all[site.file])
            #expect(text.components(separatedBy: site.publish).count == 2, "\(site.file): \(site.publish)")
        }
        let total = all.values.map { $0.components(separatedBy: "APIFireFeed.shared.publish(").count - 1 }.reduce(0, +)
        #expect(total == Self.sites.count, "a publish outside the known sites fires twice on a follower")
        let kinds = ["slide", "step", "clear", "clearAll", "media", "overlay", "dismissOverlay", "alert", "timer", "combo", "outputPreset",
                     "audioPlaylist", "audioItem", "stopAudio"]
        for kind in kinds {
            #expect(Self.sites.contains { $0.publish.contains("kind: .\(kind),") || $0.publish.contains("kind: .\(kind))") }, "\(kind) has a site")
        }

        #expect(try source("AudioController.swift").components(separatedBy: "kind: .audioTransport").count - 1 == 4)
        #expect(try source("MediaTransportController.swift").components(separatedBy: "kind: .mediaTransport").count - 1 == 3)
    }

    @Test func aWaitingSlidePublishesOnce() throws {
        let controls = try source("ServiceControls.swift")
        let fire = try #require(controls.range(of: "    func fire(\n        slide: Slide"))
        let dispatch = try #require(controls.range(of: "    private func dispatch(\n        slide: Slide"))
        let entry = controls[fire.upperBound ..< dispatch.lowerBound]
        #expect(entry.contains("kind: .slide,"))
        #expect(entry.contains("APIFireFeed.$cause.withValue(seq) {\n            dispatch("))
        let body = controls[dispatch.upperBound...].prefix(3000)
        #expect(body.contains("self.dispatch(\n"))
        #expect(!body.contains("self.fire(\n                    slide:"))
    }

    @Test func effectsRunUnderTheirFire() throws {
        let controls = try source("ServiceControls.swift")
        #expect(controls.contains("APIFireFeed.$cause.withValue(seq) { actionRouter?.applyPresetSwitches(forMedia: mediaItem, contextID: contextID) }"))
        #expect(controls.contains("APIFireFeed.$cause.withValue(seq) { actionRouter?.mediaDidFire(mediaItem, on: layer) }"))
        #expect(try source("ActionRouter.swift").contains("APIFireFeed.$cause.withValue(seq) { execute(combo.actions, depth: 1, visited: [comboID]) }"))
    }

    @Test func schedulerFiresCarryTheSchedulerSource() throws {
        let scheduler = try source("SchedulerController.swift")
        #expect(scheduler.contains("APIFireSource.$current.withValue(APIFireSource(kind: .scheduler)) { router.execute(trigger.actions) }"))
    }

    @Test func theLocalAPISendsFiresAndTheMainBeat() throws {
        let controller = try source("LocalAPIController.swift")
        #expect(controller.contains("APIFireFeed.shared.sink = { continuation.yield($0) }"))
        #expect(controller.contains("APIFireFeed.shared.sink = nil"))
        #expect(controller.contains("beat: { DiagnosticsStore.shared.mainBeat }"))
        #expect(try source("MxUSlidesApp.swift").contains("api.identity = {"))
    }
}
