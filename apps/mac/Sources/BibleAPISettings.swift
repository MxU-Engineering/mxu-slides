import BibleKit
import Foundation
import Observation
import Security
import SwiftUI

/// Separate from the Local API credential: this key authenticates outbound
/// requests to API.Bible. Never put it in UserDefaults, documents, or log messages.
private enum BibleAPIKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.example.mxuslides.apibible",
         kSecAttrAccount as String: "api-key"]
    }

    static func load() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { throw BibleAPIError.missingKey }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw BibleError.message("Could not read the API.Bible key from Keychain (\(status)).")
        }
        return key
    }

    static func save(_ key: String) throws {
        let value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query.merging(value) { _, new in new }
            attributes[kSecAttrLabel as String] = "MxU Slides — API.Bible"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BibleError.message("Could not save the API.Bible key in Keychain (\(status)).") }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BibleError.message("Could not remove the API.Bible key from Keychain (\(status)).")
        }
    }
}

@MainActor
@Observable
final class BibleAPISettings {
    static let shared = BibleAPISettings()
    private static let prefix = "bible.apiBible."
    private let defaults = UserDefaults.standard
    private let deviceID: String
    private(set) var catalog: [APIBible]
    private(set) var selectedIDs: Set<String>
    private(set) var hasStoredKey: Bool
    private(set) var busy = false
    private(set) var status = ""
    private(set) var revision = 0
    private(set) var credentialRevision = 0
    @ObservationIgnored private var cachedClient: BibleAPIClient?

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.prefix + "enabled"); revision &+= 1 }
    }

    private init() {
        let storedID = UserDefaults.standard.string(forKey: Self.prefix + "deviceID") ?? UUID().uuidString
        deviceID = storedID
        UserDefaults.standard.set(storedID, forKey: Self.prefix + "deviceID")
        let data = defaults.data(forKey: Self.prefix + "catalog") ?? Data()
        catalog = (try? JSONDecoder().decode([APIBible].self, from: data)) ?? []
        selectedIDs = Set(defaults.stringArray(forKey: Self.prefix + "selected") ?? [])
        hasStoredKey = defaults.bool(forKey: Self.prefix + "hasKey")
        enabled = defaults.bool(forKey: Self.prefix + "enabled")
        // Do not access Keychain merely because the app or settings window opens.
        // Load the secret only for an explicit connection test or online lookup.
    }

    var available: [APIBible] {
        enabled && hasStoredKey ? catalog.filter { selectedIDs.contains($0.id) } : []
    }

    func setSelected(_ id: String, _ selected: Bool) {
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        defaults.set(selectedIDs.sorted(), forKey: Self.prefix + "selected")
        revision &+= 1
    }

    func client() async throws -> BibleAPIClient {
        guard enabled, hasStoredKey else { throw BibleAPIError.missingKey }
        if let cachedClient { return cachedClient }
        let key = try await Task.detached(priority: .userInitiated) { try BibleAPIKeychain.load() }.value
        let client = BibleAPIClient(apiKey: key, deviceID: deviceID)
        cachedClient = client
        return client
    }

    func connect(key: String) async -> Bool {
        guard !busy else { return false }
        busy = true; status = "Checking API key and loading available Bibles…"
        defer { busy = false }
        do {
            let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = BibleAPIClient(apiKey: candidate, deviceID: deviceID)
            let bibles = try await client.bibles()
            // Validate first: an invalid replacement key must not destroy a working one.
            try await Task.detached(priority: .userInitiated) { try BibleAPIKeychain.save(candidate) }.value
            cachedClient = client
            credentialRevision &+= 1
            hasStoredKey = true
            defaults.set(true, forKey: Self.prefix + "hasKey")
            enabled = true
            installCatalog(bibles)
            status = "Connected. \(bibles.count) Bibles are available to this API key. Choose the ones to show below."
            return true
        } catch { status = error.localizedDescription; return false }
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; status = "Refreshing Bibles…"
        defer { busy = false }
        do {
            let bibles = try await client().bibles()
            installCatalog(bibles)
            status = "Refreshed \(bibles.count) Bibles. \(selectedIDs.count) selected."
        } catch { status = error.localizedDescription }
    }

    func removeKey() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await Task.detached(priority: .userInitiated) { try BibleAPIKeychain.remove() }.value
            credentialRevision &+= 1
            cachedClient = nil; hasStoredKey = false; enabled = false
            defaults.set(false, forKey: Self.prefix + "hasKey")
            status = "API key removed. Offline Bibles remain available."
        } catch { status = error.localizedDescription }
    }

    private func installCatalog(_ bibles: [APIBible]) {
        catalog = bibles
        selectedIDs.formIntersection(Set(bibles.map(\.id)))
        // Only IDs, names, language and copyright metadata are persisted, not Scripture.
        defaults.set(try? JSONEncoder().encode(bibles), forKey: Self.prefix + "catalog")
        defaults.set(selectedIDs.sorted(), forKey: Self.prefix + "selected")
        revision &+= 1
    }
}

