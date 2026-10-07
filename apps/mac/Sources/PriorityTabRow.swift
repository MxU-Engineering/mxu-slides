import AppKit
import os
import PresenterCore
import SwiftUI

private enum ChipTextWidths {
    private static let cache = OSAllocatedUnfairLock<[String: Double]>(initialState: [:])

    static func width(_ title: String) -> Double {
        if let hit = cache.withLock({ $0[title] }) { return hit }
        let width = ceil(Double((title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11)]
        ).width))
        cache.withLock { $0[title] = width }
        return width
    }
}

struct PriorityTabDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let glyph: GlyphKind

    var tint: Color?

    var isPopped = false
}

struct PriorityTabRow<ChipMenu: View>: View {

    let card: String

    let tabs: [PriorityTabDescriptor]

    var overflowExtras: [PriorityTabDescriptor] = []
    let selectedID: String?
    let onSelect: (String) -> Void

    let onReorder: (_ movedID: String, _ beforeID: String?) -> Void
    @ViewBuilder let chipMenu: (String) -> ChipMenu

    @State private var containerWidth: CGFloat = 0
    @State private var showingOverflow = false

    private static var spacing: CGFloat { 3 }

    private func chipWidth(_ tab: PriorityTabDescriptor) -> Double {
        let popped: Double = tab.isPopped ? 5 + 8 : 0

        return 9 + 12 + 5 + ChipTextWidths.width(tab.title) + 9 + popped + 2
    }

    private static var overflowButtonWidth: Double { 26 }

    private var visibleCount: Int {

        guard containerWidth > 0 else { return min(1, tabs.count) }
        return TabRowLogic.visibleCount(
            widths: tabs.map(chipWidth), spacing: Double(Self.spacing),
            containerWidth: Double(containerWidth - 6),
            chevronWidth: Self.overflowButtonWidth)
    }

    private var rowSpacing: CGFloat {
        guard containerWidth > 0 else { return Self.spacing }
        return CGFloat(TabRowLogic.distributedSpacing(
            widths: pills.map(chipWidth),
            chevronWidth: overflowRows.isEmpty ? nil : Self.overflowButtonWidth,
            containerWidth: Double(containerWidth - 6),
            minimumSpacing: Double(Self.spacing)))
    }

    private var pills: [PriorityTabDescriptor] { Array(tabs.prefix(visibleCount)) }
    private var overflow: [PriorityTabDescriptor] { Array(tabs.dropFirst(visibleCount)) }

    private var overflowRows: [PriorityTabDescriptor] {
        overflow + overflowExtras.filter { extra in !tabs.contains(where: { $0.id == extra.id }) }
    }

    var body: some View {
        HStack(spacing: rowSpacing) {
            ForEach(pills) { tab in
                chip(tab, inPopover: false)
            }
            if !overflowRows.isEmpty {
                chevron
            }
        }
        .padding(3)

        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabRowContainerWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(TabRowContainerWidthKey.self) { containerWidth = $0 }
        .background(

            Color.primary.opacity(0.06),
            in: RoundedRectangle.standard(CornerStandard.cardHugging(inset: 5))
        )
    }

    private func chipLabel(_ tab: PriorityTabDescriptor, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Glyph(kind: tab.glyph, size: 12)
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .fixedSize()
            if tab.isPopped {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(
            tab.tint.map(AnyShapeStyle.init)
                ?? (selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        )
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func chip(_ tab: PriorityTabDescriptor, inPopover: Bool) -> some View {
        let selected = selectedID == tab.id && !tab.isPopped
        return Button {
            if inPopover { showingOverflow = false }
            onSelect(tab.id)
        } label: {
            if inPopover {
                chipLabel(tab, selected: selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                chipLabel(tab, selected: selected)
            }
        }
        .buttonStyle(.plain)

        .background(
            selected ? AnyShapeStyle(Color.cardSurface) : AnyShapeStyle(.clear),
            in: RoundedRectangle.standard(CornerStandard.cardHugging(inset: 8))
        )
        .overlay {
            if selected {
                RoundedRectangle.standard(CornerStandard.cardHugging(inset: 8))
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 1.5, y: 1)
        .draggable(payload(tab.id))
        .dropDestination(for: String.self) { items, _ in
            guard let moved = movedID(items), moved != tab.id else { return false }
            onReorder(moved, tab.id)
            return true
        }
        .contextMenu {
            if tabs.first?.id != tab.id, tabs.contains(where: { $0.id == tab.id }) {
                Button("Move to Front") { onReorder(tab.id, tabs.first?.id) }
                Divider()
            }
            chipMenu(tab.id)
        }
        .help(tab.isPopped
            ? "\(tab.title) is in its own window — click to show it" : tab.title)
    }

    private var overflowTint: Color? {
        if overflowRows.contains(where: { $0.tint == .orange }) { return .orange }
        return overflowRows.first(where: { $0.tint != nil })?.tint
    }

    private var selectedInOverflow: PriorityTabDescriptor? {
        overflowRows.first { $0.id == selectedID && !$0.isPopped }
    }

    private var chevron: some View {
        Button {
            showingOverflow.toggle()
        } label: {

            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    overflowTint.map(AnyShapeStyle.init)
                        ?? (selectedInOverflow != nil
                            ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                )
                .frame(width: CGFloat(Self.overflowButtonWidth) - 6)
                .padding(.horizontal, 3)
                .padding(.vertical, 4)
                .frame(minHeight: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        .background(
            selectedInOverflow != nil ? AnyShapeStyle(Color.cardSurface) : AnyShapeStyle(.clear),
            in: RoundedRectangle.standard(CornerStandard.cardHugging(inset: 8))
        )
        .overlay {
            if selectedInOverflow != nil {
                RoundedRectangle.standard(CornerStandard.cardHugging(inset: 8))
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(selectedInOverflow != nil ? 0.1 : 0), radius: 1.5, y: 1)

        .dropDestination(for: String.self) { items, _ in
            guard let moved = movedID(items) else { return false }
            onReorder(moved, nil)
            return true
        }
        .help("More tabs")
        .popover(isPresented: $showingOverflow, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(overflowRows) { tab in
                    chip(tab, inPopover: true)
                }
            }
            .padding(6)
            .frame(width: 190)
        }
    }

    private func payload(_ id: String) -> String { "tabrow:\(card):\(id)" }

    private func movedID(_ items: [String]) -> String? {
        guard let raw = items.first else { return nil }
        let prefix = "tabrow:\(card):"
        guard raw.hasPrefix(prefix) else { return nil }
        return String(raw.dropFirst(prefix.count))
    }
}

private struct TabRowContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
