import AVFoundation
import AudioEngine
import MediaEngine
import NDIKit
import OutputEngine
import PresenterCore
import SwiftUI

private func sizeName(_ width: Int, _ height: Int) -> String {
    switch (width, height) {
    case (1280, 720): "720p"
    case (1920, 1080): "1080p"
    case (2560, 1440): "1440p"
    case (3840, 2160): "4K"
    case (720, 1280): "Vertical 720"
    case (1080, 1920): "Vertical 1080"
    case (2160, 3840): "Vertical 4K"
    case let (width, height): "\(width)\u{D7}\(height)"
    }
}

private func bitrateText(_ kbps: Int) -> String {
    kbps % 1000 == 0 ? "\(kbps / 1000) Mbps" : String(format: "%.1f Mbps", Double(kbps) / 1000)
}

struct StreamQualityPopover: View {
    let model: AppModel
    let presetID: String

    @State private var tab: Int

    @State private var selectedRungID: String?
    @State private var hdrLifted: Bool

    @State private var driftedKbps: Int?

    init(model: AppModel, presetID: String) {
        self.model = model
        self.presetID = presetID

        let preset = try? model.streamPreset(presetID)
        let rung = StreamQualityRung.rung(matching: preset)
        _tab = State(initialValue: rung == nil ? 1 : 0)
        _selectedRungID = State(initialValue: rung?.id)
        let hdr = preset.map { StreamQualityRung.presetWantsHDR($0, in: model) } ?? false
        _hdrLifted = State(initialValue: hdr)
        if let rung {
            let stored = preset?.videoBitrateKbps ?? 4500
            let recommended = hdr ? rung.hdrKbps : rung.sdrKbps
            _driftedKbps = State(initialValue: stored == recommended ? nil : stored)
        } else {
            _driftedKbps = State(initialValue: nil)
        }
    }

    private var preset: StreamRecordPreset? { try? model.streamPreset(presetID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChipPicker(
                options: [(0, "Quality"), (1, "Advanced")],
                selection: $tab
            )
            if tab == 0 { rungList } else { advanced }
        }
        .padding(12)
        .frame(width: 330)
        .presentationBackground(Color.basePlane)
    }