struct BibleAPISettingsPane: View {
    @State private var settings = BibleAPISettings.shared
    @State private var key = ""
    @State private var filter = ""
    @State private var selectedOnly = false

    private var filtered: [APIBible] {
        settings.catalog.filter { bible in
            (!selectedOnly || settings.selectedIDs.contains(bible.id)) &&
            (filter.isEmpty || "\(bible.abbreviation) \(bible.name) \(bible.language)".localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        Form {
            ESVSettingsSection()
            Section("API.Bible") {
                Toggle("Show selected API.Bible translations in Bible", isOn: $settings.enabled)
                    .disabled(!settings.hasStoredKey || settings.busy)
                Text("Use an API.Bible application API key. Your API.Bible account password is not needed.")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField(settings.hasStoredKey ? "Replace saved API key…" : "API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .disabled(settings.busy)
                HStack {
                    Button("Save Key & Load Bibles") {
                        Task { if await settings.connect(key: key) { key = "" } }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.busy)
                    Button("Refresh Bibles") { Task { await settings.refresh() } }
                        .disabled(!settings.hasStoredKey || !settings.enabled || settings.busy)
                    if settings.hasStoredKey {
                        Button("Remove API Key") { Task { await settings.removeKey() } }.disabled(settings.busy)
                    }
                    if settings.busy { ProgressView().controlSize(.small) }
                }
                if !settings.status.isEmpty { Text(settings.status).font(.callout).textSelection(.enabled) }
                Text(settings.hasStoredKey ? "API key saved in this Mac's Keychain." : "No API key saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Available Bibles · \(settings.selectedIDs.count) selected") {
                TextField("Filter by name, abbreviation, or language — NIV, NLT, ESV…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("Show selected only", isOn: $selectedOnly)
                if settings.catalog.isEmpty {
                    Text("Connect above to load the Bibles available to your application. Translation access depends on your API.Bible plan and publisher permissions.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filtered) { bible in
                                Toggle(isOn: Binding(get: { settings.selectedIDs.contains(bible.id) },
                                                     set: { settings.setSelected(bible.id, $0) })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(bible.abbreviation) — \(bible.name)")
                                        Text(bible.language).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .disabled(settings.busy)
                            }
                            if filtered.isEmpty { Text("No matching Bibles. Try another filter or check your account access.").foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                    .frame(height: 230)
                }
            }
            Section("Online Scripture") {
                Text("Passages are fetched on demand. The app does not download whole API.Bible translations or keep a disk cache of fetched Scripture. WEB and imported Bible files continue to work offline.")
                Text("API.Bible receives anonymous preview usage reports (a response token and random device/session IDs) through its Fair Use system.").font(.caption).foregroundStyle(.secondary)
                Text("API.Bible publisher attribution is included on generated slides. Saved or appended slides remain normal library documents; use them according to your translation's license.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("API.Bible Dashboard", destination: URL(string: "https://api.bible/dashboard")!)
                    Link("Translation Access", destination: URL(string: "https://api.bible/bibles")!)
                    Link("Terms", destination: URL(string: "https://api.bible/terms-and-conditions")!)
                }
            }
        }
        .settingsForm()
        .onDisappear { key = "" }
    }
}
