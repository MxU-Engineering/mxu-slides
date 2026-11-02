import Foundation
import Observation

@MainActor
@Observable
final class NDIScreenOutputs {
    static let shared = NDIScreenOutputs()

    private(set) var controllers: [UUID: NDIOutputController] = [:]
    private static let defaultsKey = "ndi.screenBackings"

    private init() {}

    func status(for screenID: UUID) -> NDIOutputController.Status? {
        controllers[screenID]?.status
    }

    func isCarrying(_ screenID: UUID) -> Bool {
        controllers[screenID]?.isActive ?? false
    }

    var anySending: Bool {
        controllers.values.contains(where: \.isActive)
    }

    var anyAttention: Bool {
        controllers.values.contains { controller in
            switch controller.status {
            case .interrupted, .failed: true
            default: false
            }
        }
    }

    var sendingScreens: [(screenID: UUID, sourceName: String)] {
        controllers.compactMap { id, controller in
            if case .sending(let name) = controller.status { return (id, name) }
            return nil
        }
    }

    func enable(screenID: UUID, render: RenderContext) {

        guard let feed = render.outputs.networkCarryFeed(forSlice: screenID) else { return }
        disable(screenID: screenID)

        DeckLinkScreenOutputs.shared.disable(screenID: screenID, render: render)
        SyphonScreenOutputs.shared.disable(screenID: screenID)
        render.outputs.assignPlaceholderDevice(placeholderID: screenID, displayUUID: nil)
        let controller = NDIOutputController(render: render)
        controller.start(
            targetID: screenID.uuidString,
            targetName: feed.name,
            sourceName: feed.name,
            width: feed.width,
            height: feed.height,
            frameRate: feed.framesPerSecond,
            sourceRect: feed.sourceRect,
            placement: feed.placement
        )
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
