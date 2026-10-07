import SwiftUI

struct AutoAdvanceChip: View {
    let controls: ServiceControls

    var body: some View {
        if controls.autoAdvancePending != nil {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = controls.autoAdvanceRemaining(at: context.date)
                Button {
                    controls.setAutoAdvancePaused(!controls.autoAdvancePaused)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: controls.autoAdvancePaused
                            ? "pause.circle.fill" : "arrow.right.circle")
                            .font(.system(size: 10, weight: .medium))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(controls.autoAdvancePaused ? "Advance held" : "Auto advance")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            Text(remaining.map(Self.timecode) ?? "–:––")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(
                        Color.primary.opacity(controls.autoAdvancePaused ? 0.1 : 0.05),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
                }
                .buttonStyle(.plain)
                .help(controls.autoAdvancePaused
                    ? "Auto advance is held — the video keeps playing, the room stays. Click to re-arm (an end that already passed stays skipped)."
                    : "Time until this slide advances on its own — click to hold (the video keeps playing)")
            }
        }
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded(.up)), 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
