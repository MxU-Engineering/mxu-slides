import PresenterCore
import SlideScene
import SwiftUI

struct TimecodeModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.openSettings) private var openSettings
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let follower = controls.timecode
        let rows = rows()
        let songs = rows.filter { $0.timeline?.timecodeEnabled == true }
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeaderBar {

            } trailing: {

                Toggle("Follow timecode", isOn: Binding(get: { follower.follows }, set: { follower.setFollows($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .help("Songs with a timecode start play from it on this computer")
            }
            HStack(spacing: 8) {
                startTimesPicker
                Spacer(minLength: 0)
                if !songs.isEmpty { expandAllButton(songs) }
            }
            if !follower.hasInput {
                Text("No timecode input on this computer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Set Up Timecode…") {
                    SettingsRouter.shared.pending = .midi
                    openSettings()
                }
                .controlSize(.small)
            } else {
                TimecodeModuleReadout(follower: follower)
            }

            songsSection(rows)
        }
    }

    @ViewBuilder
    private var startTimesPicker: some View {
        if let serviceID = model.currentServiceID, let service = try? model.service(serviceID) {
            let byOrder = service.timecodeByOrder == true
            HStack(spacing: 4) {
                Text("Start times:")
                    .foregroundStyle(.secondary)
                Menu {
                    Picker("Start times", selection: Binding(
                        get: { byOrder },
                        set: { on in model.updateService(serviceID) { $0.timecodeByOrder = on ? true : nil } }
                    )) {
                        Text("Saved with each song").tag(false)
                        Text("In service order").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(byOrder ? "In service order" : "Saved with each song")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(runOnly)
                .help("In service order: songs that play from timecode start at 01:00, 02:00, … in run order, for this service only")
            }
            .font(.caption)
        }
    }

    struct Row {
        var item: ServiceItem
        var deck: Presentation?
        var timeline: PresentationTimeline?
        var start: Int?
    }

    private func rows() -> [Row] {
        guard let serviceID = model.currentServiceID, let service = try? model.service(serviceID) else { return [] }
        let starts = TimecodeFollower.starts(model, service: service)
        return model.runOfShow(service).compactMap { item in
            switch item.itemKind {
            case .header:
                return Row(item: item)
            case .presentation:
                let deck = model.presentation(item.refId)
                return Row(
                    item: item, deck: deck,
                    timeline: deck.flatMap { PresentationTimelines.timeline(for: item.arrangementId, in: $0) },
                    start: starts[item.id])
            default:
                return nil
            }
        }
    }

    private func isOpen(_ itemID: String) -> Bool {
        TimecodeModuleSongs.shared.open[itemID] ?? (controls.timeline.itemID == itemID)
    }

    private func expandAllButton(_ songs: [Row]) -> some View {
        let allOpen = songs.allSatisfy { isOpen($0.item.id) }
        return Button {
            var open = TimecodeModuleSongs.shared.open
            for song in songs { open[song.item.id] = !allOpen }
            TimecodeModuleSongs.shared.open = open
        } label: {
            Image(systemName: allOpen ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(allOpen ? "Collapse All" : "Expand All")
        .help(allOpen ? "Collapse all songs" : "Expand all songs")
    }

    @ViewBuilder
    private func songsSection(_ rows: [Row]) -> some View {
        let songs = rows.compactMap { row in
            row.timeline.flatMap { $0.timecodeEnabled ? TimecodeFollow.Song(itemID: row.item.id, timeline: $0, start: row.start) : nil }
        }
        let clashes = TimecodeFollow.clashes(songs)
        if !rows.contains(where: { $0.item.itemKind == .presentation }) {
            Text("No presentations in this service.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            if !clashes.isEmpty {
                Label(
                    "\(clashes.count) songs share a timecode start, so timecode can't tell them apart. Give each its own start in Playback and here.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.item.id) { row in
                    if row.item.itemKind == .header {
                        ModuleSectionLabel(row.item.name)
                            .padding(.top, 6)
                    } else {
                        songRow(row, clashes: clashes.contains(row.item.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func songRow(_ row: Row, clashes: Bool) -> some View {
        let current = controls.timeline.itemID == row.item.id
        let on = row.timeline?.timecodeEnabled == true
        let open = on && isOpen(row.item.id)
        let byOrder = model.currentServiceID.flatMap { try? model.service($0) }?.timecodeByOrder == true
        HStack(spacing: 6) {
            Button {
                TimecodeModuleSongs.shared.open[row.item.id] = !open
            } label: {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(on ? 1 : 0)
            .disabled(!on)
            .accessibilityLabel(open ? "Collapse" : "Expand")
            .help(open ? "Hide this song's cues" : "Show this song's cues")
            Toggle("", isOn: Binding(
                get: { on },
                set: { play in edit(row, play ? "Play from Timecode" : "Stop Playing from Timecode") { $0.timecodeEnabled = play } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .disabled(runOnly || row.deck == nil)
                .help("Plays from timecode")
            if on, byOrder, let start = row.start {
                Text(PresentationTimelines.timecode(frames: start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                    .help("By order in this service")
            } else if on, let start = row.start {
                TimecodeStartField(frames: start) { frames in edit(row, "Timecode Start") { $0.timecodeStart = frames } }
                    .disabled(runOnly)
            } else {
                Text("--:--:--:--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.quaternary)
                    .frame(width: 78, alignment: .leading)
            }
            Text(row.item.name)
                .font(.system(size: 12, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? Color.accentColor : on ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if clashes {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Shares its timecode start with another song")
            }
        }
        .padding(.vertical, 2)

        if open, let deck = row.deck, let timeline = row.timeline {
            let cues = TimecodeFollow.cueRows(
                timeline, start: row.start,
                blocks: SlideSceneBuilder.timelineBlocks(for: deck, arrangementId: row.item.arrangementId)
            ) { id in deck.sections?.first { $0.id == id }?.name ?? "Slides" }
            ForEach(cues, id: \.id) { cue in
                HStack(spacing: 8) {
                    Text(cue.timecode)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(cue.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 38)
            }
        }
    }

    private func edit(_ row: Row, _ undoLabel: String, _ change: (inout PresentationTimeline) -> Void) {
        guard let serviceID = model.currentServiceID, let deck = row.deck else { return }
        PresentationTimelineContext(model: model, controls: controls, serviceID: serviceID, item: row.item, presentation: deck)
            .edit(undoLabel, change)
    }
}

struct TimecodeStartField: View {
    let frames: Int
    let set: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("HH:MM:SS:FF", text: $text)
            .textFieldStyle(.plain)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle.standard(CornerStandard.element))
            .frame(width: 78)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onAppear { text = PresentationTimelines.timecode(frames: frames) }
            .onChange(of: frames) { text = PresentationTimelines.timecode(frames: frames) }
            .help("Timecode start, saved with the song")
    }

    private func commit() {
        if let typed = PresentationTimelines.frames(timecode: text), typed != frames {
            set(typed)
        } else {
            text = PresentationTimelines.timecode(frames: frames)
        }
    }
}

@MainActor
@Observable
final class TimecodeModuleSongs {
    static let shared = TimecodeModuleSongs()
    var open: [String: Bool] = [:]
}

struct TimecodeModuleReadout: View {
    let follower: TimecodeFollower

    var body: some View {
        let reading = follower.timecodeReading
        let status = TimecodeFollower.status(reading, follows: follower.follows)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(reading.label.map { $0.text(dropFrame: reading.rate == .fps2997DropFrame) } ?? "--:--:--:--")
                .font(.system(size: 20, weight: .medium).monospacedDigit())
                .fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                Text(status.word)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.color)
                Text(follower.detectedRate.map { $0 == .fps2997DropFrame ? "29.97 DF" : $0.title } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 56, alignment: .leading)
        }
    }
}
