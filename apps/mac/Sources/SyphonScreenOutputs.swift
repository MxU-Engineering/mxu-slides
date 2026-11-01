import Foundation
import Observation

@MainActor
@Observable
final class SyphonScreenOutputs {
    static let shared = SyphonScreenOutputs()

    private(set) var controllers: [UUID: SyphonOutputController] = [:]
    private static let defaultsKey = "syphon.screenBackings"

    private init() {}

    func status(for screenID: UUID) -> SyphonOutputController.Status? {
        controllers[screenID]?.status
    }

    func isCarrying(_ screenID: UUID) -> Bool {
        controllers[screenID]?.isActive ?? false
    }

    func enable(screenID: UUID, render: RenderContext) {

        guard let feed = render.outputs.networkCarryFeed(forSlice: screenID) else { return }
        disable(screenID: screenID)

        NDIScreenOutputs.shared.disable(screenID: screenID)
        DeckLinkScreenOutputs.shared.disable(screenID: screenID, render: render)
        render.outputs.assignPlaceholderDevice(placeholderID: screenID, displayUUID: nil)
        let controller = SyphonOutputController(render: render)
        controller.start(targetID: screenID.uuidString, feed: feed)
        controllers[screenID] = controller
        persist()
    }

    func disable(screenID: UUID) {
        controllers[screenID]?.stop()
        controllers[screenID] = nil
        persist()
    }

    func restore(render: RenderContext) {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        for raw in stored {
            guard let id = UUID(uuidString: raw) else { continue }
            enable(screenID: id, render: render)
        }
    }

    private func persist() {
        UserDefaults.standard.set(
            controllers.keys.map(\.uuidString).sorted(), forKey: Self.defaultsKey)
    }
}
