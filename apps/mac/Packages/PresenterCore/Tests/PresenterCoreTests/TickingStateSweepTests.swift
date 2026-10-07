import Foundation
import Testing

@Suite struct TickingStateSweepTests {

    private enum Tick {

        case moves([String])

        case quiet(String)
    }

    private let clocks: [String: [Tick]] = [
        "AudioController.swift": [.moves(["elapsed"])],  
        "MediaEditorView.swift": [.moves(["elapsed"])],  
        "SlideEditorModel+Animations.swift": [.moves(["animationPreviewShownTime"])],  
        "AnimationTimelinePanel.swift": [
            .quiet("the 45 Hz edge auto-scroll runs only under a live drag and scrolls the panel that owns the drag"),
        ],
        "MediaTransportController.swift": [.quiet("refresh() writes rows and rowsVersion only when a row moved")],
        "VideoInputInventory.swift": [.quiet("the 1 s connectivity poll writes the connected set only when it changes")],
        "MenuTrackingRecorder.swift": [.quiet("diagnostics while a menu is open; writes breadcrumbs, not observed state")],
        "SheetWatchRecorder.swift": [.quiet("the 1 s sheet and modal watch writes breadcrumbs, not observed state")],
        "ServiceControls.swift": [
            .quiet("the exit sweep re-applies only when an exit landed"),
            .quiet("the slide auto-advance poll fires only when the video ends"),
            .quiet("the media auto-advance poll fires only when the video ends"),
            .moves(["alertVisible"]),  
            .quiet("the linked-text clock re-applies the live scene; apply() writes state only on a change"),
        ],
        "PerformanceHUD.swift": [.quiet("the debug HUD samples its own @State twice a second")],
        "MediaPlaylistController.swift": [.quiet("the 2 Hz walk tick fires only when the item is due")],
        "SignageController.swift": [.quiet("the 2 Hz loop tick advances only a loop that is due")],
        "MediaSoak.swift": [.quiet("the soak harness's own readout")],
        "AudioMixerModule.swift": [.moves(["displayLevels", "busLevels", "playerLevels", "outputLevels"])],  
    ]

