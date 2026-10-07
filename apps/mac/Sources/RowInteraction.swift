import AppKit
import SwiftUI

enum RowInteraction {

    static func settled(_ changedAt: Date) -> Bool {
        Date().timeIntervalSince(changedAt) > NSEvent.doubleClickInterval
    }
}

struct RowNameField: View {
    let id: String
    let name: String

    @Binding var renamingID: String?
    @Binding var draft: String
    let commit: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        if renamingID == id {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)

                .onAppear { DispatchQueue.main.async { focused = true } }
                .onSubmit { commitNow() }
                .onChange(of: focused) { _, nowFocused in
                    if !nowFocused { commitNow() }
                }
                .onExitCommand { renamingID = nil }
        } else {
            Text(name)
                .lineLimit(1)
        }
    }

    private func commitNow() {
        guard renamingID == id else { return }
        commit(draft)
        renamingID = nil
    }
}

struct RowMouseHandler: NSViewRepresentable {

    var renameDeadZone: CGFloat = 0
    let isSelected: () -> Bool
    let selectionSettled: () -> Bool
    let select: () -> Void
    let beginRename: () -> Void

    func makeNSView(context: Context) -> HandlerView {
        let view = HandlerView()
        update(view)
        return view
    }

    func updateNSView(_ view: HandlerView, context: Context) {
        update(view)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: HandlerView, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private func update(_ view: HandlerView) {
        view.renameDeadZone = renameDeadZone
        view.isSelected = isSelected
        view.selectionSettled = selectionSettled
        view.select = select
        view.beginRename = beginRename
    }

    final class HandlerView: NSView {
        var renameDeadZone: CGFloat = 0
        var isSelected: () -> Bool = { false }
        var selectionSettled: () -> Bool = { false }
        var select: () -> Void = {}
        var beginRename: () -> Void = {}

        private var pendingRename: DispatchWorkItem?

        override func mouseDown(with event: NSEvent) {
            pendingRename?.cancel()
            let local = convert(event.locationInWindow, from: nil)
            let candidate = isSelected() && selectionSettled()
                && local.x > renameDeadZone
            if !isSelected() { select() }
            if candidate {
                let downLocation = NSEvent.mouseLocation
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isSelected() else { return }
                    guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                    let now = NSEvent.mouseLocation
                    guard abs(now.x - downLocation.x) < 4,
                          abs(now.y - downLocation.y) < 4 else { return }
                    self.beginRename()
                }
                pendingRename = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + NSEvent.doubleClickInterval, execute: work
                )
            }
            super.mouseDown(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            superview?.menu(for: event)
        }
    }
}

struct RowInsertionLine: View {

    static let rowGapOffset: CGFloat = -3

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: 6, height: 6)
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
    }
}
