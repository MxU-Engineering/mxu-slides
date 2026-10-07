import RenderEngine
import SwiftUI

struct MediaTransportStrip: View {
    let controls: ServiceControls?

    var floating = false

    @AppStorage("transport.skipToEndOffset") private var skipToEndOffset = 30

    @State private var nameHovering = false

    var body: some View {

        if let controls {
            if let target = controls.media.target {
                strip(controls.media, target: target)
                    .padding(.horizontal, floating ? 12 : 0)
                    .padding(.vertical, floating ? 6 : 0)
                    .background { floatingChrome }
            } else if !floating {

                HStack(spacing: 8) {
                    pickerChip(controls.media, target: nil)
                    idleStrip
                }
                .opacity(0.65)
            }
        }
    }

    @ViewBuilder
    private var floatingChrome: some View {
        if floating {
            RoundedRectangle.standard(CornerStandard.panel)
                .fill(Color.cardSurface)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .overlay(
                    RoundedRectangle.standard(CornerStandard.panel)
                        .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
                )
        }
    }

    private var idleStrip: some View {
        HStack(spacing: 8) {

            transportChip(systemName: "play.fill", caption: nil)
                .foregroundStyle(.secondary)
            VStack(spacing: 1) {
                Text("No video playing")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 3)
                    .frame(height: 16)
                Text("0:00 / 0:00")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 240)
            transportChip(
                systemName: "arrow.right.to.line",
                caption: Self.offsetCaption(skipToEndOffset)
            )
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())

