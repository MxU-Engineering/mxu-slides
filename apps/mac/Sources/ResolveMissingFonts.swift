import AppKit
import PresenterCore
import SwiftUI

@MainActor
enum ResolveMissingFontsWindow {
    private static var window: NSWindow?

    static func present(
        missingFamilies: [String],
        apply: @escaping ([String: String]) -> Void
    ) {
        window?.close()
        let hosting = NSHostingController(
            rootView: ResolveMissingFontsView(missingFamilies: missingFamilies) { replacements in
                window?.close()
                window = nil
                if !replacements.isEmpty { apply(replacements) }
            }
        )
        let panel = NSWindow(contentViewController: hosting)
        panel.title = "Resolve Missing Fonts"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

struct ResolveMissingFontsView: View {
    let missingFamilies: [String]
    let finish: ([String: String]) -> Void

    @State private var choices: [String: String] = [:]

    private static let installedFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("These fonts aren't installed. Replacing a font rewrites the imported slides; Don't Replace keeps the name and a substitute shows until the font is installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(missingFamilies, id: \.self) { family in
                    HStack(spacing: 12) {
                        Text(family)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Picker("", selection: binding(for: family)) {
                            Text("(Don't Replace)").tag("")
                            Divider()
                            ForEach(Self.installedFamilies, id: \.self) { installed in
                                Text(installed).tag(installed)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle.standard(CornerStandard.element))
            HStack {
                Spacer()
                Button("Continue") {
                    finish(choices.filter { !$0.value.isEmpty })
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func binding(for family: String) -> Binding<String> {
        Binding(
            get: { choices[family] ?? "" },
            set: { choices[family] = $0 }
        )
    }
}
