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
    @State private var patchDevice = ""
    @State private var patchStart = 0
    @State private var patched: String?
    @AppStorage(TracksController.offMainKey) private var offMain = false
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let wide = devices.filter { $0.channelCount > 2 }
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Tracks").font(.headline)
            step(1, "Where does the band hear click and guide?") {
                outputPicker("Click", .click)
                outputPicker("Guide", .guide)
                Text("Pick the in-ear outputs. Until then they go nowhere, never to the room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            step(2, "How does the room hear the tracks?") {
                Picker("", selection: Binding(
                    get: { offMain },
                    set: { TracksController.setMusicOnMain(!$0, model.trackChannels) }
                )) {
                    Text("Straight from this Mac (on Main)").tag(false)
                    Text("Through the sound desk (each family mix to its own channel)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            step(3, "Patch the family mixes to a multichannel interface") {
                if wide.isEmpty {
                    Text("No multichannel interface is connected. Patch the mixes in the mixer when it is.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Picker("Interface", selection: $patchDevice) {
                            ForEach(wide, id: \.uid) { Text("\($0.name) (\($0.channelCount))").tag($0.uid) }
                        }
                        Picker("From channel", selection: $patchStart) {
                            ForEach(0 ..< (wide.first { $0.uid == patchDevice }?.channelCount ?? 16), id: \.self) {
                                Text("\($0 + 1)").tag($0)
                            }
                        }
                        .frame(width: 140)
                    }
                    Button("Patch Click, Guide, Drums, \u{2026} in Order") { patch(wide) }
                        .disabled(runOnly || patchDevice.isEmpty)
                    Text(patched ?? "One channel each: Click, Guide, Drums, Percussion, Bass, Electric Guitars, Acoustic Guitars, Keys, Synths & Pads, Vocals, Strings, Other.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        .frame(width: 420)
        .disabled(runOnly)
        .task {
            devices = AudioDeviceList.outputDevices()
            if patchDevice.isEmpty { patchDevice = devices.first { $0.channelCount > 2 }?.uid ?? "" }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number). \(title)").font(.subheadline.weight(.medium))
            content().padding(.leading, 14)
        }
    }

    private func outputPicker(_ label: String, _ family: TimelineTracks.Family) -> some View {
        Picker(label, selection: Binding(
            get: { TracksController.existingBus(family).map { mixes.primaryToken(mixId: $0.id) } ?? AudioMixInventory.noOutputID },
            set: { mixes.setPrimary(mixId: TracksController.familyBus(family).id, token: $0) }
        )) {
            Text("Not yet").tag(AudioMixInventory.noOutputID)
            ForEach(outputs.entries) { Text($0.name).tag($0.id) }
        }
        .frame(width: 300)
    }

    private func patch(_ wide: [AudioOutputDevice]) {
        guard let device = wide.first(where: { $0.uid == patchDevice }) else { return }
        let plan = TimelineTracks.patchPlan(start: patchStart, deviceChannels: device.channelCount)
        for (family, channel) in plan {
            let output = outputs.ensureMono(device: device, channel: channel)
            mixes.setPrimary(mixId: TracksController.familyBus(family).id, token: output.id)
        }
        patched = "Patched \(plan.count) mixes to \(device.name) \(patchStart + 1)\u{2013}\(patchStart + plan.count)."
    }
}