            .contextMenu { skipPresetPicker }
            .help("Jump amount — right-click to change")
        }
        .frame(height: 48)
        .help("Video transport — fired videos pause and scrub here")
    }

    private func transportChip(systemName: String, caption: String?) -> some View {
        VStack(spacing: 1) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
            if let caption {
                Text(caption)
                    .font(.system(size: 8).monospacedDigit())
            }
        }
        .frame(width: 32, height: 32)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    @ViewBuilder
    private func strip(_ media: MediaTransportController, target: MediaTransportController.Row) -> some View {
        let now = Date()
        let finished = MediaTransportController.isFinished(target.state, at: now)
        HStack(spacing: 8) {
            pickerChip(media, target: target)
            if media.showsTransport {

                Button {
                    if finished {
                        media.resetToStart(target.id)
                    } else {
                        media.togglePlayPause(target.id)
                    }
                } label: {
                    transportChip(
                        systemName: finished
                            ? "arrow.counterclockwise"
                            : (target.state.isPlaying ? "pause.fill" : "play.fill"),
                        caption: nil
                    )
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    finished
                        ? "Reset to the start (stays paused)"
                        : (target.state.isPlaying ? "Pause" : "Play")
                )

                TimelineView(
                    .animation(minimumInterval: 1.0 / 30.0, paused: !target.state.isPlaying)
                ) { context in
                    VStack(spacing: 1) {
                        nameCaption(target)
                        ScrubBar(
                            elapsed: target.state.position(at: context.date),
                            duration: target.state.duration,
                            isPlaying: target.state.isPlaying
                        ) { seconds, final in
                            media.seek(target.id, to: seconds, final: final)
                        }
                        HStack(spacing: 2) {
                            GoToTimeReadout(media: media, row: target)
                            Text("/ \(ScrubBar.timecode(target.state.duration))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 240)
                skipToEndButton(media, target: target)
            } else {

                TimelineView(.animation(minimumInterval: 1, paused: !target.state.isPlaying)) { context in
                    VStack(spacing: 1) {
                        Text(ScrubBar.timecode(target.state.remaining(at: context.date)) + " left")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        nameCaption(target)
                    }
                }
                .help("Remaining in this pass — select the video in the picker to control it")
            }
        }
        .frame(height: 48)
    }

    private func skipToEndButton(
        _ media: MediaTransportController, target: MediaTransportController.Row
    ) -> some View {
        Button {
            media.seek(
                target.id,
                to: max(0, target.state.duration - Double(skipToEndOffset)),
                final: true
            )
        } label: {
            transportChip(
                systemName: "arrow.right.to.line",
                caption: Self.offsetCaption(skipToEndOffset)
            )
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { skipPresetPicker }
        .fixedSize()
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .help("Jump to \(skipToEndOffset)s before the end — long-press to change the amount")
    }

    private func nameCaption(_ target: MediaTransportController.Row) -> some View {
        HStack(spacing: 4) {
            Text(
                nameHovering || target.name.count <= 20
                    ? target.name
                    : String(target.name.prefix(20)) + "…"
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .onHover { nameHovering = $0 }
            if target.candidate.isLooping {
                Image(systemName: "repeat")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.quaternary)
                    .help("Looping")
            }
        }
    }

    static func offsetCaption(_ seconds: Int) -> String {
        seconds == 0 ? "End" : (seconds < 60 ? "-\(seconds)" : "-\(seconds / 60)m")
    }

    @ViewBuilder
    private var skipPresetPicker: some View {
        skipOption(0, "End")
        ForEach([5, 10, 15, 20, 25, 30, 60, 90], id: \.self) { seconds in
            skipOption(seconds, "-\(seconds)s before end")
        }
        ForEach([2, 3, 4, 5], id: \.self) { minutes in
            skipOption(minutes * 60, "-\(minutes)m before end")
        }
    }

    private func skipOption(_ seconds: Int, _ title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { skipToEndOffset == seconds },
            set: { _ in skipToEndOffset = seconds }
        ))
    }

    private func pickerChip(
        _ media: MediaTransportController, target: MediaTransportController.Row?
    ) -> some View {

        TimelineView(.animation(minimumInterval: 1, paused: !media.rows.contains { $0.state.isPlaying })) { context in
            pickerMenu(media, target: target, now: context.date)
        }
    }

    private func pickerMenu(
        _ media: MediaTransportController, target: MediaTransportController.Row?, now: Date
    ) -> some View {
        let byLayer = Dictionary(grouping: media.rows, by: \.candidate.layer)

        let fixed: Set<LayerKind> = [.alerts, .overlays, .slide, .videos, .loopingVideos]
        let layers = LayerKind.allCases.reversed().filter { layer in
            fixed.contains(layer) || byLayer[layer] != nil
        }
        return Menu {
            ForEach(layers, id: \.self) { layer in
                Section(layer.displayName) {
                    Toggle("View \(layer.displayName)", isOn: Binding(
                        get: { media.viewedLayer == layer },
                        set: { _ in media.select(layer: layer) }
                    ))
                    ForEach(byLayer[layer] ?? []) { row in
                        Toggle(isOn: Binding(
                            get: { media.pinnedID == row.id },
                            set: { _ in media.pin(row.id) }
                        )) {
                            Text("\(row.name)  ·  \(ScrubBar.timecode(row.state.remaining(at: now))) left")
                        }
                    }
                }
            }
        } label: {

            HStack(spacing: 4) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 10))
                Text((target?.candidate.layer ?? media.viewedLayer).displayName)
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }

        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playing videos by layer, top of the stack first — pick which one the strip controls")
    }
}

private struct GoToTimeReadout: View {
    let media: MediaTransportController
    let row: MediaTransportController.Row

    @State private var editing = false
    @State private var minutes = 0
    @State private var seconds = 0

    var body: some View {
        if editing {
            HStack(spacing: 3) {
                TimerTimeField(label: "MM", value: $minutes, max: 999, onCommit: commit)
                Text(":").font(.caption).foregroundStyle(.tertiary)
                TimerTimeField(label: "SS", value: $seconds, max: 59, onCommit: commit)
                Button(action: commit) {
                    Text("Go")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .overlay(
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
                )
                .help("Seek to this time (or press Return)")
            }
        } else {
            Text(ScrubBar.timecode(row.state.position(at: Date())))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    let position = Int(row.state.position(at: Date()))
                    minutes = position / 60
                    seconds = position % 60
                    editing = true
                }
                .help("Click to type an exact time")
        }
    }

    private func commit() {
        media.seek(row.id, to: TimeInterval(minutes * 60 + seconds), final: true)
        editing = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}
