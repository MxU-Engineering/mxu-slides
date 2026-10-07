import Foundation
import PresenterCore
import RenderEngine

public enum VisibilityRules {

    public static func itemVisibility(for object: SlideObject) -> ItemVisibility? {
        guard let conditions = object.visibilityConditions, !conditions.isEmpty else { return nil }
        let match: ItemVisibility.Match = switch object.visibilityMatch ?? .all {
        case .all: .all
        case .any: .any
        case .none: .none
        }
        return ItemVisibility(match: match, conditions: conditions.map(condition(from:)))
    }

    static func condition(from schema: VisibilityCondition) -> ItemVisibility.Condition {
        let state: ItemVisibility.Condition.RequiredState? = switch schema.state {
        case .hasTimeRemaining: .hasTimeRemaining
        case .hasExpired: .hasExpired
        case .isRunning, .isActive: .isRunning
        case .isNotRunning, .isInactive: .isNotRunning
        case .isConnected: .isConnected
        case .isDisconnected: .isNotConnected
        case .hasText: .hasText
        case .hasNoText: .hasNoText
        }
        let kind: ItemVisibility.Condition.Kind
        switch schema.conditionKind {
        case .timer:
            kind = .timer(id: schema.timerId?.isEmpty == false ? schema.timerId : nil)
        case .videoCountdown:
            kind = .videoCountdown
        case .objectText:
            if let id = schema.objectId, !id.isEmpty {
                kind = .objectText(id: id)
            } else {
                kind = .unevaluable
            }
        case .audioPlayback:
            kind = .audioPlayback
        case .liveInput:
            kind = .liveInput(id: schema.liveInputId?.isEmpty == false ? schema.liveInputId : nil)
        case .capture:
            kind = .capture
        }
        guard let state else { return ItemVisibility.Condition(kind: .unevaluable, state: .isRunning) }
        return ItemVisibility.Condition(kind: kind, state: state)
    }

    public static func isShown(
        _ object: SlideObject,
        among siblings: [SlideObject],
        info: ConfidenceInfo,
        at date: Date
    ) -> Bool {
        isShown(itemVisibility(for: object), info: info, at: date) { id in
            guard let sibling = siblings.first(where: { $0.id == id }) else { return nil }
            return !sibling.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func filteredScene(
        _ scene: RenderScene, info: ConfidenceInfo, at date: Date
    ) -> RenderScene {
        guard scene.layers.contains(where: { layer in
            layer.items.contains { $0.visibility != nil }
        }) else { return scene }

        func objectHasText(_ objectId: String) -> Bool? {

            for layer in scene.layers {
                for item in layer.items
                where item.id == objectId || item.id.hasSuffix("-\(objectId)")
                    || item.id == "\(objectId)::text" || item.id.hasSuffix("-\(objectId)::text") {
                    if case .text(let text) = item.content {
                        return !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                }
            }
            return nil
        }

        var filtered = scene
        for index in filtered.layers.indices {
            filtered.layers[index].items.removeAll { item in
                !isShown(item.visibility, info: info, at: date, objectHasText: objectHasText)
            }
        }
        return filtered
    }

    static func isShown(
        _ visibility: ItemVisibility?,
        info: ConfidenceInfo,
        at date: Date,
        objectHasText: (String) -> Bool?
    ) -> Bool {
        guard let visibility, !visibility.conditions.isEmpty else { return true }
        let verdicts = visibility.conditions.map {
            holds($0, info: info, at: date, objectHasText: objectHasText)
        }
        switch visibility.match {
        case .all: return verdicts.allSatisfy { $0 ?? true }
        case .any: return verdicts.contains { $0 ?? true }
        case .none: return !verdicts.contains { $0 == true }
        }
    }

    private static func holds(
        _ condition: ItemVisibility.Condition,
        info: ConfidenceInfo,
        at date: Date,
        objectHasText: (String) -> Bool?
    ) -> Bool? {
        switch condition.kind {
        case .timer(let id):

            let snapshot: TimerSnapshot?
            if let id {
                snapshot = info.timers.first { $0.id == id }
            } else {
                snapshot = ConfidenceSceneBuilder.primaryTimer(info.timers)
            }
            guard let snapshot else { return nil }
            switch condition.state {
            case .isRunning: return snapshot.isLive
            case .isNotRunning: return !snapshot.isLive
            case .hasTimeRemaining:
                guard let remaining = snapshot.remaining(at: date) else { return nil }
                return remaining > 0
            case .hasExpired:
                guard let remaining = snapshot.remaining(at: date) else { return nil }
                return remaining <= 0
            case .isConnected, .isNotConnected, .hasText, .hasNoText: return nil
            }
        case .videoCountdown:

            guard let countdown = info.videoCountdown else {
                switch condition.state {
                case .isRunning, .hasTimeRemaining: return false
                case .isNotRunning: return true
                case .hasExpired: return false
                case .isConnected, .isNotConnected, .hasText, .hasNoText: return nil
                }
            }
            switch condition.state {
            case .isRunning: return countdown.isPlaying
            case .isNotRunning: return !countdown.isPlaying
            case .hasTimeRemaining: return countdown.remaining(at: date) > 0
            case .hasExpired: return countdown.remaining(at: date) <= 0
            case .isConnected, .isNotConnected, .hasText, .hasNoText: return nil
            }
        case .audioPlayback:

            guard let audio = info.audioCountdown else {
                switch condition.state {
                case .isRunning, .hasTimeRemaining: return false
                case .isNotRunning: return true
                case .hasExpired: return false
                case .isConnected, .isNotConnected, .hasText, .hasNoText: return nil
                }
            }
            switch condition.state {
            case .isRunning: return audio.isPlaying
            case .isNotRunning: return !audio.isPlaying
            case .hasTimeRemaining: return audio.remaining(at: date) > 0
            case .hasExpired: return audio.remaining(at: date) <= 0
            case .isConnected, .isNotConnected, .hasText, .hasNoText: return nil
            }
        case .liveInput(let id):

            guard let id else { return nil }
            switch condition.state {
            case .isRunning: return info.activeLiveInputIds.contains(id)
            case .isNotRunning: return !info.activeLiveInputIds.contains(id)
            case .isConnected: return info.connectedLiveInputIds.contains(id)
            case .isNotConnected: return !info.connectedLiveInputIds.contains(id)
            default: return nil
            }
        case .capture:
            switch condition.state {
            case .isRunning: return info.captureActive
            case .isNotRunning: return !info.captureActive
            default: return nil
            }
        case .objectText(let id):
            guard let hasText = objectHasText(id) else { return nil }
            switch condition.state {
            case .hasText: return hasText
            case .hasNoText: return !hasText
            default: return nil
            }
        case .unevaluable:
            return nil
        }
    }
}
