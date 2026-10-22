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
        VStack(alignment: .leading, spacing: 10) {

            ModuleHeaderBar {
                startTimesPicker
            } trailing: {

                Toggle("Follow timecode", isOn: Binding(get: { follower.follows }, set: { follower.setFollows($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .help("Items with a timecode start play from it on this computer")
            }
            TimecodeModuleReadout(follower: follower) {
                SettingsRouter.shared.pending = .midi
                openSettings()
            }
            Divider()

            songsSection(rows)
        }
    }

    @ViewBuilder
    private var startTimesPicker: some View {
        if let serviceID = model.currentServiceID, let service = try? model.service(serviceID) {
            let byOrder = service.timecodeByOrder == true
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
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(runOnly)
            .accessibilityLabel("Start times")
            .help("Start times. In service order: items that play from timecode start at 01:00, 02:00, … in run order, for this service only")
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

    @ViewBuilder
    private func expandAllHeader(_ ids: [String]) -> some View {
        if !ids.isEmpty {
            let allOpen = ids.allSatisfy(isOpen)
            Button {
                var open = TimecodeModuleSongs.shared.open
                for id in ids { open[id] = !allOpen }
                TimecodeModuleSongs.shared.open = open
            } label: {
                HStack(spacing: TimecodeGrid.gap) {
                    TimecodeGrid.chevron(open: allOpen)
                    ModuleSectionLabel(allOpen ? "Collapse all" : "Expand all")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(allOpen ? "Collapse All" : "Expand All")
        }
    }

    @ViewBuilder
    private func songsSection(_ rows: [Row]) -> some View {
        let songs = rows.compactMap { row in
            row.timeline.flatMap { $0.timecodeEnabled ? TimecodeFollow.Song(itemID: row.item.id, timeline: $0, start: row.start) : nil }
        }
        let clashes = TimecodeFollow.clashes(songs)

        let cues = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [TimecodeFollow.CueRow])? in
            guard let deck = row.deck, let timeline = row.timeline, timeline.timecodeEnabled else { return nil }
            return (row.item.id, TimecodeFollow.cueRows(
                timeline, start: row.start,
                blocks: SlideSceneBuilder.timelineBlocks(for: deck, arrangementId: row.item.arrangementId)
            ) { id in deck.sections?.first { $0.id == id }?.name ?? "Slides" })
        })
        let expandable = rows.map(\.item.id).filter { cues[$0]?.isEmpty == false }
        if !rows.contains(where: { $0.item.itemKind == .presentation }) {
            Text("No presentations in this service.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            if !clashes.isEmpty {
                Label(
                    "\(clashes.count) items share a timecode start, so timecode can't tell them apart. Give each its own start in Playback and here.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                expandAllHeader(expandable)
                ForEach(rows, id: \.item.id) { row in
                    if row.item.itemKind == .header {
                        ModuleSectionLabel(row.item.name)
                            .padding(.leading, TimecodeGrid.lead + TimecodeGrid.gap)
                            .padding(.top, 6)
                    } else {
                        songRow(row, cues: cues[row.item.id] ?? [], clashes: clashes.contains(row.item.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func songRow(_ row: Row, cues: [TimecodeFollow.CueRow], clashes: Bool) -> some View {
        let current = controls.timeline.itemID == row.item.id
        let on = row.timeline?.timecodeEnabled == true
        let open = !cues.isEmpty && isOpen(row.item.id)
        let byOrder = model.currentServiceID.flatMap { try? model.service($0) }?.timecodeByOrder == true
        HStack(spacing: TimecodeGrid.gap) {
            Button {
                TimecodeModuleSongs.shared.open[row.item.id] = !open
            } label: {
                TimecodeGrid.chevron(open: open)
            }
            .buttonStyle(.plain)

            .opacity(cues.isEmpty ? 0 : 1)
            .disabled(cues.isEmpty)
            .accessibilityLabel(open ? "Collapse" : "Expand")
            .help(open ? "Hide this item's cues" : "Show this item's cues")

            Button {
                edit(row, on ? "Stop Playing from Timecode" : "Play from Timecode") { $0.timecodeEnabled = !on }
            } label: {
                Image(systemName: on ? "clock.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: TimecodeGrid.icon)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(runOnly || row.deck == nil)
            .accessibilityLabel("Plays from Timecode")
            .accessibilityValue(on ? "On" : "Off")
            .help(on ? "Plays from timecode" : "Doesn't play from timecode")
            if on, byOrder, let start = row.start {
                Text(PresentationTimelines.timecode(frames: start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: TimecodeGrid.time, alignment: .leading)
                    .help("By order in this service")
            } else if on, let start = row.start {
                TimecodeStartField(frames: start) { frames in edit(row, "Timecode Start") { $0.timecodeStart = frames } }
                    .disabled(runOnly)
            } else {

                Color.clear.frame(width: TimecodeGrid.time, height: 1)
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
                    .help("Shares its timecode start with another item")
            }
        }
        .padding(.vertical, 2)
        if open {
            ForEach(cues, id: \.id) { cue in
                HStack(spacing: TimecodeGrid.gap) {
                    Text(cue.timecode)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: TimecodeGrid.time, alignment: .leading)
                    Text(cue.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, TimecodeGrid.timeX)
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

            .frame(width: TimecodeGrid.time, alignment: .leading)
            .background(
                RoundedRectangle.standard(CornerStandard.element)
                    .fill(Color.primary.opacity(0.06))
                    .padding(.horizontal, -3))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onAppear { text = PresentationTimelines.timecode(frames: frames) }
            .onChange(of: frames) { text = PresentationTimelines.timecode(frames: frames) }
            .help("Timecode start, saved with the presentation")
    }

    private func commit() {
        if let typed = PresentationTimelines.frames(timecode: text), typed != frames {
            set(typed)
        } else {
            text = PresentationTimelines.timecode(frames: frames)
        }
    }
}

enum TimecodeGrid {
    static let lead: CGFloat = 12
    static let icon: CGFloat = 14
    static let time: CGFloat = 84
    static let gap: CGFloat = 6

    static let timeX = lead + gap + icon + gap

    static func chevron(open: Bool) -> some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: lead, height: 14)
            .contentShape(Rectangle())
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
    let openSettings: () -> Void

    var body: some View {
        let reading = follower.timecodeReading
        let running = follower.follows && (reading.state == .locked || reading.state == .freewheel)
        VStack(spacing: 2) {
            Text(reading.label.map { $0.text(dropFrame: reading.rate == .fps2997DropFrame) } ?? "--:--:--:--")
                .font(.system(size: 22, weight: .medium).monospacedDigit())
                .foregroundStyle(running ? Color.primary : Color.secondary.opacity(0.6))
                .fixedSize()
            if let issue = issue {
                HStack(spacing: 4) {
                    Text(issue.text)
                        .foregroundStyle(issue.fault ? Color.red : Color.secondary)

                    Button(issue.fault ? "Settings…" : "Choose Input…", action: openSettings)
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var issue: (text: String, fault: Bool)? {
        if !follower.hasInput { return ("No timecode input", false) }

        let missingMIDI = if case .midi(let uid) = follower.input {
            !MIDIDeviceInventory.shared.discoveredSources.contains { $0.uid == uid }
        } else {
            false
        }
        if follower.problem != nil || missingMIDI { return ("Timecode input not connected", true) }
        if follower.noTimecode {
            if case .audio = follower.input { return ("No timecode on channel \(follower.channel + 1)", true) }
            return ("No timecode", true)
        }
        return nil
    }
}
