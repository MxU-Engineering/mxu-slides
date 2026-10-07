import SwiftUI

struct InspectorForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.cardGap) {
                content
            }

            .padding(.leading, 16)
            .padding(.trailing, 10)

            .padding(.top, 16 - (InspectorMetrics.titledGap - InspectorMetrics.cardGap))
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(InspectorToggleStyle())
        .labeledContentStyle(InspectorLabeledContentStyle())

        .textFieldStyle(.plain)
    }
}

enum InspectorMetrics {
    static let cardGap: CGFloat = 10
    static let titledGap: CGFloat = 30
    static let titleToCard: CGFloat = 10
}

struct InspectorSection<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {

        VStack(alignment: .leading, spacing: InspectorMetrics.titleToCard) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, 10)
            }
            rows
                .background(
                    Color.primary.opacity(0.035),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
        }
        .padding(.top, title == nil ? 0 : InspectorMetrics.titledGap - InspectorMetrics.cardGap)
    }

    @ViewBuilder private var rows: some View {
        if #available(macOS 15, *) {
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.horizontal, 10)
                        }
                        row.modifier(InspectorRow())
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                content.modifier(InspectorRow())
            }
        }
    }
}

private struct InspectorRow: ViewModifier {
    func body(content: Content) -> some View {

        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(minHeight: 36)
    }
}

struct InspectorLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {

        HStack(alignment: .center, spacing: 8) {
            configuration.label
                .fixedSize(horizontal: true, vertical: false)
            configuration.content
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct InspectorToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Spacer(minLength: 8)
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

struct InspectorPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    let content: Content

    init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        LabeledContent(title) {

            Picker(title, selection: $selection) { content }
                .labelsHidden()
                .buttonStyle(.borderless)
        }
    }
}

struct InspectorTextField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
        }
    }
}
