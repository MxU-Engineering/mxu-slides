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
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeaderBar {

            } trailing: {

                Toggle("Follow timecode", isOn: Binding(get: { follower.follows }, set: { follower.setFollows($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .help("Songs with a timecode start play from it on this computer")
            }
            startTimesPicker
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
                songsSection
            }
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
                .help("In service order: songs with a timeline start at 01:00, 02:00, … in run order, for this service only")
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var songsSection: some View {
        let songs = TimecodeFollower.songs(model)
        let clashes = TimecodeFollow.clashes(songs.map(\.song))
        if songs.isEmpty {
            Text("No song in this service plays from timecode. Turn it on beside a song's timecode start on its timeline.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if !clashes.isEmpty {
                Label(
                    "\(clashes.count) songs share a timecode start, so timecode can't tell them apart. Give each its own start in Playback and on its timeline.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(songs, id: \.item.id) { followed in
                    songRow(followed, clashes: clashes.contains(followed.item.id))
                }
            }
        }
    }

    @ViewBuilder
    private func songRow(_ followed: TimecodeFollower.FollowedSong, clashes: Bool) -> some View {
        let current = controls.timeline.itemID == followed.item.id
        HStack(spacing: 8) {
            Text(PresentationTimelines.timecode(frames: followed.song.startFrames))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(followed.item.name)
                .font(.system(size: 12, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if clashes {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Shares its timecode start with another song")
            }
        }
        .padding(.vertical, 3)

        if current {
            let deck = followed.presentation
            let rows = TimecodeFollow.cueRows(
                followed.timeline, start: followed.song.startFrames,
                blocks: SlideSceneBuilder.timelineBlocks(for: deck, arrangementId: followed.arrangementId)
            ) { id in deck.sections?.first { $0.id == id }?.name ?? "Slides" }
            ForEach(rows, id: \.id) { row in
                HStack(spacing: 8) {
                    Text(row.timecode)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
            }
        }
    }
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
