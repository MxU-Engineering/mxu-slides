import Foundation
import NDIKit
import Network

enum NDINetworkScope {
    static let interfaceKey = "ndi.interface"

    static var selectedBSDName: String {
        get { UserDefaults.standard.string(forKey: interfaceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: interfaceKey) }
    }

    static func apply() {
        let selection = selectedBSDName
        var ips: [String] = []
        if !selection.isEmpty {
            if let adapter = NDIAdapterList.current()
                .first(where: { $0.bsdName == selection }) {
                ips = [adapter.ipv4]
            } else {
                DiagnosticsStore.shared.note(
                    "ndi.network",
                    detail: "\(selection) has no address; using all networks")
            }
        }
        do {
            try NDIRuntimeConfig.activate(allowedAdapterIPs: ips)
        } catch {
            DiagnosticsStore.shared.note(
                "ndi.network", detail: "config write failed: \(error)")
        }
    }

    @MainActor private static var pathMonitor: NWPathMonitor?
    @MainActor private static var lastFingerprint = ""
    @MainActor private static var debounceToken = 0

    @MainActor
    static func watchNetworkChanges() {
        guard pathMonitor == nil else { return }
        lastFingerprint = NDIAdapterList.fingerprint(NDIAdapterList.current())
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            Task { @MainActor in
                debounceToken += 1
                let token = debounceToken

                try? await Task.sleep(for: .seconds(3))
                guard token == debounceToken else { return }
                let now = NDIAdapterList.fingerprint(NDIAdapterList.current())
                guard now != lastFingerprint else { return }
                lastFingerprint = now
                DiagnosticsStore.shared.note(
                    "ndi.network", detail: "addressing changed — re-applying pin")
                await applyLive()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    @MainActor
    static func applyLive() async {
        apply()
        let rested = VideoInputInventory.shared.restNDIForRuntimeSwap()

        let swapped = await Task.detached(priority: .userInitiated) {
            NDILibrary.reinitialize()
        }.value
        if !swapped {
            DiagnosticsStore.shared.note(
                "ndi.network", detail: "runtime busy — pin applies at next launch")
        }
        VideoInputInventory.shared.rewarmAfterRuntimeSwap(rested)
        for controller in NDIScreenOutputs.shared.controllers.values {
            controller.reloadNetworkPin()
        }
    }
}
