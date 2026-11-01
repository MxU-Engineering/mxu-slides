import LocalAPI
import PresenterCore
import SwiftUI

struct FollowSettingsControl: View {
    @State private var choosing = false

    var body: some View {
        let follow = FollowController.shared
        if let pairing = follow.pairing {
            HStack(spacing: 8) {
                Picker("While \(pairing.name) runs", selection: Binding(
                    get: { pairing.mirrors ?? true },
                    set: { mirrors in Task { await follow.setMirrors(mirrors) } })) {
                    Text("Show it live").tag(true)
                    Text("Stay ready").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Button("Stop Backing Up") { Task { await follow.unpair() } }
            }
        } else {
            Button("Back Up Another Computer\u{2026}") { choosing = true }
                .disabled(follow.me == nil)
                .sheet(isPresented: $choosing) {
                    FollowPairingSheet(own: follow.me)
                }
        }
    }
}

struct FollowPairingCodeControl: View {
    let api: LocalAPIController?

    var body: some View {
        if FollowController.shared.pairing != nil {
            EmptyView()
        } else if let api, api.running {
            HStack(spacing: 8) {
                Text(api.pairingCode).font(.title3.monospacedDigit().weight(.semibold))
                Button("New Code") { api.newPairingCode() }
            }
        } else {
            Text("Turn on the API in Network & API first.").foregroundStyle(.secondary)
        }
    }
}

struct FollowPairingSheet: View {
    let own: String?

    @Environment(\.dismiss) private var dismiss
    @State private var peers: [BonjourBrowser.Peer] = []
    @State private var picked: String?
    @State private var code = Self.qaCode
    @State private var working = false
    @State private var problem: String?
    @State private var unconnected: [String] = []

    @State private var automatic = true

    @State private var mirrors = true

    private static var qaCode: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["MXU_QA_FOLLOW_CODE"] ?? ""
        #else
        ""
        #endif
    }

    private var peer: BonjourBrowser.Peer? { peers.first { $0.stationHexId == picked } }
    private var name: String { peer.map(displayName) ?? "that computer" }

    private func displayName(_ peer: BonjourBrowser.Peer) -> String {
        peer.stationName ?? peer.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Back up another computer").font(.headline)
            Text("This computer follows the other one fire for fire: live on its own screens, or ready with clear screens until it takes over. Its own triggers wait until then.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if peers.isEmpty {
                Label("Looking for MxU Slides on this network\u{2026} The other computer needs MxU Slides open with its API on.", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Text("Computer").gridColumnAlignment(.trailing)
                        Picker("Computer", selection: $picked) {
                            ForEach(peers, id: \.stationHexId) { peer in
                                Text(displayName(peer)).tag(Optional(peer.stationHexId))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Code \(name) shows")
                        TextField("0000", text: $code)
                            .frame(width: 70)
                            .font(.body.monospacedDigit())
                    }
                    GridRow {
                        Text("While \(name) runs")
                        Picker("While \(name) runs", selection: $mirrors) {
                            Text("Show the same thing live").tag(true)
                            Text("Stay ready, show nothing").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("If \(name) stops")
                        Picker("If \(name) stops", selection: $automatic) {
                            Text("Take over after 3 seconds").tag(true)
                            Text("Wait for Take Over").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                checks
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Backing Up") { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(peer == nil || code.count != 4 || working)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await browse() }
        .onAppear { unconnected = Follow.unconnectedScreens(in: UserDefaults.standard.dictionaryRepresentation()) }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            check("Copies \(name)'s library, output presets and stream presets here over the network.", ok: true)
            ForEach(unconnected, id: \.self) { screen in
                check("\(screen) isn't connected on this computer, so it won't show here. Connect it in Settings › Screens.", ok: false)
            }
        }
        .font(.caption)
    }

    private func check(_ text: String, ok: Bool) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ok ? "checkmark" : "exclamationmark.triangle")
                .foregroundStyle(ok ? .green : .orange)
        }
    }

    private func browse() async {
        let browser = BonjourBrowser(ownStationHexId: own)
        defer { browser.stop() }
        for await found in browser.start() {
            peers = found.sorted { $0.name < $1.name }
            if picked == nil || !peers.contains(where: { $0.stationHexId == picked }) { picked = peers.first?.stationHexId }
        }
    }

    private func pair() {
        guard let peer else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            if let refused = await FollowController.shared.pair(with: peer, name: displayName(peer), code: code, automatic: automatic, mirrors: mirrors) {
                problem = refused
                return
            }
            dismiss()
        }
    }
}
