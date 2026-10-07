import SwiftUI

struct ModuleHeaderBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 2) {
            leading()
            Spacer(minLength: 4)
            trailing()
        }
        .frame(height: 24)
    }
}

struct ModuleSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.4)
    }
}

extension Image {

    func moduleHeaderGlyph(_ style: some ShapeStyle = .secondary) -> some View {
        font(.system(size: 12))
            .foregroundStyle(style)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

struct ModuleSearchButton: View {
    @Binding var isSearching: Bool
    @Binding var query: String

    var body: some View {
        Button {
            isSearching.toggle()
            if !isSearching { query = "" }
        } label: {
            Image(systemName: "magnifyingglass")
                .moduleHeaderGlyph(
                    isSearching ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                )
        }
        .buttonStyle(.plain)
        .help(isSearching ? "Close search" : "Search by name — folder names match too")
    }
}

struct ModuleSearchField: View {
    @Binding var query: String
    @Binding var isSearching: Bool

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($focused)
                .onExitCommand {
                    query = ""
                    isSearching = false
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .onAppear { focused = true }
    }
}
