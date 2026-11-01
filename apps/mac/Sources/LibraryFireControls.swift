import PresenterCore
import SwiftUI

@MainActor
struct LibraryFireActions {
    let model: AppModel
    let controls: ServiceControls?
    let entry: LibraryIndex.Entry

    let edit: () -> Void

    var isLive: Bool {
        guard let controls else { return false }
        return switch entry.kind {
        case .media: controls.isMediaLive(entry.id)
        case .audio: controls.state.liveAudio.contains { $0.audioItemId == entry.id }
        case .overlay: controls.state.liveOverlays.contains { $0.id == entry.id }
        default: false
        }
    }

    func toggle() {
        guard let controls else { return }
        let live = isLive
        switch entry.kind {
        case .media:
            if live {
                controls.stopMedia(id: entry.id)
            } else if let item = model.media(entry.id), !model.isMediaFileMissing(item) {
                controls.fire(mediaItem: item)
            }
        case .audio:
            if live {
                controls.stopAudio(audioItemID: entry.id)
            } else if let item = model.audio(entry.id) {
                controls.fire(audioItem: item)
            }
        case .overlay:
            if live {
                controls.dismissOverlay(id: entry.id)
            } else if let overlay = model.overlay(entry.id) {
                controls.fire(overlay: overlay)
            }
        default:
            break
        }
    }
}

struct LibraryRowFireControls: View {
    let actions: LibraryFireActions
    let hovering: Bool
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let live = actions.isLive
        let fires = LibraryPresentLogic.fires(actions.entry.kind)
        if hovering || live {
            HStack(spacing: 4) {
                if hovering, !runOnly {
                    LibraryFireChip(systemImage: "pencil", help: "Open in the editor", action: actions.edit)
                }

                if fires {
                    LibraryFireChip(
                        title: LibraryPresentLogic.fireLabel(actions.entry.kind, live: live),
                        live: live, action: actions.toggle)
                }
            }
        }
    }
}

struct LibraryCardFireControls: View {
    let actions: LibraryFireActions
    let hovering: Bool
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let live = actions.isLive
        if !LibraryPresentLogic.fires(actions.entry.kind) {
            if hovering, !runOnly {
                LibraryFireChip(systemImage: "pencil", help: "Open in the editor", action: actions.edit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }
        } else if live {
            LibraryFireChip(
                title: LibraryPresentLogic.fireLabel(actions.entry.kind, live: true),
                live: true, action: actions.toggle)
        } else if hovering {
            HStack(spacing: 8) {
                LibraryCardSymbol(systemImage: "play.fill",
                                  help: LibraryPresentLogic.fireLabel(actions.entry.kind, live: false),
                                  action: actions.toggle)
                if !runOnly {
                    LibraryCardSymbol(systemImage: "pencil", help: "Open in the editor", action: actions.edit)
                }
            }
        }
    }
}

struct LibraryFireChip: View {
    var title: String? = nil
    var systemImage: String? = nil
    var live = false
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).font(.caption2.weight(.medium))
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(live ? Color.green : .secondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(.thickMaterial, in: RoundedRectangle.standard(CornerStandard.element))
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(live ? Color.green.opacity(0.4) : Color.separator.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title ?? help ?? "")
        .help(help ?? title ?? "")
    }
}

struct LibraryCardSymbol: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.6), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }
}

struct LibraryCardFireOverlay: ViewModifier {
    let actions: LibraryFireActions?
    @State private var hovering = false

    func body(content: Content) -> some View {
        if let actions {
            content
                .overlay {
                    LibraryCardFireControls(actions: actions, hovering: hovering)
                        .padding(.bottom, 18)
                }
                .overlay {
                    if actions.isLive {
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(Color.green, lineWidth: 2)
                            .padding(.bottom, 18)
                    }
                }
                .onHover { hovering = $0 }
        } else {
            content
        }
    }
}

struct LibraryRowFireTrailing: ViewModifier {
    let actions: LibraryFireActions?
    @State private var hovering = false

    func body(content: Content) -> some View {
        if let actions {
            let showing = hovering || actions.isLive
            content
                .environment(\.libraryRowFiring, showing)
                .overlay(alignment: .trailing) {
                    if showing {
                        LibraryRowFireControls(actions: actions, hovering: hovering)
                    }
                }
                .onHover { hovering = $0 }
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    @Entry var libraryRowFiring = false
}

struct HiddenWhileRowFires<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.libraryRowFiring) private var firing

    var body: some View {
        content.opacity(firing ? 0 : 1)
    }
}
