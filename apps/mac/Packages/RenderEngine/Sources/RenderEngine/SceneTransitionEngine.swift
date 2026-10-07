import CoreGraphics
import Foundation

public struct SceneTransition: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case cut
        case dissolve

        case fade(SceneColor)

        case blurDissolve

        case filmBurn
    }

    public var kind: Kind
    public var duration: Double

    public init(kind: Kind, duration: Double = 0.5) {
        self.kind = kind
        self.duration = min(max(duration, 0.05), 10)
    }

    public static let cut = SceneTransition(kind: .cut, duration: 0.05)
}

public final class SceneTransitionEngine: @unchecked Sendable {
    private struct Active {
        var previous: RenderScene
        var startedAt: Date

        var transitions: [LayerKind: SceneTransition]

        var duration: Double
    }

    private struct State {
        var target: RenderScene
        var active: Active?
    }

    private let state: Locked<State>

    private let pullCount = Locked<Int>(0)

    public func telemetry(at date: Date = Date()) -> (pulls: Int, transition: String?) {
        let pulls = pullCount.value
        let description: String? = state.withLock { s in
            guard let active = s.active else { return nil }
            let progress = Self.progress(of: active, at: date)
            let kinds = active.transitions.values.map { "\($0.kind)" }.joined(separator: "+")
            return "\(kinds) \(Int(progress * 100))% over \(active.transitions.count) layer(s)"
        }
        return (pulls, description)
    }

    public init(initial: RenderScene = RenderScene()) {
        state = Locked(State(target: initial, active: nil))
    }

    public func heldMediaIDs(at date: Date = Date()) -> Set<String> {
        state.withLock { s in
            guard let active = s.active,
                  date.timeIntervalSince(active.startedAt) < active.duration
            else { return [] }
            var ids = Set<String>()
            for layer in active.previous.layers where active.transitions.keys.contains(layer.kind) {
                for item in layer.items {

                    if let id = item.content.mediaID { ids.insert(id) }
                }
            }
            return ids
        }
    }

    public func push(_ scene: RenderScene, transition: SceneTransition) {
        push(scene) { _ in transition }
    }

    public func push(_ scene: RenderScene, transitionFor: (LayerKind) -> SceneTransition?) {
        state.withLock { s in
            let changed = Self.changedLayers(from: s.target, to: scene)

            guard !changed.isEmpty else {
                s.target = scene
                return
            }
            var transitions: [LayerKind: SceneTransition] = [:]
            for layer in changed {
                if let transition = transitionFor(layer), transition.kind != .cut {
                    transitions[layer] = transition
                }
            }
            guard !transitions.isEmpty else {
                s.target = scene

                s.active = nil
                return
            }

            let base = s.active.map { Self.composite(
                previous: $0.previous, target: s.target,
                transitions: $0.transitions,
                progress: Self.progress(of: $0, at: Date())
            ) } ?? s.target
            s.active = Active(
                previous: base, startedAt: Date(),
                transitions: transitions,
                duration: transitions.values.map(\.duration).max() ?? 0.05
            )
            s.target = scene
        }
    }

    public func scene(at date: Date) -> RenderScene {
        pullCount.withLock { $0 += 1 }
        return state.withLock { s in
            guard let active = s.active else { return s.target }
            let progress = Self.progress(of: active, at: date)
            if progress >= 1 {
                s.active = nil
                return s.target
            }
            return Self.composite(
                previous: active.previous, target: s.target,
                transitions: active.transitions, progress: progress
            )
        }
    }

    private static func progress(of active: Active, at date: Date) -> Double {
        min(max(date.timeIntervalSince(active.startedAt) / active.duration, 0), 1)
    }

    static func membershipKey(_ item: RenderItem) -> String {

        if let id = item.content.mediaID { return item.id + "|" + id }
        return item.id
    }

    static func changedLayers(from old: RenderScene, to new: RenderScene) -> Set<LayerKind> {
        var changed = Set<LayerKind>()
        for kind in LayerKind.allCases {
            let oldIDs = old.layers.first { $0.kind == kind }
                .map { Set($0.items.map(membershipKey)) } ?? []
            let newIDs = new.layers.first { $0.kind == kind }
                .map { Set($0.items.map(membershipKey)) } ?? []
            if oldIDs != newIDs { changed.insert(kind) }
        }
        return changed
    }

