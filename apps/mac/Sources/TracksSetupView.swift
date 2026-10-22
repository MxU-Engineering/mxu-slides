import AudioEngine
import PresenterCore
import SwiftUI

struct TracksMixerButton: View {
    let model: AppModel
    @AppStorage(TracksController.enabledKey) private var tracksOn = false
    @Environment(\.runOnly) private var runOnly
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Image(systemName: "square.stack.3d.down.right")
                .moduleHeaderGlyph(tracksOn ? AnyShapeStyle(Color.purple) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(tracksOn ? "Tracks: where click, guide and the tracks go" : "Tracks: play songs' stems from this computer")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if tracksOn {
                TracksSetupGuide(model: model) { open = false }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tracks").font(.headline)
                    Text("Play songs' stems (click, guide and backing tracks) from this computer, through this mixer: a Tracks strip, and a mix for each instrument family to send where the band and the room need them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Turn On Tracks") { tracksOn = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(runOnly)
                }
                .padding(16)
                .frame(width: 320)
            }
        }
    }
}

struct TracksSetupGuide: View {
    let model: AppModel
    let done: () -> Void
    @State private var mixes = AudioMixInventory.shared
    @State private var outputs = AudioOutputInventory.shared
    @State private var devices: [AudioOutputDevice] = []
    @AppStorage("tracks.setupInterface") private var interfaceUID = ""
    @AppStorage("tracks.setupOutputs") private var layoutSize = 2
    @AppStorage("tracks.setupStart") private var layoutStart = 0
    @State private var applied: String?
    @Environment(\.runOnly) private var runOnly

    private static let roomFamilies = TimelineTracks.Family.allCases.filter { $0 != .click && $0 != .guide }

    private static let notYet = -1
    private static let pairBase = 1000

    var body: some View {
        let device = devices.first { $0.uid == interfaceUID }
        let fits = TimelineTracks.layoutSizes.filter { $0 <= (device?.channelCount ?? 0) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Tracks").font(.headline)
            Picker("Audio interface", selection: $interfaceUID) {
                ForEach(devices, id: \.uid) { Text("\($0.name) (\($0.channelCount) outputs)").tag($0.uid) }
            }
            .frame(width: 400)
            VStack(alignment: .leading, spacing: 8) {
                Text("How many outputs go to your sound board?").font(.subheadline.weight(.medium))
                ChipPicker(options: [(0, "None")] + fits.map { ($0, "\($0)") }, selection: $layoutSize)
                if layoutSize == 0 {
                    Text("No sound board: the tracks play from this computer's main output. Click and guide wait until you give them outputs below.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let device {
                    HStack(spacing: 6) {
                        Text("Starting at output")
                        Picker("", selection: $layoutStart) {
                            ForEach(0 ... max(0, device.channelCount - layoutSize), id: \.self) { Text("\($0 + 1)").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }
                    .font(.caption)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(TimelineTracks.layoutRows(outputs: layoutSize).enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.outputLabel(row.channels.map { $0 + layoutStart }))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 110, alignment: .leading)
                                Text(Self.carries(row.families))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle.standard(CornerStandard.element))
                }
                Button(layoutSize == 0 ? "Play Tracks from This Computer" : "Set Up These Outputs") { apply(device) }
                    .disabled(runOnly || (layoutSize > 0 && device == nil))
                if let applied { Text(applied).font(.caption).foregroundStyle(.secondary) }
            }
            DisclosureGroup("Change which mixes go where") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(TimelineTracks.Family.allCases, id: \.self) { family in outputRow(family, device) }
                }
                .padding(.top, 4)
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
                .keyboardShortcut(.defaultAction)
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
        .onChange(of: fits) { _, fits in

            if layoutSize > 0, !fits.contains(layoutSize) { layoutSize = fits.last ?? 0 }
            layoutStart = min(layoutStart, max(0, (device?.channelCount ?? 0) - layoutSize))
        }
    }

    static func outputLabel(_ channels: [Int]) -> String {
        channels.count == 2 ? "Outputs \(channels[0] + 1)\u{2013}\(channels[1] + 1)" : "Output \(channels[0] + 1)"
    }

    static func carries(_ families: [TimelineTracks.Family]) -> String {
        families.count == roomFamilies.count && Set(families) == Set(roomFamilies)
            ? "All the tracks" : families.map(\.name).joined(separator: ", ")
    }

    private func apply(_ device: AudioOutputDevice?) {
        guard layoutSize > 0, let device else {
            TracksController.setMusicOnMain(true, model.trackChannels)
            applied = "The tracks play from this computer's main output."
            return
        }
        for (family, channels) in TimelineTracks.layout(outputs: layoutSize) {
            let first = layoutStart + channels[0]
            assign(family, device, channels.count == 2 ? Self.pairBase + first : first)
        }
        TracksController.setMusicOnMain(false, model.trackChannels)
        applied = "Set up \(layoutSize) outputs on \(device.name), from output \(layoutStart + 1)."
    }

    private func outputRow(_ family: TimelineTracks.Family, _ device: AudioOutputDevice?) -> some View {
        Picker(family.name, selection: Binding(
            get: { current(family, device) },
            set: { assign(family, device, $0) }
        )) {
            Text("Not yet").tag(Self.notYet)
            if let device {
                ForEach(0 ..< device.channelCount, id: \.self) { Text("Output \($0 + 1)").tag($0) }
                Divider()
                ForEach(Array(stride(from: 0, to: device.channelCount - 1, by: 2)), id: \.self) {
                    Text("Outputs \($0 + 1)-\($0 + 2) (stereo)").tag(Self.pairBase + $0)
                }
            }
        }
        .frame(width: 330)
    }

    private func current(_ family: TimelineTracks.Family, _ device: AudioOutputDevice?) -> Int {
        guard let device, let mix = TracksController.existingBus(family),
              let output = outputs.entry(id: mixes.primaryToken(mixId: mix.id)), output.deviceUID == device.uid
        else { return Self.notYet }
        return output.monoChannel ?? (Self.pairBase + output.channelOffset)
    }

    private func assign(_ family: TimelineTracks.Family, _ device: AudioOutputDevice?, _ tag: Int) {
        let mix = TracksController.familyBus(family)
        guard let device, tag != Self.notYet else {
            mixes.setPrimary(mixId: mix.id, token: AudioMixInventory.noOutputID)
            return
        }
        let output = tag >= Self.pairBase
            ? outputs.ensurePair(device: device, offset: tag - Self.pairBase)
            : outputs.ensureMono(device: device, channel: tag)
        mixes.setPrimary(mixId: mix.id, token: output.id)
    }
}
