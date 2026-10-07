import Foundation

@MainActor
public protocol LocalAPIBridge: AnyObject, Sendable {

    func librarySummary() throws -> APILibrarySummary
    func libraryEntries(kind: APIDocumentKind) throws -> [APILibraryEntry]

    func documentJSON(kind: APIDocumentKind, id: String) async throws -> Data
    func showStatus() -> APIShowStatus
    func timers() -> [APITimerStatus]
    func audioStatus() -> APIAudioStatus
    func transportRows() -> [APITransportRow]
    func outputsStatus() -> APIOutputsStatus
    func schedulerStatus() -> APISchedulerStatus

    func fireSlide(_ command: APIFireSlideCommand) async throws

    func advance(steps: Int, settled: Bool) async throws
    func clear(_ command: APIClearCommand) throws
    func clearAll()
    func fireMedia(id: String) throws
    func fireOverlay(id: String) throws
    func fireActionCombo(id: String) throws
    func dismissOverlay(id: String) throws
    func fireAlert(_ command: APIFireAlertCommand) throws
    func dismissAlert()
    func timerAction(id: String, action: APITimerAction) throws
    func fireAudioPlaylist(id: String, startAtEntryId: String?) throws
    func fireAudioItem(id: String) throws
    func stopAudio(_ command: APIAudioStopCommand) throws
    func audioTransport(_ command: APIAudioTransportCommand) throws
    func mediaTransport(id: String, command: APIMediaTransportCommand) throws
    func activateOutputPreset(id: String?) throws

    func selectService(id: String) throws

    func setSchedulerEnabled(_ enabled: Bool)
    func setScheduleTriggerEnabled(id: String, enabled: Bool) throws

    func fireScheduleTrigger(id: String) throws

    func midiDevices() -> [APIMIDIDeviceStatus]
    func setMIDIDeviceEnabled(id: String, enabled: Bool) throws

    func videoInputs() -> [APIVideoInputStatus]
    func audioInputs() -> [APIAudioInputStatus]
    func audioMixes() -> [APIAudioMixStatus]
    func setMixerInput(id: String, command: APIMixerInputCommand) throws

    func createDocument(kind: APIDocumentKind, body: Data) async throws -> String
    func updateDocument(kind: APIDocumentKind, id: String, body: Data) async throws
    func deleteDocument(kind: APIDocumentKind, id: String) async throws
    func addServiceItem(serviceId: String, refId: String, index: Int?) throws
}