    static func composite(
        previous: RenderScene, target: RenderScene,
        transition: SceneTransition, progress: Double,
        layers: Set<LayerKind>
    ) -> RenderScene {
        composite(
            previous: previous, target: target,
            transitions: Dictionary(uniqueKeysWithValues: layers.map { ($0, transition) }),
            progress: progress
        )
    }

    static func composite(
        previous: RenderScene, target: RenderScene,
        transitions: [LayerKind: SceneTransition], progress: Double
    ) -> RenderScene {
        var scene = target
        for index in scene.layers.indices {
            let kind = scene.layers[index].kind
            guard let transition = transitions[kind] else { continue }
            let oldItems = previous.layers.first { $0.kind == kind }?.items ?? []
            let newItems = scene.layers[index].items

            let oldKeys = Set(oldItems.map(membershipKey))
            let newKeys = Set(newItems.map(membershipKey))

            let leaving = oldItems.filter { !newKeys.contains(membershipKey($0)) }
                .map { item in
                    var out = item
                    out.id += "::leaving"
                    return out
                }
            func arrivingFaded(_ items: [RenderItem], to opacity: Double) -> [RenderItem] {
                items.map { item in
                    guard !oldKeys.contains(membershipKey(item)) else { return item }
                    var out = item
                    out.opacity *= opacity
                    return out
                }
            }

            let hasArrivals = newItems.contains { !oldKeys.contains(membershipKey($0)) }
            let holdsUnder = hasArrivals
                && (kind == .loopingVideos || kind == .stillGraphics || kind == .videos)
            switch transition.kind {
            case .cut:
                continue
            case .dissolve:
                scene.layers[index].items =
                    (holdsUnder ? leaving : faded(leaving, to: 1 - progress))
                    + arrivingFaded(newItems, to: progress)
            case .fade(let plate):

                let firstHalf = progress < 0.5
                let plateOpacity = firstHalf ? progress * 2 : (1 - progress) * 2
                var items = firstHalf ? oldItems : newItems
                items.append(RenderItem(
                    id: "transition-plate-\(kind.rawValue)",
                    frame: CGRect(origin: .zero, size: scene.canvasSize),
                    content: .solid(SceneColor(
                        red: plate.red, green: plate.green, blue: plate.blue,
                        alpha: plateOpacity
                    ))
                ))
                scene.layers[index].items = items
            case .blurDissolve:

                let swell = (1 - abs(progress * 2 - 1)) * 60
                scene.layers[index].items =
                    blurred(holdsUnder ? leaving : faded(leaving, to: 1 - progress), radius: swell)
                    + blurred(arrivingFaded(newItems, to: progress), radius: swell)
            case .filmBurn:

                let peak = 1 - abs(progress * 2 - 1)
                let leaving = burned(faded(leaving, to: 1 - progress), amount: peak, phase: progress)
                let arriving = burned(arrivingFaded(newItems, to: progress), amount: peak, phase: progress)
                var items = leaving + arriving
                items.append(RenderItem(
                    id: "transition-plate-\(kind.rawValue)",
                    frame: CGRect(origin: .zero, size: scene.canvasSize),
                    content: .solid(SceneColor(red: 1, green: 0.72, blue: 0.42, alpha: peak * 0.35))
                ))
                scene.layers[index].items = items
            }
        }
        return scene
    }

    private static func faded(_ items: [RenderItem], to opacity: Double) -> [RenderItem] {
        items.map { item in
            var out = item
            out.opacity *= opacity
            return out
        }
    }

    private static func burned(_ items: [RenderItem], amount: Double, phase: Double) -> [RenderItem] {
        guard amount > 0.01 else { return items }
        return items.map { item in
            var out = item
            out.effects = [SceneEffect(kind: .burn(amount: amount, phase: phase))] + out.effects
            return out
        }
    }

    private static func blurred(_ items: [RenderItem], radius: Double) -> [RenderItem] {
        guard radius > 0.5 else { return items }
        return items.map { item in
            var out = item
            out.effects = [SceneEffect(kind: .blur(radius: radius))] + out.effects
            return out
        }
    }
}
