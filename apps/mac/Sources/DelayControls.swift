import SwiftUI

struct DelayField: View {
    let unit: String
    let range: ClosedRange<Int>
    let step: Int
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text("Delay")
                .font(.caption2)
                .foregroundStyle(value > 0 ? .secondary : .tertiary)
            TextField("", value: binding, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: range.upperBound > 99 ? 44 : 28)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(value > 0 ? .primary : .secondary)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(value > 0 ? .secondary : .tertiary)
            Stepper("", value: binding, in: range, step: step)
                .labelsHidden()
                .controlSize(.mini)
        }

        .fixedSize()
    }

    private var binding: Binding<Int> {
        Binding(
            get: { value },
            set: { onChange(min(max($0, range.lowerBound), range.upperBound)) }
        )
    }
}
