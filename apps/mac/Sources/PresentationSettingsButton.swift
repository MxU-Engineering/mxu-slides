import PresenterCore
import SlideScene
import SwiftUI

struct PresentationSettingsButton: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let presentation: Presentation

    var isPresented: Binding<Bool>? = nil

    @Environment(\.runOnly) private var runOnly
    @State private var localShown = false
    private var popoverShown: Binding<Bool> { isPresented ?? $localShown }
    @State private var sheet: PresentationSettingsSheet?

    @State private var pendingSheet: PresentationSettingsSheet?

    var body: some View {
        let changed = presentation.autoAdvance != nil || presentation.transition != nil
        Button {
            popoverShown.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                if let slideShow = presentation.autoAdvance {
                    Text("Slide Show: " + Self.slideShowText(slideShow))
                        .font(.caption)
                        .fixedSize()
                }
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(changed ? Color.accentColor : Color.secondary)
            .padding(.horizontal, presentation.autoAdvance == nil ? 0 : 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(
                changed ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Presentation settings")
        .popover(isPresented: popoverShown, arrowEdge: .bottom) {
            popover
                .onDisappear {
                    sheet = pendingSheet
                    pendingSheet = nil
                }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .theme: themeSheet
            case .slideShow: slideShowSheet
            }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Presentation Settings")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Theme").foregroundStyle(.secondary)
                    Button(model.entry(presentation.themeId)?.name ?? "None") { open(.theme) }
                }
                GridRow {
                    Text("Slide Show").foregroundStyle(.secondary)
                    Button(presentation.autoAdvance.map(Self.slideShowText) ?? "Off") { open(.slideShow) }
                }
                GridRow {
                    Text("Transition").foregroundStyle(.secondary)
                    TransitionMenu(current: presentation.transition, prefix: "") { transform in
                        model.updatePresentationField(
                            presentation.id, \.transition, key: "transition",
                            to: transform(model.presentation(presentation.id)?.transition),
                            undoLabel: "Presentation Transition")
                        controls?.presentationEdited(presentation.id)
                    }
                    .fixedSize()
                }
            }
            .disabled(runOnly)
            Text("Slides and media with their own transition keep it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 280, alignment: .leading)
    }

    private func open(_ next: PresentationSettingsSheet) {
        pendingSheet = next
        popoverShown.wrappedValue = false
    }

    private var themeSheet: some View {
        ApplyThemeSheet(
            appModel: model, render: render, deckThemeId: presentation.themeId,
            scope: "Applies to every slide in \u{201C}\(presentation.name)\u{201D}"
                + (model.presentationHasSlideThemes(presentation.id)
                    ? ", slides with a theme of their own too." : ".")
        ) { themeId, design in
            model.applyTheme(to: presentation.id, themeID: themeId, design: design)
        }
    }

    private var slideShowSheet: some View {
        AutoAdvanceSheet(
            slideName: presentation.name,
            advance: Binding(
                get: { model.presentation(presentation.id)?.autoAdvance },
                set: { advance in
                    model.updatePresentationField(
                        presentation.id, \.autoAdvance, key: "autoAdvance", to: advance,
                        undoLabel: "Slide Show")
                    controls?.presentationEdited(presentation.id)
                }
            ),
            presentationScope: true
        )
    }

    static func slideShowText(_ slideShow: AutoAdvance) -> String {
        let seconds = slideShow.delaySeconds
        let interval = seconds == seconds.rounded()
            ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
        return "\(interval)\((slideShow.loopToStart ?? false) ? " · Loop" : "")"
    }
}

private enum PresentationSettingsSheet: String, Identifiable {
    case theme, slideShow
    var id: String { rawValue }
}
