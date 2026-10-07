import RenderEngine

public enum ColorHex {
    public static func color(_ hex: String) -> SceneColor? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt64(digits, radix: 16)
        else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return SceneColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    public static func hex(_ color: SceneColor) -> String {
        func byte(_ component: Double) -> UInt64 {
            UInt64((component.clamped(to: 0...1) * 255).rounded())
        }
        let value = byte(color.red) << 24 | byte(color.green) << 16
            | byte(color.blue) << 8 | byte(color.alpha)
        return String(format: "#%08X", value)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
