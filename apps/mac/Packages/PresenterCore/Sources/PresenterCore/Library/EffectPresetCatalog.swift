import Foundation

public struct EffectPresetGroup: Identifiable, Sendable, Equatable {
    public var name: String
    public var presets: [EffectPreset]
    public var id: String { name }

    public init(name: String, presets: [EffectPreset]) {
        self.name = name
        self.presets = presets
    }
}

public extension EffectPreset {
    static let recommendedGroups: [EffectPresetGroup] = [

        EffectPresetGroup(name: "Frost", presets: [
            EffectPreset(id: "builtin.frost.light", name: "Light", effects: [
                Effect(effectKind: .scatter, amount: 12, scale: 1, speed: 0, smooth: 1),
            ]),
            EffectPreset(id: "builtin.frost.heavy", name: "Heavy", effects: [
                Effect(effectKind: .scatter, amount: 100, scale: 1, speed: 0, smooth: 1),
            ]),
        ]),
        EffectPresetGroup(name: "Static", presets: [
            EffectPreset(id: "builtin.static", name: "Static", effects: [
                Effect(effectKind: .scatter, amount: 8, scale: 1, speed: 1, smooth: 0),
            ]),
        ]),
        EffectPresetGroup(name: "Heat Haze", presets: [
            EffectPreset(id: "builtin.heatHaze", name: "Heat Haze", effects: [
                Effect(effectKind: .warp, amount: 40, scale: 240, speed: 0.5),
            ]),
        ]),
        EffectPresetGroup(name: "Long Trails", presets: [
            EffectPreset(id: "builtin.longTrails", name: "Long Trails", effects: [
                Effect(effectKind: .echo, amount: 6.9),
            ]),
        ]),

        EffectPresetGroup(name: "Amoeba", presets: [
            EffectPreset(id: "builtin.amoeba", name: "Amoeba", effects: [
                Effect(effectKind: .ghostTrails, amount: 6, scale: 240, speed: 0, fade: 1.5),
                Effect(effectKind: .warp, amount: 300, scale: 240, speed: 0),
                Effect(effectKind: .echo, amount: 20),
                Effect(effectKind: .scatter, amount: 5.5, scale: 1, speed: 0, smooth: 1),
            ]),
        ]),
        EffectPresetGroup(name: "Ghosty", presets: [
            EffectPreset(id: "builtin.ghosty", name: "Ghosty", effects: [
                Effect(effectKind: .ghostTrails, amount: 6, scale: 160, speed: 0, fade: 1.5),
                Effect(effectKind: .echo, amount: 6.9),
                Effect(effectKind: .scatter, amount: 5.5, scale: 1, speed: 0, smooth: 1),
            ]),
        ]),
    ]

    static var recommended: [EffectPreset] { recommendedGroups.flatMap(\.presets) }
}
