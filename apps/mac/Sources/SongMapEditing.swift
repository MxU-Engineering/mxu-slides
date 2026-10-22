import AppKit
import PresenterCore
import SlideScene
import SwiftUI

struct SongMapImport: Sendable {
    var set: SongMaps.AbletonSet
    var bpm: Double

    static func find(_ urls: [URL]) async -> SongMapImport? {
        await Task.detached(priority: .userInitiated) {
            let folders = urls.flatMap { url in
                url.hasDirectoryPath ? [url, url.deletingLastPathComponent()]
                    : [url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()]
            }
            for folder in folders {
                let file = folder.appendingPathComponent("MultiTrack.als")
                guard let data = try? Data(contentsOf: file), let set = SongMaps.abletonSet(data), !set.locators.isEmpty else { continue }

                let bpm = SongMaps.bpm(folderName: folder.lastPathComponent) ?? set.tempo.first?.bpm ?? 120
                DiagnosticsStore.shared.note("timeline.songMap.found", detail: "\(set.locators.count) locators, \(bpm) bpm")
                return SongMapImport(set: set, bpm: bpm)
            }
            return nil
        }.value
    }
}

extension PresentationTimelineController {

    @discardableResult
    func layOutFromMap(presentationID: String, arrangementId: String?) -> Bool {
        guard let model = controls?.appModel, let deck = model.presentation(presentationID), let map = deck.songMap else { return false }
        let blocks = SlideSceneBuilder.timelineBlocks(for: deck, arrangementId: arrangementId)
        let timeline = PresentationTimelines.timeline(for: arrangementId, in: deck) ?? PresentationTimeline(
            id: UUID().uuidString, arrangementId: arrangementId.flatMap { $0.isEmpty ? nil : $0 },
            timecodeEnabled: false, timecodeStart: deck.timelines?.first?.timecodeStart ?? 3600 * PresentationTimelines.framesPerSecond,
            cues: [])
        guard let laid = SongMaps.laidOut(map, blocks: blocks, timeline: timeline) else { return false }
        save(laid, presentationID: deck.id, undoLabel: nil)
        DiagnosticsStore.shared.note("timeline.songMap.laid", detail: "\(laid.mapLayout?.count ?? 0) blocks, \(laid.cues.count) cues")
        return true
    }
}

struct SongMapSheet: View {
    let context: PresentationTimelineContext
    let done: () -> Void

    private var deck: Presentation { context.model.presentation(context.presentation.id) ?? context.presentation }

    var body: some View {
        let deck = deck
        let map = deck.songMap
        VStack(alignment: .leading, spacing: 10) {
            Text("Section Map").font(.headline)
            Text("Where each section is in this song's recording. Every arrangement plays its sections' audio in its order; the slides ride with their section.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let map {
                let slideSections = deck.sections ?? []
                List {
                    ForEach(map.sections, id: \.id) { section in
                        row(section, slideSections: slideSections)
                    }
                }
                .frame(minHeight: 220)
                let missing = SongMaps.missing(
                    map, blocks: context.blocks, names: Dictionary(slideSections.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
                if !missing.isEmpty {
                    Label("\(missing.joined(separator: ", ")) \(missing.count == 1 ? "has" : "have") no audio in this song's tracks", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Add Marker at Playhead") { addMarker(map) }
                        .help("A new section starting where the playhead is in the recording")
                    Spacer()
                    Button("Remove Section Map", role: .destructive) { write(nil, "Remove Section Map") }
                        .help("This song's timelines stay as they are now")
                }
            } else {
                Text("This song has no section map. Make one from this timeline's audio, then add a marker where each section starts.")
                    .font(.caption)
                Button("Make Section Map") {
                    write(SongMap(recording: context.timeline?.cues ?? [], sections: []), "Make Section Map")
                }
                .disabled(TimelineTracks.stems(context.timeline?.cues ?? []).isEmpty
                          && !(context.timeline?.cues ?? []).contains(where: TimelineClips.isClip))
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func row(_ section: AudioSection, slideSections: [PresentationSection]) -> some View {
        HStack(spacing: 6) {
            Text(PresentationTimelineLanes.clock(section.start))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            Stepper("", onIncrement: { nudge(section, by: PresentationTimelines.frame) }, onDecrement: { nudge(section, by: -PresentationTimelines.frame) })
                .labelsHidden()
                .help("A frame later or earlier")
            TextField("Name", text: Binding(get: { section.name }, set: { name in edit(section) { $0.name = name } }))
                .textFieldStyle(.roundedBorder)
            Picker("", selection: Binding(get: { section.sectionId ?? "" }, set: { id in edit(section) { $0.sectionId = id.isEmpty ? nil : id } })) {
                Text("No slides").tag("")
                ForEach(slideSections, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 120)
            .help("The slide section this audio plays")
            Button {
                guard var map = deck.songMap else { return }
                map.sections.removeAll { $0.id == section.id }
                write(map, "Remove Marker")
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this marker")
        }
    }

    private func edit(_ section: AudioSection, _ change: (inout AudioSection) -> Void) {
        guard var map = deck.songMap, let index = map.sections.firstIndex(where: { $0.id == section.id }) else { return }
        change(&map.sections[index])
        map.sections.sort { $0.start < $1.start }
        write(map, "Edit Section Map")
    }

    private func nudge(_ section: AudioSection, by seconds: Double) {
        edit(section) { $0.start = max(0, PresentationTimelines.snappedToFrame($0.start + seconds)) }
    }

    private func addMarker(_ map: SongMap) {
        let time = context.clock.insertionTime(for: context.item.id)
        let start = SongMaps.recordingTime(time, map: map, layout: context.timeline?.mapLayout)
        write(SongMaps.adding("Section", at: start, to: map, slideSections: deck.sections ?? []), "Add Marker")
    }

    private func write(_ map: SongMap?, _ label: String) {
        context.model.updatePresentationField(context.presentation.id, \.songMap, key: "songMap", to: map, undoLabel: label)
        context.clock.layOutFromMap(presentationID: context.presentation.id, arrangementId: context.item.arrangementId)
    }
}
