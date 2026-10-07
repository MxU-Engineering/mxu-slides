import Foundation
import Testing

@Suite struct BodyMeterSweepTests {
    private let required = [
        "ShellView", "LibrarySidebar", "SlideEditorView", "SlideObjectInspector", "AnimationTimelinePanel",
    ]

    @Test func everyMeteredViewTicksFirstInItsBody() throws {
        let sweep = try SourceSweep.app()
        let meter = try #require(sweep.file("BodyMeter.swift")).text

        let named = meter.matches(of: /case \.([A-Za-z]+): "([A-Za-z]+)"/).map { (String($0.1), String($0.2)) }
        #expect(Set(named.map(\.1)).isSuperset(of: required), "metered: \(named.map(\.1))")
        for (member, view) in named {
            let file = try #require(
                sweep.files.first { file in file.lines.contains { $0.hasPrefix("struct \(view)") } },
                "\(view) not found")
            let start = try #require(file.lines.firstIndex { $0.hasPrefix("struct \(view)") })
            let body = try #require(
                file.lines[start...].firstIndex { $0.hasPrefix("    var body: some View {") }, "\(view).body")
            #expect(
                file.lines[body + 1].trimmingCharacters(in: .whitespaces) == "let _ = BodyMeter.tick(.\(member))",
                "\(file.name):\(body + 2) \(view).body must start with `let _ = BodyMeter.tick(.\(member))`"
            )
        }
    }

    @Test func aTickAllocatesNothingOnTheQuietPath() throws {
        let sweep = try SourceSweep.app()
        let meter = try #require(sweep.file("BodyMeter.swift"))
        let start = try #require(meter.lines.firstIndex { $0.contains("static func tick(_ view: MeteredView)") })
        let body = meter.block(from: start).map { meter.code($0) }
        let stormLine = try #require(body.firstIndex { $0.contains("if let storm") })
        let quiet = body[...stormLine].joined(separator: "\n")
        #expect(!quiet.contains("\""), "no string on the quiet path")
        #expect(quiet.contains("bodyMeter.withLock"))
    }
}
