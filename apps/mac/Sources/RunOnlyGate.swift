import PresenterCore
import SwiftUI

enum PinFlow: String, Identifiable {
    case set
    case verify
    case change

    var id: String { rawValue }
}

struct PasscodeSheet: View {
    let flow: PinFlow

    let verify: (String) -> Bool

    var waitSeconds: () -> Int = { 0 }

    let onSuccess: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var problem: String?
    private enum Field { case current, pin }
    @FocusState private var focus: Field?

    private var title: String {
        switch flow {
        case .set: "Set Run-Only Passcode"
        case .verify: "Enter Passcode"
        case .change: "Change Run-Only Passcode"
        }
    }

    private var caption: String {
        switch flow {
        case .set: "4–6 digits. Exiting run-only mode — and reaching editing — will ask for it."
        case .verify: "Run-only mode stays on until the passcode is entered."
        case .change: "Enter the current passcode, then the new one (4–6 digits) twice."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if flow == .change {
                SecureField("Current passcode", text: $current)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .current)
            }
            SecureField(flow == .change ? "New passcode" : "Passcode", text: $pin)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .pin)
                .onSubmit { flow == .verify ? submit() : nil }
            if flow != .verify {
                SecureField("Repeat passcode", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(flow == .verify ? "Unlock" : "Set Passcode", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { focus = flow == .change ? .current : .pin }
    }

    private func submit() {
        let wait = waitSeconds()
        if flow != .set && wait > 0 {
            problem = RunOnlyPINCopy.wait(wait)
        } else if flow == .verify {
            if verify(pin) {
                onSuccess(pin)
                dismiss()
            } else {
                problem = "Wrong passcode."
                pin = ""
            }
        } else if flow == .change && !verify(current) {
            problem = "The current passcode is wrong."
            current = ""
        } else if !RunOnlyPasscode.isValid(pin: pin) {
            problem = "Use 4–6 digits."
        } else if pin != confirmation {
            problem = "Passcodes don't match."
            confirmation = ""
        } else {
            onSuccess(pin)
            dismiss()
        }
    }
}

enum RunOnlyPINCopy {
    static func wait(_ seconds: Int) -> String {
        "Too many tries. Try again in \(seconds) second\(seconds == 1 ? "" : "s")."
    }
}

struct RunOnlyLockedPlaceholder: View {
    let surface: String

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("\(surface) is locked in run-only mode.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Exit run-only from the lock in the titlebar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
    }
}

struct RunOnlyEntry: Identifiable {
    let id = UUID()
    let saved: PresentLayout?

    weak var settingsWindow: NSWindow?
}

struct RunOnlyEntrySheet: View {
    let needsPIN: Bool
    let initial: [ServiceControlsModule]

    let onEnter: (_ pin: String?, _ modules: [ServiceControlsModule]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<ServiceControlsModule> = []
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter Run-Only Mode")
                .font(.headline)
            Text("Volunteers can run slides, clears, and the Service Controls tabs checked below. Everything else stays locked until the passcode is entered.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("WHAT VOLUNTEERS SEE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                ForEach(ServiceControlsModule.defaultOrder, id: \.self) { module in
                    Toggle(module.title, isOn: Binding(
                        get: { chosen.contains(module) },
                        set: { on in
                            if on { chosen.insert(module) } else { chosen.remove(module) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            if needsPIN {
                Text("Set a 4–6 digit passcode. Leaving run-only asks for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Passcode", text: $pin)
                    .textFieldStyle(.roundedBorder)
                SecureField("Repeat passcode", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Enter Run-Only", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { chosen = Set(initial) }
    }

    private func submit() {
        if chosen.isEmpty {
            problem = "Check at least one tab."
        } else if needsPIN && !RunOnlyPasscode.isValid(pin: pin) {
            problem = "Use 4–6 digits."
        } else if needsPIN && pin != confirmation {
            problem = "Passcodes don't match."
            confirmation = ""
        } else {
            onEnter(needsPIN ? pin : nil, ServiceControlsModule.defaultOrder.filter(chosen.contains))
            dismiss()
        }
    }
}
