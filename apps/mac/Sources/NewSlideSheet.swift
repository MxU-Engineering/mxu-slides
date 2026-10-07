import PresenterCore
import SwiftUI

struct NewSlideTarget: Identifiable {
    let id = UUID()
    let after: Slide?
}

struct NewSlideSheet: View {
    let appModel: AppModel
    let render: RenderContext?

    let deckThemeId: String
    let onCreate: (NewSlideChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var exploring = false

    @State private var looks: [ThemeLook]?

    var body: some View {
        VStack(spacing: 0) {
            if exploring {
                ThemeExplorerView(
                    appModel: appModel, render: render, deckThemeId: deckThemeId, looks: looks,
                    emptyHint: "Make a theme in the Library, or start from a Blank Slide."
                ) { themeId, design in
                    create(.design(themeId: themeId, design: design))
                }
            } else {
                doors
            }
            Divider()
            HStack {
                if exploring {
                    Button("Back") { exploring = false }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: exploring ? 820 : 520, height: exploring ? 600 : nil)
        .task { looks = await ThemeLook.load(appModel, firstThemeId: deckThemeId) }
    }

    private var doors: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Slide").font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                door(
                    title: "Blank Slide", detail: "Nothing on it, no theme.",
                    systemImage: "rectangle"
                ) {
                    create(.blank)
                }
                door(
                    title: "From Theme", detail: "Pick a design from any theme.",
                    systemImage: "paintpalette"
                ) {
                    exploring = true
                }
            }
        }
        .padding(20)
    }

    private func door(title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .light))
                    .frame(height: 40)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle.standard(CornerStandard.element))
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color.separator.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func create(_ choice: NewSlideChoice) {
        onCreate(choice)
        dismiss()
    }
}

@MainActor
@Observable
final class NewSlideRouter {
    static let shared = NewSlideRouter()
    private(set) var requests = 0
    @ObservationIgnored var route = NewSlideRoute()

    func request() {
        requests += 1
    }
}

extension View {

    func newSlideEdgeButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        modifier(NewSlideEdgeButton(enabled: enabled, action: action))
    }
}

private struct NewSlideEdgeButton: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    @State private var tileHovered = false
    @State private var buttonHovered = false

    private static let diameter: CGFloat = 22

    func body(content: Content) -> some View {
        if enabled {
            content
                .onHover { tileHovered = $0 }
                .overlay(alignment: .trailing) {
                    if tileHovered || buttonHovered {
                        Button(action: action) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: Self.diameter, height: Self.diameter)
                                .background(Circle().fill(Color.accentColor))
                                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                                .scaleEffect(buttonHovered ? 1.12 : 1)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("New Slide…")
                        .onHover { buttonHovered = $0 }

                        .offset(
                            x: Self.diameter / 2,
                            y: -(SlideGridMetrics.labelHeight + SlideGridMetrics.labelGap) / 2)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: tileHovered || buttonHovered)
        } else {
            content
        }
    }
}
