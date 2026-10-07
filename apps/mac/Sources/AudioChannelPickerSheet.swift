import AudioEngine
import SwiftUI

struct AudioChannelPickerSheet: View {
    let device: AudioDeviceList.AudioInputDevice
    @Environment(\.dismiss) private var dismiss
    @State private var inventory = AudioInputInventory.shared
    @State private var nameStore = AudioChannelNameStore.shared
    @State private var selectedPairs: Set<Int> = []
    @State private var selectedMonos: Set<Int> = []

    private var pairOffsets: [Int] {
        Array(stride(from: 0, to: max(2, device.channelCount) - 1, by: 2))
    }

    private var usedPairs: Set<Int> {
        Set(inventory.entries.compactMap { entry in
            guard entry.uid == device.uid, entry.monoChannel == nil else { return nil }
            return entry.channelOffset ?? 0
        })
    }

    private var usedMonos: Set<Int> {
        Set(inventory.entries.compactMap { entry in
            entry.uid == device.uid ? entry.monoChannel : nil
        })
    }

    private var selectionCount: Int {
        selectedPairs.count + selectedMonos.count
    }

    private var monosBlockedByPairs: Set<Int> {
        Set(selectedPairs.flatMap { [$0, $0 + 1] })
    }

    private var pairsBlockedByMonos: Set<Int> {
        Set(selectedMonos.map { $0 - ($0 % 2) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Channels — \(device.name)")
                    .font(.headline)
                Text("\(device.channelCount) channels. Each checked pair or mono channel becomes its own input in the mixer. Channel names stick to the device — new inputs start with them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pairSection
                    monoSection
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 380)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selectionCount > 0 ? "Add \(selectionCount) Input\(selectionCount == 1 ? "" : "s")" : "Add") {
                    let selections: [InputChannelSelection] =
                        selectedPairs.sorted().map { .stereoPair(offset: $0) }
                        + selectedMonos.sorted().map { .mono(channel: $0) }
                    inventory.createBatch(
                        uid: device.uid, deviceName: device.name, selections: selections)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectionCount == 0)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private var pairSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: "STEREO PAIRS", items: pairOffsets,
                used: usedPairs, blocked: pairsBlockedByMonos, selected: $selectedPairs)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), alignment: .topLeading)],
                alignment: .leading, spacing: 6
            ) {
                ForEach(pairOffsets, id: \.self) { offset in
                    VStack(alignment: .leading, spacing: 1) {
                        checkbox(
                            label: "\(offset + 1)-\(offset + 2)", item: offset,
                            used: usedPairs, blocked: pairsBlockedByMonos,
                            selected: $selectedPairs)

                        if let name = pairName(offset) {
                            Text(name)
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }

    private var monoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: "MONO CHANNELS", items: Array(0 ..< device.channelCount),
                used: usedMonos, blocked: monosBlockedByPairs, selected: $selectedMonos)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                alignment: .leading, spacing: 4
            ) {
                ForEach(0 ..< device.channelCount, id: \.self) { channel in
                    HStack(spacing: 4) {
                        checkbox(
                            label: "\(channel + 1)", item: channel,
                            used: usedMonos, blocked: monosBlockedByPairs,
                            selected: $selectedMonos)
                        .frame(width: 40, alignment: .leading)
                        TextField("Name", text: Binding(
                            get: { nameStore.name(uid: device.uid, channel: channel) ?? "" },
                            set: { nameStore.setName($0, uid: device.uid, channel: channel) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func pairName(_ offset: Int) -> String? {
        let left = nameStore.name(uid: device.uid, channel: offset)
        let right = nameStore.name(uid: device.uid, channel: offset + 1)
        switch (left, right) {
        case (nil, nil): return nil
        case (let left?, nil): return left
        case (nil, let right?): return right
        case (let left?, let right?): return left == right ? left : "\(left) / \(right)"
        }
    }

    private func sectionHeader(
        title: String, items: [Int], used: Set<Int>, blocked: Set<Int>,
        selected: Binding<Set<Int>>
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Spacer()
            let addable = items.filter { !used.contains($0) && !blocked.contains($0) }
            let allSelected = !addable.isEmpty
                && addable.allSatisfy { selected.wrappedValue.contains($0) }
            Button(allSelected ? "Select None" : "Select All") {
                selected.wrappedValue = allSelected ? [] : Set(addable)
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .disabled(addable.isEmpty)
        }
    }

    private func checkbox(
        label: String, item: Int, used: Set<Int>, blocked: Set<Int>,
        selected: Binding<Set<Int>>
    ) -> some View {
        let inUse = used.contains(item)
        let isBlocked = !inUse && blocked.contains(item)
        return Toggle(label, isOn: Binding(
            get: { inUse || selected.wrappedValue.contains(item) },
            set: { on in
                guard !inUse, !isBlocked else { return }
                if on {
                    selected.wrappedValue.insert(item)
                } else {
                    selected.wrappedValue.remove(item)
                }
            }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .disabled(inUse || isBlocked)
        .help(inUse ? "Already patched into an input"
            : isBlocked ? "Overlaps another selection in this batch"
            : "")
    }
}
