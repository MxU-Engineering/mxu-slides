import PresenterCore
import SwiftUI

struct SlidesAcrossControl: View {
    @Binding var count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("\(SlidesAcross.clamped(count))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 24, height: 20)
                .background(
                    Color.primary.opacity(0.08),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
            Slider(
                value: Binding(
                    get: { Double(SlidesAcross.clamped(count)) },
                    set: { raw in
                        let next = SlidesAcross.clamped(Int(raw.rounded()))
                        if next != count { count = next }
                    }
                ),
                in: Double(SlidesAcross.range.lowerBound) ... Double(SlidesAcross.range.upperBound),
                step: 1
            )
            .controlSize(.small)
        }
        .help("How many slides share a row in Present")
    }
}
