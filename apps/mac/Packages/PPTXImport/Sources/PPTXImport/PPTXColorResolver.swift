import Foundation

struct PPTXColorResolver {

    var scheme: [String: String] = [:]

    var slotMap: [String: String] = [:]

    func color(in parent: XMLElement?, phClr: String? = nil, warnings: inout [String]) -> String? {
        guard let parent else { return nil }
        for child in (parent.children ?? []).compactMap({ $0 as? XMLElement }) {
            switch child.localName {
            case "srgbClr":
                guard let hex = child.attr("val") else { return nil }
                return applyingTransforms(of: child, to: hex, warnings: &warnings)
            case "schemeClr":
                guard let slot = child.attr("val") else { return nil }
                let base = slot == "phClr" ? phClr : scheme[slotMap[slot] ?? slot]
                guard let base else {
                    appendUnique("theme color \"\(slot)\" could not be resolved — that ink was skipped", &warnings)
                    return nil
                }
                return applyingTransforms(of: child, to: base, warnings: &warnings)
            case "sysClr":

                guard let hex = child.attr("lastClr") else { return nil }
                return applyingTransforms(of: child, to: hex, warnings: &warnings)
            case "prstClr":
                guard let name = child.attr("val"), let hex = Self.presetColor(named: name) else {
                    appendUnique("preset color \"\(child.attr("val") ?? "?")\" is not recognized — that ink was skipped", &warnings)
                    return nil
                }
                return applyingTransforms(of: child, to: hex, warnings: &warnings)
            case "hslClr", "scrgbClr":
                appendUnique("\(child.localName ?? "an exotic") color values are not supported yet", &warnings)
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private func applyingTransforms(of colorElement: XMLElement, to hex: String, warnings: inout [String]) -> String? {
        guard var rgb = Self.channels(of: hex) else { return nil }
        var alpha = 255.0
        for transform in (colorElement.children ?? []).compactMap({ $0 as? XMLElement }) {
            let value = transform.doubleAttr("val").map { $0 / 100_000 }
            switch transform.localName {
            case "alpha":
                if let value { alpha = 255 * value }
            case "tint":

                if let value { rgb = Self.inLinear(rgb) { $0 * value + (1 - value) } }
            case "shade":
                if let value { rgb = Self.inLinear(rgb) { $0 * value } }
            case "lumMod":
                if let value { rgb = Self.adjustingHSL(rgb) { $0.l *= value } }
            case "lumOff":
                if let value { rgb = Self.adjustingHSL(rgb) { $0.l += value } }
            case "satMod":
                if let value { rgb = Self.adjustingHSL(rgb) { $0.s *= value } }
            case .some(let name):
                appendUnique("color transform \"\(name)\" is not applied", &warnings)
            case nil:
                break
            }
        }
        let bytes = (rgb + [alpha]).map { UInt8(min(max($0.rounded(), 0), 255)) }
        return String(format: "%02X%02X%02X%02X", bytes[0], bytes[1], bytes[2], bytes[3])
    }

    private static func inLinear(_ rgb: [Double], _ change: (Double) -> Double) -> [Double] {
        rgb.map { channel in
            let c = channel / 255
            let linear = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            let changed = min(max(change(linear), 0), 1)
            let encoded = changed <= 0.0031308 ? changed * 12.92 : 1.055 * pow(changed, 1 / 2.4) - 0.055
            return encoded * 255
        }
    }

    private struct HSL {
        var h: Double
        var s: Double
        var l: Double
    }

    private static func adjustingHSL(_ rgb: [Double], _ change: (inout HSL) -> Void) -> [Double] {
        var hsl = toHSL(rgb)
        change(&hsl)
        hsl.l = min(max(hsl.l, 0), 1)
        hsl.s = min(max(hsl.s, 0), 1)
        return toRGB(hsl)
    }

    private static func toHSL(_ rgb: [Double]) -> HSL {
        let r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return HSL(h: 0, s: 0, l: l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        return HSL(h: h / 6, s: s, l: l)
    }

    private static func toRGB(_ hsl: HSL) -> [Double] {
        guard hsl.s != 0 else { return [hsl.l * 255, hsl.l * 255, hsl.l * 255] }
        let q = hsl.l < 0.5 ? hsl.l * (1 + hsl.s) : hsl.l + hsl.s - hsl.l * hsl.s
        let p = 2 * hsl.l - q
        func channel(_ offset: Double) -> Double {
            var t = hsl.h + offset
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return [channel(1 / 3) * 255, channel(0) * 255, channel(-1 / 3) * 255]
    }

    private static func channels(of hex: String) -> [Double]? {
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)]
    }

    static func presetColor(named name: String) -> String? {
        if let hex = presetColors[name] { return hex }
        var normalized = name
        for (long, short) in [("dark", "dk"), ("light", "lt"), ("medium", "med")] where normalized.hasPrefix(long) {
            normalized = short + normalized.dropFirst(long.count)
        }
        normalized = normalized.replacingOccurrences(of: "Grey", with: "Gray")
        if normalized.hasPrefix("grey") { normalized = "gray" + normalized.dropFirst(4) }
        return presetColors[normalized]
    }

    private static let presetColors: [String: String] = [
        "aliceBlue": "F0F8FF", "antiqueWhite": "FAEBD7", "aqua": "00FFFF",
        "aquamarine": "7FFFD4", "azure": "F0FFFF", "beige": "F5F5DC",
        "bisque": "FFE4C4", "black": "000000", "blanchedAlmond": "FFEBCD",
        "blue": "0000FF", "blueViolet": "8A2BE2", "brown": "A52A2A",
        "burlyWood": "DEB887", "cadetBlue": "5F9EA0", "chartreuse": "7FFF00",
        "chocolate": "D2691E", "coral": "FF7F50", "cornflowerBlue": "6495ED",
        "cornsilk": "FFF8DC", "crimson": "DC143C", "cyan": "00FFFF",
        "deepPink": "FF1493", "deepSkyBlue": "00BFFF", "dimGray": "696969",
        "dkBlue": "00008B", "dkCyan": "008B8B", "dkGoldenrod": "B8860B",
        "dkGray": "A9A9A9", "dkGreen": "006400", "dkKhaki": "BDB76B",
        "dkMagenta": "8B008B", "dkOliveGreen": "556B2F", "dkOrange": "FF8C00",
        "dkOrchid": "9932CC", "dkRed": "8B0000", "dkSalmon": "E9967A",
        "dkSeaGreen": "8FBC8F", "dkSlateBlue": "483D8B", "dkSlateGray": "2F4F4F",
        "dkTurquoise": "00CED1", "dkViolet": "9400D3", "dodgerBlue": "1E90FF",
        "firebrick": "B22222", "floralWhite": "FFFAF0", "forestGreen": "228B22",
        "fuchsia": "FF00FF", "gainsboro": "DCDCDC", "ghostWhite": "F8F8FF",
        "gold": "FFD700", "goldenrod": "DAA520", "gray": "808080",
        "green": "008000", "greenYellow": "ADFF2F", "honeydew": "F0FFF0",
        "hotPink": "FF69B4", "indianRed": "CD5C5C", "indigo": "4B0082",
        "ivory": "FFFFF0", "khaki": "F0E68C", "lavender": "E6E6FA",
        "lavenderBlush": "FFF0F5", "lawnGreen": "7CFC00", "lemonChiffon": "FFFACD",
        "lime": "00FF00", "limeGreen": "32CD32", "linen": "FAF0E6",
        "ltBlue": "ADD8E6", "ltCoral": "F08080", "ltCyan": "E0FFFF",
        "ltGoldenrodYellow": "FAFAD2", "ltGray": "D3D3D3", "ltGreen": "90EE90",
        "ltPink": "FFB6C1", "ltSalmon": "FFA07A", "ltSeaGreen": "20B2AA",
        "ltSkyBlue": "87CEFA", "ltSlateGray": "778899", "ltSteelBlue": "B0C4DE",
        "ltYellow": "FFFFE0", "magenta": "FF00FF", "maroon": "800000",
        "medAquamarine": "66CDAA", "medBlue": "0000CD", "medOrchid": "BA55D3",
        "medPurple": "9370DB", "medSeaGreen": "3CB371", "medSlateBlue": "7B68EE",
        "medSpringGreen": "00FA9A", "medTurquoise": "48D1CC", "medVioletRed": "C71585",
        "midnightBlue": "191970", "mintCream": "F5FFFA", "mistyRose": "FFE4E1",
        "moccasin": "FFE4B5", "navajoWhite": "FFDEAD", "navy": "000080",
        "oldLace": "FDF5E6", "olive": "808000", "oliveDrab": "6B8E23",
        "orange": "FFA500", "orangeRed": "FF4500", "orchid": "DA70D6",
        "paleGoldenrod": "EEE8AA", "paleGreen": "98FB98", "paleTurquoise": "AFEEEE",
        "paleVioletRed": "DB7093", "papayaWhip": "FFEFD5", "peachPuff": "FFDAB9",
        "peru": "CD853F", "pink": "FFC0CB", "plum": "DDA0DD",
        "powderBlue": "B0E0E6", "purple": "800080", "red": "FF0000",
        "rosyBrown": "BC8F8F", "royalBlue": "4169E1", "saddleBrown": "8B4513",
        "salmon": "FA8072", "sandyBrown": "F4A460", "seaGreen": "2E8B57",
        "seaShell": "FFF5EE", "sienna": "A0522D", "silver": "C0C0C0",
        "skyBlue": "87CEEB", "slateBlue": "6A5ACD", "slateGray": "708090",
        "snow": "FFFAFA", "springGreen": "00FF7F", "steelBlue": "4682B4",
        "tan": "D2B48C", "teal": "008080", "thistle": "D8BFD8",
        "tomato": "FF6347", "turquoise": "40E0D0", "violet": "EE82EE",
        "wheat": "F5DEB3", "white": "FFFFFF", "whiteSmoke": "F5F5F5",
        "yellow": "FFFF00", "yellowGreen": "9ACD32",
    ]
}
