import PresenterCore
import SwiftUI

struct RunOnlyLockedPlaceholder: View {
    let surface: String

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("\(surface) is hidden in Volunteer Mode.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Leave Volunteer Mode from the mode switcher.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
    }
}

@MainActor
@Observable
final class VolunteerModeRouter {
    static let shared = VolunteerModeRouter()
    private(set) var requests = 0

    func request() {
        requests += 1
    }
}

struct VolunteerMenuRequests: ViewModifier {
    let layout: PresentLayoutController?

    func body(content: Content) -> some View {
        content.onChange(of: VolunteerModeRouter.shared.requests) { _, _ in
            if UserDefaults.standard.bool(forKey: VolunteerModeLogic.enabledKey), layout?.runOnly == false {
                layout?.enterRunOnly()
            }
        }
    }
}
