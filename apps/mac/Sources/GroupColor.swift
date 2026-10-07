import PresenterCore
import SlideScene
import SwiftUI

enum GroupColor {

    static func fill(_ section: PresentationSection?, palette: [String: String]) -> Color? {
        guard let hex = section?.resolvedColorHex(paletteColors: palette) else { return nil }
        return color(hex)
    }

    static func color(_ hex: String) -> Color? {
        guard let c = ColorHex.color(hex), c.alpha > 0.01 else { return nil }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    static func text(onHex hex: String?) -> Color {
        guard let hex, let c = ColorHex.color(hex) else { return .white }
        let luminance = 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        return luminance > 0.6 ? Color(.sRGB, white: 0.1, opacity: 1) : .white
    }
}
