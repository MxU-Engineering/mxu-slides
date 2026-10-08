import LocalAPI
import SwiftUI

extension APIScope {
    var label: String {
        switch self {
        case .view: "Watch"
        case .control: "Operate"
        case .edit: "Manage"
        }
    }

    var explanation: String {
        switch self {
        case .view:
            "Read-only. See what's live and read the library, except stream presets that may contain credentials. Can't change anything on the glass. For dashboards and status displays."
        case .control:
            "Everything Watch sees, plus running the show: fire slides, clear, alerts, music and video transport. Can't create or edit content. The usual pick for a remote or Stream Deck."
        case .edit:
            "Everything Watch and Operate can do, plus create, edit, and delete presentations and services. The full-access level — give it only to trusted automation."
        }
    }
}

struct LocalAPIEnableToggle: View {
    @Bindable var api: LocalAPIController

    var body: some View {
        Toggle("", isOn: Binding(
            get: { api.enabled },
            set: { api.enabled = $0 }
        ))
        .settingsToggle()
    }
}

struct LocalAPIPortField: View {
    let api: LocalAPIController
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
            .onAppear { text = "\(api.port)" }
            .onSubmit {
                if let value = UInt16(text), value >= 1024 {
                    api.setPort(value)
                } else {
                    text = "\(api.port)"
                }
            }
    }
}

struct LocalAPIAddressRow: View {
    let api: LocalAPIController

    private var copyValue: String {
        api.lanAddress ?? "localhost:\(api.port)"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if let error = api.lastError {
                    Text("Couldn't start: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let address = api.lanAddress {
                    Text(verbatim: address)
                        .font(.system(size: 11).monospaced())
                        .textSelection(.enabled)
                } else if api.running {
                    Text("Serving on port \(String(api.port)) — this Mac isn't on a network yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Turn on the Local API to connect")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                CopyGlyphButton(value: copyValue)
            }

            if api.running, let secret = api.defaultKeySecret {
                HStack(spacing: 8) {
                    Text("Default key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: secret)
                        .font(.system(size: 11).monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                    CopyGlyphButton(value: secret)
                }
            }
        }
    }
}

struct CopyGlyphButton: View {
    let value: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .help("Copy \(value)")
    }
}

struct LocalAPIContractRow: View {
    let api: LocalAPIController

    var body: some View {
        HStack(spacing: 8) {
            Button("Open API Reference") {
                if let url = URL(string: api.docsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(!api.running)
            CopyGlyphButton(value: api.docsURL)
        }
    }
}

struct LocalAPITokensButton: View {
    let api: LocalAPIController
    @State private var managing = false

    var body: some View {
        HStack(spacing: 10) {
            if !api.hasAnyKey {
                Text("No keys yet")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Manage Keys…") { managing = true }
        }
        .sheet(isPresented: $managing) {
            LocalAPITokensSheet(api: api)
        }
    }
}

struct LocalAPITokensSheet: View {
    let api: LocalAPIController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue

    private var tokens: [APIToken] { api.allKeys }
    @State private var newName = ""
    @State private var newScope: APIScope = .control
    @State private var mintedSecret: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Access Keys")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    
                    .keyboardShortcut(.defaultAction)
            }
            Text("Give each device its own key. The access level decides what that device is allowed to do — a higher level includes everything below it.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            if let mintedSecret {
                mintedBanner(mintedSecret)
            }

            if tokens.isEmpty {
                Text("No keys yet — nothing can connect until you create one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(tokens) { token in
                        tokenRow(token)
                        if token.id != tokens.last?.id {
                            Divider().padding(.leading, 10)
                        }
                    }
                }
                .background(
                    Color.cardSurface,
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Name this device (e.g. Companion, Stream Deck)", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(6)
                        .background(
                            Color.primary.opacity(0.05),
                            in: RoundedRectangle.standard(CornerStandard.element)
                        )
                    QuietMenuChip(title: newScope.label) {
                        ForEach(APIScope.allCases, id: \.self) { scope in
                            Button(scope.label) { newScope = scope }
                        }
                    }
                    Button("Create") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        let minted = api.tokens.create(name: name, scope: newScope)
                        mintedSecret = minted.secret
                        copied = false
                        newName = ""
                        api.keysDidChange()
                    }
                    
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(newScope.explanation)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 480)
        .background(Color.basePlane)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
    }

    private func mintedBanner(_ secret: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Copy this key now — it won't be shown again.")
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                Text(secret)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(secret, forType: .string)
                    copied = true
                }
                .controlSize(.mini)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.green.opacity(0.12),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    private func tokenRow(_ token: APIToken) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(token.name)
                    .font(.system(size: 11, weight: .medium))
                Text("\(token.prefix)…  ·  created \(token.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(token.scope.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Button {

                api.revokeKey(id: token.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Revoke — a device using this key loses access immediately")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
