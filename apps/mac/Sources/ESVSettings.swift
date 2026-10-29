import BibleKit
import Foundation
import Observation
import Security
import SwiftUI

private enum ESVKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.example.mxuslides.esv",
         kSecAttrAccount as String: "api-key"]
    }

    static func load() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { throw ESVError.missingKey }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw BibleError.message("Could not read the ESV key from Keychain (\(status)).")
        }
        return key
    }

    static func save(_ key: String) throws {
        let value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query.merging(value) { _, new in new }
            attributes[kSecAttrLabel as String] = "MxU Slides — ESV"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BibleError.message("Could not save the ESV key in Keychain (\(status)).") }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BibleError.message("Could not remove the ESV key from Keychain (\(status)).")
        }
    }
}

@MainActor
@Observable
final class ESVSettings {
    static let shared = ESVSettings()
    private let defaults = UserDefaults.standard
    private(set) var hasKey = UserDefaults.standard.bool(forKey: "bible.esv.hasKey")
    private(set) var revision = 0
    private(set) var busy = false
    private(set) var status = ""
    @ObservationIgnored private var cachedClient: ESVClient?
    var enabled = UserDefaults.standard.bool(forKey: "bible.esv.enabled") {
        didSet { defaults.set(enabled, forKey: "bible.esv.enabled"); revision &+= 1 }
    }

    func client() async throws -> ESVClient {
        guard hasKey, enabled else { throw ESVError.missingKey }
        if let cachedClient { return cachedClient }
        let key = try await Task.detached { try ESVKeychain.load() }.value
        let client = ESVClient(apiKey: key)
        cachedClient = client
        return client
    }

    func connect(_ key: String) async -> Bool {
        guard !busy else { return false }
        busy = true; status = "Checking ESV API key…"
        defer { busy = false }
        do {
            let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = ESVClient(apiKey: candidate)
            _ = try await client.lookup(query: "John 11:35", search: false)
            try await Task.detached { try ESVKeychain.save(candidate) }.value
            cachedClient = client; hasKey = true
            defaults.set(true, forKey: "bible.esv.hasKey")
            enabled = true; revision &+= 1
            status = "Connected. ESV (Crossway API) is now available in Bible."
            return true
        } catch { status = error.localizedDescription; return false }
    }

    func remove() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await Task.detached { try ESVKeychain.remove() }.value
            cachedClient = nil; hasKey = false; enabled = false
            defaults.set(false, forKey: "bible.esv.hasKey")
            revision &+= 1; status = "ESV API key removed. Saved presentations were not deleted."
        } catch { status = error.localizedDescription }
    }
}

struct ESVSettingsSection: View {
    @State private var settings = ESVSettings.shared
    @State private var key = ""
    var body: some View {
        Section("ESV · Crossway API") {
            Toggle("Show ESV from Crossway in Bible", isOn: $settings.enabled)
                .disabled(!settings.hasKey || settings.busy)
            SecureField(settings.hasKey ? "Replace ESV API key…" : "ESV application API key", text: $key)
                .textFieldStyle(.roundedBorder).disabled(settings.busy)
            HStack {
                Button("Save Key & Connect") { Task { if await settings.connect(key) { key = "" } } }
                    .disabled(settings.busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if settings.hasKey { Button("Remove ESV Key") { Task { await settings.remove() } }.disabled(settings.busy) }
                if settings.busy { ProgressView().controlSize(.small) }
            }
            if !settings.status.isEmpty { Text(settings.status).font(.callout).textSelection(.enabled) }
            Text("Use your own application key, saved in this Mac's Keychain. This is separate from API.Bible. No account password is needed.")
                .font(.caption).foregroundStyle(.secondary)
            Text("For non-commercial use under Crossway's API conditions. Temporary Sunday presentations can be saved; the app checks tracked ESV verses against the local storage allowance. Remove older presentations when needed—nothing is deleted automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Create an ESV API application / usage conditions", destination: URL(string: "https://api.esv.org/")!)
            DisclosureGroup("ESV copyright information") { Text(ESVClient.copyright).font(.caption).textSelection(.enabled) }
        }
        .onDisappear { key = "" }
    }
}