    private let readers: [String: (hint: String, pattern: Regex<Substring>, views: Set<String>)] = [
        "animationPreviewShownTime": (
            "animationPreviewShownTime", /\banimationPreviewShownTime\b/,
            ["PlayheadReadout", "PlayheadLine", "PlayheadHandle", "AnimationPreviewStrip"]
        ),

        "animationPreviewTime": ("animationPreviewTime", /\banimationPreviewTime\b/, ["AnimationPreviewStrip"]),
        "elapsed": (".elapsed", /\w\.elapsed\b(?!\s*\()/, ["AudioScrubBar", "AudioTimecode", "TransportPill"]),
        "alertVisible": ("alertVisible", /\balertVisible\b/, []),
        "displayLevels": ("displayLevels", /\.displayLevels\b/, ["AudioMixerModule"]),
        "busLevels": ("busLevels", /\.busLevels\b/, ["AudioMixerModule"]),
        "playerLevels": ("playerLevels", /\.playerLevels\b/, ["AudioMixerModule"]),
        "outputLevels": ("outputLevels", /\.outputLevels\b/, ["AudioMixerModule"]),
    ]

    private let actionOpeners: [Regex<Substring>] = [
        /set:\s*\{/, /action:\s*\{/, /\bButton\b[^{]*\{\s*$/, /\.onTapGesture\b/, /perform:\s*\{/,
        /\.onChange\(of:[^{]*\{/, /\.task\s*(?:\([^)]*\))?\s*\{/, /\.onAppear\s*\{/, /\.onDisappear\s*\{/,
        /\bTask\s*(?:\([^)]*\))?\s*\{/, /\bTimelineView\(/,
    ]

    private func clockSites(in file: SourceSweep.File) -> [Int] {
        var sites: [Int] = []
        for index in file.lines.indices {
            let code = file.code(index)
            if code.contains("Timer(timeInterval:"), code.contains("repeats: true") {
                sites.append(index)
            } else if code.trimmingCharacters(in: .whitespaces).hasPrefix("while ") {
                let loop = file.block(from: index)
                if loop.contains(where: { file.code($0).contains("Task.sleep(for: .milliseconds(") }) {
                    sites.append(index)
                }
            }
        }
        return sites
    }

    @Test func everyClockIsRegistered() throws {
        let sweep = try SourceSweep.app()
        var found: [String: Int] = [:]
        for file in sweep.files {
            let count = clockSites(in: file).count
            if count > 0 { found[file.name] = count }
        }
        let registered = clocks.mapValues(\.count)
        #expect(
            found == registered,
            "every repeating clock is registered with what its tick moves (found \(found.sorted { $0.key < $1.key }))"
        )
        for (file, ticks) in clocks {
            for case .moves(let moved) in ticks {
                for property in moved {
                    #expect(readers[property] != nil, "\(file) moves \(property): register its readers")
                }
            }
        }
    }

    @Test func tickingStateIsReadOnlyByItsLeaves() throws {
        let sweep = try SourceSweep.app()
        let views = sweep.viewTypes
        var violations: [String] = []
        for (property, reader) in readers {
            for file in sweep.files {
                for index in file.lines.indices where file.code(index).contains(reader.hint) {
                    let code = file.code(index)
                    for match in code.matches(of: reader.pattern) {
                        let column = code.distance(from: code.startIndex, to: match.range.lowerBound)
                        guard let type = file.enclosingType(of: index), views.contains(type),
                              !reader.views.contains(type), !inAction(file, index, column: column)
                        else { continue }
                        violations.append("\(file.name):\(index + 1) \(type) reads \(property)")
                    }
                }
            }
        }
        #expect(
            violations.isEmpty,
            "ticking state read in a big body redraws it every tick: read it in a small leaf view and register the leaf: \(violations)"
        )
    }

    private func inAction(_ file: SourceSweep.File, _ index: Int, column: Int) -> Bool {
        var position = (line: index, column: column)
        while let opener = file.opener(line: position.line, column: position.column) {
            let head = String(Array(file.code(opener.line)).prefix(opener.column + 1))
            if actionOpeners.contains(where: { head.contains($0) }) { return true }
            if head.contains("var body") || head.contains(" func ") || head.contains("struct ") { return false }
            position = opener
        }
        return false
    }

    @Test func applyWritesShowStateOnlyOnAChange() throws {
        let sweep = try SourceSweep.app()
        let file = try #require(sweep.file("ServiceControls.swift"))
        let start = try #require(file.lines.firstIndex { $0.contains("private func apply() {") })
        let body = Array(file.block(from: start))
        var writes = 0
        for (offset, index) in body.enumerated() {
            guard let write = file.code(index).firstMatch(of: /^\s*state\.([A-Za-z]+)\s*=[^=]/) else { continue }
            writes += 1
            let guardLine = body[..<offset].last { !file.code($0).trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(
                guardLine.map { file.code($0).contains("if state.\(write.1) != ") } == true,
                "ServiceControls.swift:\(index + 1) writes state.\(write.1) on every clock tick"
            )
        }
        #expect(writes >= 1)
    }

    @Test func slideGridHostsNeverReadTheLiveSlide() throws {
        let sweep = try SourceSweep.app()
        let hosts: Set<String> = ["SlideGridBody", "PresentGridView", "ServiceContinuousView"]
        let verbs: Set<String> = ["handleTap", "pasteFromKeyboard", "fireStep", "revealLive"]
        var violations: [String] = []
        var tileReads = 0
        for name in ["PresentGridView.swift", "ServiceContinuousView.swift"] {
            let file = try #require(sweep.file(name))
            for index in file.lines.indices
            where file.code(index).contains(/\b(liveOccurrence|liveContextID|slideAnimationStep)\b/) {
                let type = file.enclosingType(of: index)
                if type == "SlideTile" { tileReads += 1 }
                if let type, hosts.contains(type), !verbs.contains(file.enclosingMember(of: index) ?? "") {
                    violations.append("\(name):\(index + 1) \(type).\(file.enclosingMember(of: index) ?? "?")")
                }
            }
        }
        #expect(violations.isEmpty, "a grid host's body reads the live slide: every fire rebuilds its tile menus: \(violations)")
        #expect(tileReads > 0, "SlideTile reads the live slide itself")
    }

    @Test func slideFireStampsItsDeckOncePerGoingLive() throws {
        let sweep = try SourceSweep.app()
        let file = try #require(sweep.file("ServiceControls.swift"))
        let start = try #require(file.lines.firstIndex { $0.contains("private func land(") })
        let body = Array(file.block(from: start))
        let stamp = try #require(body.firstIndex { file.code($0).contains("appModel.markUsed(presentation.id)") })
        let guardLine = body[..<stamp].last { !file.code($0).trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(guardLine.map { file.code($0).contains("if !deckWasLive {") } == true)
        let captured = body.firstIndex { file.code($0).contains("let deckWasLive = livePresentationID == presentation.id") }
        let fired = body.firstIndex { file.code($0).contains("state.fire(") }
        #expect(captured != nil && fired != nil && captured! < fired!, "read the live deck before this fire replaces it")
    }

    @Test func noViewReadsTheRawPlayhead() throws {
        let sweep = try SourceSweep.app()
        for file in sweep.files where !file.name.hasPrefix("SlideEditorModel") {
            let reads = file.text.components(separatedBy: "model.animationPreviewPlayhead").count - 1
            #expect(reads == 0, "\(file.name) reads the 30 Hz playhead: read animationPreviewShownTime in a small leaf view")
        }
    }

    @Test func timelinePanelBodyNeverReadsTheTickingTime() throws {
        let sweep = try SourceSweep.app()
        let source = try #require(sweep.file("AnimationTimelinePanel.swift")).text
        let leaves = try #require(source.range(of: "private struct PlayheadReadout: View"))
        let panel = source[..<leaves.lowerBound]
        let leafSection = source[leaves.lowerBound...]
        #expect(!panel.contains("animationPreviewShownTime"), "the panel body must not read the ticking time")
        #expect(
            !panel.contains("animationPreviewTime"),
            "previewActive reads the stored animationPreviewActive: a scrub moves animationPreviewTime every drag step"
        )
        #expect(
            leafSection.contains(".frame(width: 84, alignment: .trailing)") && leafSection.contains(".frame(width: 34)"),
            "the ticking labels keep fixed widths: new digits must not re-lay out their rows"
        )
        for leaf in ["PlayheadReadout", "PlayheadHandle", "PlayheadLine"] {
            #expect(leafSection.contains("private struct \(leaf): View"))
            #expect(panel.contains("\(leaf)(model: model"), "the panel draws the playhead through \(leaf)")
        }
    }
}
