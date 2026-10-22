import AudioEngine
import PresenterCore
import SwiftUI

struct TracksMixerButton: View {
    let model: AppModel
    let tracks: TracksController
    @Environment(\.runOnly) private var runOnly
    @State private var open = false
    @State private var newName = ""

    var body: some View {
        let tracksOn = TimelineTracks.hasTracks(model.trackChannels)
        Button {
            open = true
        } label: {

            HStack(spacing: 3) {
                Image(systemName: "square.stack.3d.down.right")
                Text("Tracks").font(.caption)
            }
            .foregroundStyle(tracksOn ? AnyShapeStyle(Color.purple) : AnyShapeStyle(.secondary))
            .font(.system(size: 12))
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tracksOn ? "Tracks: where click, guide and the tracks go" : "Tracks: a song's stems, played through this mixer")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if tracksOn {
                TracksSetupGuide(model: model) { open = false }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tracks").font(.headline)
                    Text("No tracks yet. Add one here, or import a song's stems in its timeline (+ › Tracks, then Import Audio…).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Track name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addTrack)
                        Button("Add Track", action: addTrack)
                            .keyboardShortcut(.defaultAction)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .disabled(runOnly)
                }
                .padding(16)
                .frame(width: 320)
            }
        }
    }
}

extension TracksMixerButton {

    private func addTrack() {
        guard tracks.addChannel(named: newName) != nil else { return }
        newName = ""
    }
}

struct TracksSetupGuide: View {
    let model: AppModel
    let done: () -> Void
    @State private var mixes = AudioMixInventory.shared
    @State private var outputs = AudioOutputInventory.shared
    @State private var devices: [AudioOutputDevice] = []
    @AppStorage("tracks.setupInterface") private var interfaceUID = ""
    @AppStorage("tracks.setupOutputs") private var count = 2
    @AppStorage("tracks.setupStart") private var start = 0
    @Environment(\.runOnly) private var runOnly

    static let maxOutputs = 32

    var body: some View {
        let device = devices.first { $0.uid == interfaceUID }
        let most = min(Self.maxOutputs, device?.channelCount ?? 0)
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Tracks").font(.headline)
            Picker("Audio interface", selection: $interfaceUID) {
                ForEach(devices, id: \.uid) { Text("\($0.name) (\($0.channelCount) outputs)").tag($0.uid) }
            }
            .frame(width: 400)
            HStack(spacing: 6) {
                Text("Outputs to your sound board")
                TextField("", value: Binding(get: { count }, set: { count = min(max($0, 0), most) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Stepper("", value: $count, in: 0 ... max(most, 0)).labelsHidden()
                if count > 0, let device {
                    Text("starting at")
                    Picker("", selection: $start) {
                        ForEach(0 ... max(0, device.channelCount - count), id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 64)
                }
            }
            Text(count == 0
                ? "None: the tracks play from this computer's main output. Give click and guide outputs below for the band."
                : "Each mix below goes to its own output on \(device?.name ?? "the interface"). Change any of them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(TimelineTracks.Family.allCases, id: \.self) { family in
                    GridRow {
                        Text(family.name).gridColumnAlignment(.trailing)
                        mixRow(family, device)
                    }
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Done") {

                    if let folder = mixes.folders.first(where: { $0.name == "Tracks" }),
                       !MixerGroupStore.shared.isExpanded("folder:\(folder.id)") {
                        MixerGroupStore.shared.toggle("folder:\(folder.id)")
                    }
                    done()
                }

            }
        }
        .padding(16)
        .frame(width: 460)
        .disabled(runOnly)
        .task {
            devices = AudioDeviceList.outputDevices()
            if !devices.contains(where: { $0.uid == interfaceUID }) {
                interfaceUID = (devices.first { $0.channelCount > 2 } ?? devices.first)?.uid ?? ""
            }
        }

        .onChange(of: count) { lay(device) }
        .onChange(of: start) { lay(device) }
        .onChange(of: interfaceUID) { old, _ in

            guard !old.isEmpty else { return }
            let fresh = devices.first { $0.uid == interfaceUID }
            count = min(count, min(Self.maxOutputs, fresh?.channelCount ?? 0))
            start = min(start, max(0, (fresh?.channelCount ?? 0) - count))
            lay(fresh)
        }
    }

    private func lay(_ device: AudioOutputDevice?) {
        guard count > 0, let device else {
            TracksController.setMusicOnMain(true, model.trackChannels)
            return
        }
        let layout = TimelineTracks.layout(fitting: count)
        for family in TimelineTracks.Family.allCases {
            guard let channels = layout[family] else {
                assign(family, device, channel: nil, stereo: false)
                continue
            }
            assign(family, device, channel: start + channels[0], stereo: channels.count == 2)
        }
        TracksController.setMusicOnMain(false, model.trackChannels)
    }

    private func mixRow(_ family: TimelineTracks.Family, _ device: AudioOutputDevice?) -> some View {
        let now = current(family, device)
        let last = (device?.channelCount ?? 0) - (now.stereo ? 1 : 0)
        return HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { now.channel ?? -1 },
                set: { assign(family, device, channel: $0 < 0 ? nil : $0, stereo: now.stereo) }
            )) {
                Text("Not yet").tag(-1)
                ForEach(0 ..< max(0, last), id: \.self) { channel in
                    Text(now.stereo ? "Outputs \(channel + 1)\u{2013}\(channel + 2)" : "Output \(channel + 1)").tag(channel)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: 150, alignment: .leading)
            Picker("", selection: Binding(
                get: { now.stereo },
                set: { stereo in

                    let channel = now.channel.map { stereo ? min($0, (device?.channelCount ?? 2) - 2) : $0 }
                    assign(family, device, channel: channel, stereo: stereo)
                }
            )) {
                Text("Mono").tag(false)
                Text("Stereo").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
        }
    }

    private func current(_ family: TimelineTracks.Family, _ device: AudioOutputDevice?) -> (channel: Int?, stereo: Bool) {
        guard let device, let mix = TracksController.existingBus(family),
              let output = outputs.entry(id: mixes.primaryToken(mixId: mix.id)), output.deviceUID == device.uid
        else { return (nil, family != .click && family != .guide) }
        return output.monoChannel.map { ($0, false) } ?? (output.channelOffset, true)
    }

    private func assign(_ family: TimelineTracks.Family, _ device: AudioOutputDevice?, channel: Int?, stereo: Bool) {
        let mix = TracksController.familyBus(family)
        guard let device, let channel else {
            mixes.setPrimary(mixId: mix.id, token: AudioMixInventory.noOutputID)
            return
        }
        let output = stereo
            ? outputs.ensurePair(device: device, offset: channel)
            : outputs.ensureMono(device: device, channel: channel)
        mixes.setPrimary(mixId: mix.id, token: output.id)
    }
}
