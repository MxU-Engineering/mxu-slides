import SwiftUI

struct ScrubBar: View {

    let elapsed: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    var showsTimes = false

    var trimRange: ClosedRange<Double>? = nil

    var onTrimChange: ((ClosedRange<Double>, _ final: Bool) -> Void)? = nil

    var liveSeekInterval: Duration = .milliseconds(120)

    let onSeek: (TimeInterval, _ final: Bool) -> Void

    @State private var draftFraction: Double?
    @State private var hovering = false
    @State private var lastLiveSeek = ContinuousClock.now

    @State private var lastLiveSeekFraction: Double?

    @State private var pendingSettle: Task<Void, Never>?

    @State private var isDragging = false

    @State private var trimDrag: (edge: TrimEdge, fraction: Double)?

    @State private var gestureActive = false
    private enum TrimEdge { case trimIn, trimOut }

    private static let minTrimGap = 0.02

    private static let trimGrabZone: CGFloat = 10

    var body: some View {
        if duration > 0 {
            HStack(spacing: 8) {
                if showsTimes {
                    Text(Self.timecode(previewElapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(draftFraction != nil ? .secondary : .tertiary)
                        .frame(width: 34, alignment: .trailing)
                }
                track
                if showsTimes {
                    Text(Self.timecode(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, alignment: .leading)
                }
            }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = draftFraction ?? (duration > 0 ? elapsed / duration : 0)
            let clamped = min(max(fraction, 0), 1)
            let editable = onTrimChange != nil

            let baseTrim: ClosedRange<Double>? = trimRange ?? (editable ? 0 ... 1 : nil)
            let displayTrim = baseTrim.map { applyingDraft(to: $0) }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 3)
                Capsule()
                    .fill(isPlaying ? Color.green : Color.secondary)
                    .frame(width: clamped * width, height: 3)
                if let trim = displayTrim {

                    let lower = min(max(trim.lowerBound, 0), 1)
                    let upper = min(max(trim.upperBound, lower), 1)
                    if lower > 0.001 {
                        Rectangle()
                            .fill(.black.opacity(0.45))
                            .frame(width: lower * width, height: 5)
                    }
                    if upper < 0.999 {
                        Rectangle()
                            .fill(.black.opacity(0.45))
                            .frame(width: (1 - upper) * width, height: 5)
                            .offset(x: upper * width)
                    }
                    if editable || lower > 0.001 || upper < 0.999 {
                        ForEach([lower, upper], id: \.self) { edge in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.orange)
                                .frame(width: editable ? 3 : 1.5, height: editable ? 11 : 9)
                                .offset(x: edge * width - (editable ? 1.5 : 0.75))
                        }
                    }
                }
                if hovering || isDragging || draftFraction != nil {
                    Circle()
                        .fill(isPlaying ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                        .offset(x: clamped * width - 4.5)
                }
            }
            .frame(maxHeight: .infinity)

            .contentShape(Rectangle().inset(by: -10))
            .gesture(

                DragGesture(minimumDistance: 0)
                    .onChanged { value in

                        if !gestureActive {
                            gestureActive = true
                            trimDrag = nil
                            isDragging = false
                            if editable, let trim = baseTrim {
                                let startX = value.startLocation.x
                                let inDistance = abs(startX - trim.lowerBound * width)
                                let outDistance = abs(startX - trim.upperBound * width)
                                if min(inDistance, outDistance) <= Self.trimGrabZone {
                                    trimDrag = (
                                        inDistance <= outDistance ? .trimIn : .trimOut,
                                        min(max(value.location.x / width, 0), 1)
                                    )
                                }
                            }
                            if trimDrag == nil { isDragging = true }
                        }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        if let drag = trimDrag, let trim = baseTrim {

                            let bounded = switch drag.edge {
                            case .trimIn: min(fraction, trim.upperBound - Self.minTrimGap)
                            case .trimOut: max(fraction, trim.lowerBound + Self.minTrimGap)
                            }
                            trimDrag = (drag.edge, min(max(bounded, 0), 1))
                            let now = ContinuousClock.now
                            if now - lastLiveSeek >= liveSeekInterval {
                                lastLiveSeek = now
                                onSeek(bounded * duration, false)
                            }
                            return
                        }
                        isDragging = true
                        draftFraction = fraction
                        let now = ContinuousClock.now
                        if now - lastLiveSeek >= liveSeekInterval {
                            lastLiveSeek = now
                            lastLiveSeekFraction = fraction
                            onSeek(fraction * duration, false)

                            scheduleSettle(seekTo: nil)
                        } else {

                            scheduleSettle(seekTo: fraction)
                        }
                    }
                    .onEnded { value in
                        gestureActive = false
                        if let drag = trimDrag, let trim = baseTrim {

                            let range = applyingDraft(to: trim)
                            onSeek(drag.fraction * duration, true)
                            onTrimChange?(range, true)
                            trimDrag = nil
                            return
                        }
                        pendingSettle?.cancel()
                        pendingSettle = nil
                        let fraction = min(max(value.location.x / width, 0), 1)

                        let pixel = 1.5 / width
                        if lastLiveSeekFraction.map({ abs(fraction - $0) > pixel }) ?? true {
                            onSeek(fraction * duration, true)
                        }
                        isDragging = false
                        draftFraction = nil
                        lastLiveSeekFraction = nil
                    }
            )
        }
        .frame(height: 16)
        .onHover { hovering = $0 }
        .help("Drag to seek — playback keeps its play/pause state")
    }

    private func applyingDraft(to trim: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let drag = trimDrag else { return trim }
        switch drag.edge {
        case .trimIn:
            return min(drag.fraction, trim.upperBound - Self.minTrimGap) ... trim.upperBound
        case .trimOut:
            return trim.lowerBound ... max(drag.fraction, trim.lowerBound + Self.minTrimGap)
        }
    }

    private func scheduleSettle(seekTo fraction: Double?) {
        pendingSettle?.cancel()
        pendingSettle = Task { @MainActor in
            try? await Task.sleep(for: liveSeekInterval)
            guard !Task.isCancelled else { return }
            if let fraction {
                lastLiveSeek = ContinuousClock.now
                lastLiveSeekFraction = fraction
                onSeek(fraction * duration, false)
            }

            draftFraction = nil
        }
    }

    private var previewElapsed: TimeInterval {
        if let draftFraction { return draftFraction * duration }
        return elapsed
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
