import SwiftUI

struct InkEnableToggle: View {
    @Bindable var ink: InkController

    var body: some View {
        Toggle("", isOn: Binding(
            get: { ink.enabled },
            set: { ink.enabled = $0 }
        ))
        .settingsToggle()
    }
}

struct InkPortField: View {
    let ink: InkController
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
            .onAppear { text = "\(ink.port)" }
            .onSubmit {
                if let value = UInt16(text), value >= 1024 {
                    ink.setPort(value)
                } else {
                    text = "\(ink.port)"
                }
            }
    }
}

struct InkConnectRow: View {
    let ink: InkController

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 6) {
                if let error = ink.lastError {
                    Text("Couldn't start: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !ink.running {
                    Text("Turn on Draw from iPad to connect")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let address = ink.address {
                    HStack(spacing: 8) {
                        Text(verbatim: address)
                            .font(.system(size: 11).monospaced())
                            .textSelection(.enabled)
                        CopyGlyphButton(value: address)
                    }
                } else {
                    Text("Serving on port \(String(ink.port)) — this Mac isn't on a network yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("PIN")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: ink.pin)
                        .font(.system(size: 13).monospaced())
                        .textSelection(.enabled)
                    Button("New PIN") { ink.regeneratePIN() }
                        .controlSize(.small)
                }
                if ink.running {
                    Text(ink.viewerCount == 0
                         ? "No iPad connected"
                         : "\(ink.viewerCount) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if ink.running, let qr = ink.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .accessibilityLabel("QR code for the draw page address")
            }
        }
    }
}