    private var rungList: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(StreamQualityRung.rungs) { rungRow($0) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Every pick streams at the highest recommended bitrate for the best picture.")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
                bitrateHelpBadge
            }
        }
    }

    private var bitrateHelpBadge: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 9))
            .foregroundStyle(.quaternary)
            .help("Higher bitrate = better picture. Lower it (under Advanced) only when the venue's upload can't keep up — a 4 Mbps stream survives poor internet, but looks far softer than 14 Mbps.")
    }

    private func rungRow(_ rung: StreamQualityRung) -> some View {
        let current = selectedRungID == rung.id
        let recommended = hdrLifted ? rung.hdrKbps : rung.sdrKbps
        return Button {
            selectedRungID = rung.id
            driftedKbps = nil
            model.updateStreamPreset(presetID) {
                $0.width = rung.width
                $0.height = rung.height
                $0.frameRate = rung.fps
                $0.videoBitrateKbps = recommended
            }
        } label: {
            HStack(spacing: 6) {

                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(current
                        ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                Text(rung.label)
                    .font(.system(size: 11))
                Spacer(minLength: 8)
                if current {

                    Text(driftedKbps.map { "\(bitrateText($0)) \u{2192} \(bitrateText(recommended))" }
                        ?? bitrateText(recommended))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            current ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 6) {
            customRow("RESOLUTION") {
                QuietMenuChip(title: sizeName(preset?.width ?? 1920, preset?.height ?? 1080)) {
                    sizeButton(1280, 720)
                    sizeButton(1920, 1080)
                    sizeButton(2560, 1440)
                    sizeButton(3840, 2160)
                    Divider()
                    sizeButton(720, 1280)
                    sizeButton(1080, 1920)
                    sizeButton(2160, 3840)
                }
            }
            customRow("FRAME RATE") {
                QuietMenuChip(title: "\(preset?.frameRate ?? 30) fps") {
                    ForEach([24, 30, 60], id: \.self) { fps in
                        Button("\(fps) fps") {
                            model.updateStreamPreset(presetID) { $0.frameRate = fps }
                        }
                    }
                }
            }
            customRow("BITRATE") {
                QuietMenuChip(title: bitrateText(preset?.videoBitrateKbps ?? 4500)) {
                    ForEach(
                        [2500, 3000, 4000, 4500, 6000, 8000, 10000, 12000,
                         15000, 20000, 24000, 30000, 35000, 40000, 44000, 50000],
                        id: \.self
                    ) { kbps in
                        Button(bitrateText(kbps)) {
                            model.updateStreamPreset(presetID) { $0.videoBitrateKbps = kbps }
                        }
                    }
                }
                if let recommended = StreamQualityRung.recommendedKbps(for: preset, in: model),
                   (preset?.videoBitrateKbps ?? 4500) != recommended {
                    Button("Reset to recommended (\(bitrateText(recommended)))") {
                        model.updateStreamPreset(presetID) { $0.videoBitrateKbps = recommended }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
                bitrateHelpBadge
            }
            Text("Highest bitrate = best picture. Lower it only when the venue's upload can't keep up.")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Vertical sizes are for portrait destinations \u{2014} phone-first platforms and portrait signage.")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sizeButton(_ width: Int, _ height: Int) -> some View {
        Button(sizeName(width, height)) {
            model.updateStreamPreset(presetID) {
                $0.width = width
                $0.height = height
            }
        }
    }

    private func customRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
                .frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

struct StreamQualityRung: Identifiable, Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let sdrKbps: Int
    let hdrKbps: Int

    var id: String { "\(width)x\(height)@\(fps)" }
    var label: String { "\(sizeName(width, height)) \u{B7} \(fps) fps" }

    static let rungs: [StreamQualityRung] = [
        .init(width: 1280, height: 720, fps: 30, sdrKbps: 6000, hdrKbps: 7500),
        .init(width: 1280, height: 720, fps: 60, sdrKbps: 8000, hdrKbps: 10000),
        .init(width: 1920, height: 1080, fps: 30, sdrKbps: 10000, hdrKbps: 12500),
        .init(width: 1920, height: 1080, fps: 60, sdrKbps: 12000, hdrKbps: 15000),
        .init(width: 3840, height: 2160, fps: 30, sdrKbps: 35000, hdrKbps: 44000),
        .init(width: 3840, height: 2160, fps: 60, sdrKbps: 40000, hdrKbps: 50000),
    ]

    static func rung(matching preset: StreamRecordPreset?) -> StreamQualityRung? {
        guard let preset else { return nil }
        return rungs.first {
            $0.width == (preset.width ?? 1920)
                && $0.height == (preset.height ?? 1080)
                && $0.fps == (preset.frameRate ?? 30)
        }
    }

    @MainActor
    static func presetWantsHDR(_ preset: StreamRecordPreset, in model: AppModel) -> Bool {
        preset.destinations.contains { $0.hdr == true }
            || (preset.destinationIds ?? []).contains { model.streamDestination($0)?.hdr == true }
    }

    @MainActor
    static func recommendedKbps(for preset: StreamRecordPreset?, in model: AppModel) -> Int? {
        guard let preset, let rung = rung(matching: preset) else { return nil }
        return presetWantsHDR(preset, in: model) ? rung.hdrKbps : rung.sdrKbps
    }

    static func recommendedKbps(width: Int, height: Int, fps: Int, hdr: Bool) -> Int? {
        let shortSide = min(width, height)
        let rateClass = fps >= 48 ? 60 : 30
        let candidates = rungs.filter { $0.fps == rateClass }
        guard let rung = candidates.min(by: {
            abs($0.height - shortSide) < abs($1.height - shortSide)
        }) else { return nil }
        return hdr ? rung.hdrKbps : rung.sdrKbps
    }
}

struct NDINetworkScopeControl: View {
    @State private var adapters: [NDIAdapter] = []
    @State private var selection = NDINetworkScope.selectedBSDName

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            QuietMenuChip(title: chipTitle) {
                Button("All Networks") { choose("") }
                Section("Pin to") {
                    ForEach(adapters) { adapter in
                        Button("\(adapter.displayName) — \(adapter.ipv4)") {
                            choose(adapter.bsdName)
                        }
                    }
                    if adapters.isEmpty {
                        Text("No networks connected")
                    }
                }
            }
            .foregroundStyle(.secondary)
            if !selection.isEmpty,
               !adapters.contains(where: { $0.bsdName == selection }) {
                Text("Not connected — NDI is on all networks until it returns")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.8))
            }
        }
        .task {

            while !Task.isCancelled {
                adapters = await Task.detached(priority: .utility) {
                    NDIAdapterList.current()
                }.value
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var chipTitle: String {
        guard !selection.isEmpty else { return "All Networks" }
        guard let adapter = adapters.first(where: { $0.bsdName == selection })
        else { return selection }
        return "\(adapter.displayName) — \(adapter.ipv4)"
    }

    private func choose(_ bsdName: String) {
        selection = bsdName
        NDINetworkScope.selectedBSDName = bsdName
        Task { await NDINetworkScope.applyLive() }
    }
}
