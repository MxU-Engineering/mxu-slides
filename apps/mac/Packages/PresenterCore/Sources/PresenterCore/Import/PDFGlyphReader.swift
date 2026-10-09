import CoreGraphics
import Foundation

public struct PDFGlyph: Equatable, Sendable {

    public var text: String

    public var x: CGFloat
    public var y: CGFloat

    public var width: CGFloat

    public var size: CGFloat
    public var bold: Bool

    public var light: Bool

    public var font: String

    public init(text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, bold: Bool = false, light: Bool = false, font: String = "") {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.size = size
        self.bold = bold
        self.light = light
        self.font = font
    }

    public var maxX: CGFloat { x + width }
}

public struct PDFMark: Equatable, Sendable {

    public var bounds: CGRect

    public var accidental: String?

    public init(bounds: CGRect, accidental: String?) {
        self.bounds = bounds
        self.accidental = accidental
    }
}

public struct PDFPageText: Equatable, Sendable {
    public var glyphs: [PDFGlyph]
    public var marks: [PDFMark]
    public var bounds: CGRect

    public init(glyphs: [PDFGlyph], marks: [PDFMark] = [], bounds: CGRect = .zero) {
        self.glyphs = glyphs
        self.marks = marks
        self.bounds = bounds
    }
}

public enum PDFGlyphReader {

    public static func pages(of document: CGPDFDocument) -> [PDFPageText] {
        guard document.numberOfPages > 0 else { return [] }
        return (1...document.numberOfPages).map { number in
            guard let page = document.page(at: number) else { return PDFPageText(glyphs: []) }
            let state = ScanState()
            let stream = CGPDFContentStreamCreateWithPage(page)
            state.scan(stream)
            return PDFPageText(glyphs: state.glyphs, marks: state.marks, bounds: page.getBoxRect(.mediaBox))
        }
    }

    public static func pages(of data: Data) -> [PDFPageText] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { return [] }
        return pages(of: document)
    }

    static let markLimit: CGFloat = 16

    static func accidental(of path: CGPath) -> String? {
        let bounds = path.boundingBoxOfPath
        guard bounds.height > bounds.width * 1.2 else { return nil }
        let width = 20, height = 30
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.addPath(path)
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath(using: .evenOdd)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        func coverage(rows: Range<Int>, columns: Range<Int>) -> CGFloat {
            var inked = 0
            for row in rows {
                for column in columns where data[row * width + column] > 60 { inked += 1 }
            }
            return CGFloat(inked) / CGFloat(rows.count * columns.count)
        }
        let overall = coverage(rows: 0..<height, columns: 0..<width)
        let stem = coverage(rows: 0..<height, columns: 0..<width / 4)
        let rightOfStemUp = coverage(rows: 0..<height * 35 / 100, columns: width * 3 / 10..<width)
        if overall > 0.8 || overall < 0.12 {
            return nil
        } else if stem > 0.25, rightOfStemUp < 0.04 {
            return "b"
        } else {
            return "#"
        }
    }

    final class Font {
        var name = ""
        var bold = false

        var twoByte = false
        var widths: [Int: CGFloat] = [:]
        var defaultWidth: CGFloat = 1000
        var unicode: [Int: String] = [:]
        var hasUnicodeMap = false

        init(_ dictionary: CGPDFDictionaryRef) {
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            var baseFont: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(dictionary, "BaseFont", &baseFont), let baseFont {
                name = String(cString: baseFont)
            }

            if let plus = name.firstIndex(of: "+") { name = String(name[name.index(after: plus)...]) }
            let lowered = name.lowercased()
            bold = ["bold", "black", "heavy", "semibold", "demi"].contains { lowered.contains($0) }
            if let subtype, String(cString: subtype) == "Type0" {
                twoByte = true
                var descendants: CGPDFArrayRef?
                var descendant: CGPDFDictionaryRef?
                if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
                   CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                    readCIDWidths(descendant)
                }
            } else {
                readSimpleWidths(dictionary)
            }
            var toUnicode: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(dictionary, "ToUnicode", &toUnicode), let toUnicode {
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(toUnicode, &format) as Data? {
                    unicode = Self.parseCMap(String(decoding: data, as: UTF8.self))
                    hasUnicodeMap = true
                }
            }
        }

        private func readCIDWidths(_ descendant: CGPDFDictionaryRef) {
            var dw: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descendant, "DW", &dw) { defaultWidth = dw }
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(descendant, "W", &array), let array else { return }

            var index = 0
            let count = CGPDFArrayGetCount(array)
            while index < count {
                var first: CGPDFInteger = 0
                guard CGPDFArrayGetInteger(array, index, &first) else { break }
                var list: CGPDFArrayRef?
                if CGPDFArrayGetArray(array, index + 1, &list), let list {
                    for offset in 0..<CGPDFArrayGetCount(list) {
                        var width: CGPDFReal = 0
                        if CGPDFArrayGetNumber(list, offset, &width) { widths[first + offset] = width }
                    }
                    index += 2
                } else {
                    var last: CGPDFInteger = 0
                    var width: CGPDFReal = 0
                    if CGPDFArrayGetInteger(array, index + 1, &last), CGPDFArrayGetNumber(array, index + 2, &width), last >= first {
                        for code in first...last { widths[code] = width }
                    }
                    index += 3
                }
            }
        }

        private func readSimpleWidths(_ dictionary: CGPDFDictionaryRef) {
            var firstChar: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dictionary, "FirstChar", &firstChar)
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Widths", &array), let array else { return }
            for offset in 0..<CGPDFArrayGetCount(array) {
                var width: CGPDFReal = 0
                if CGPDFArrayGetNumber(array, offset, &width) { widths[firstChar + offset] = width }
            }
        }

        func width(of code: Int) -> CGFloat { widths[code] ?? defaultWidth }

        func text(of code: Int) -> String {
            if hasUnicodeMap {
                return (unicode[code] ?? "").replacingOccurrences(of: "\0", with: "")
            } else {

                let byte = UInt8(truncatingIfNeeded: code)
                return String(bytes: [byte], encoding: .windowsCP1252) ?? ""
            }
        }

        static func parseCMap(_ text: String) -> [Int: String] {
            var map: [Int: String] = [:]
            func unicodeString(_ hex: Substring) -> String {
                var scalars: [UInt16] = []
                var index = hex.startIndex
                while hex.distance(from: index, to: hex.endIndex) >= 4 {
                    let next = hex.index(index, offsetBy: 4)
                    scalars.append(UInt16(hex[index..<next], radix: 16) ?? 0)
                    index = next
                }
                return String(decoding: scalars, as: UTF16.self)
            }
            for block in text.components(separatedBy: "beginbf").dropFirst() {
                let isRange = block.hasPrefix("range")
                let body = block.components(separatedBy: "endbf").first ?? ""
                let tokens = Self.cmapTokens(body)
                var index = 0
                if isRange {
                    while index + 2 < tokens.count {
                        guard case .hex(let low) = tokens[index], case .hex(let high) = tokens[index + 1],
                              let start = Int(low, radix: 16), let end = Int(high, radix: 16), end >= start
                        else { index += 1; continue }
                        switch tokens[index + 2] {
                        case .hex(let destination):
                            let base = Array(unicodeString(destination).utf16)
                            for code in start...end where !base.isEmpty {
                                var shifted = base
                                shifted[shifted.count - 1] &+= UInt16(code - start)
                                map[code] = String(decoding: shifted, as: UTF16.self)
                            }
                        case .array(let list):
                            for (offset, destination) in list.enumerated() where start + offset <= end {
                                map[start + offset] = unicodeString(destination)
                            }
                        }
                        index += 3
                    }
                } else {
                    while index + 1 < tokens.count {
                        if case .hex(let source) = tokens[index], case .hex(let destination) = tokens[index + 1],
                           let code = Int(source, radix: 16) {
                            map[code] = unicodeString(destination)
                        }
                        index += 2
                    }
                }
            }
            return map
        }

        enum CMapToken { case hex(Substring), array([Substring]) }

        static func cmapTokens(_ body: String) -> [CMapToken] {
            var tokens: [CMapToken] = []
            var list: [Substring]?
            var index = body.startIndex
            while index < body.endIndex {
                let character = body[index]
                if character == "<", let close = body[index...].firstIndex(of: ">") {
                    let hex = body[body.index(after: index)..<close]
                    if list != nil { list?.append(hex) } else { tokens.append(.hex(hex)) }
                    index = body.index(after: close)
                } else if character == "[" {
                    list = []
                    index = body.index(after: index)
                } else if character == "]" {
                    tokens.append(.array(list ?? []))
                    list = nil
                    index = body.index(after: index)
                } else {
                    index = body.index(after: index)
                }
            }
            return tokens
        }
    }

    struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var fillLuminance: CGFloat = 0

        var fillComponents = 1
    }

    final class ScanState {
        var glyphs: [PDFGlyph] = []
        var graphics = GraphicsState()
        var stack: [GraphicsState] = []
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var font: Font?
        var fontSize: CGFloat = 0
        var charSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var leading: CGFloat = 0
        var rise: CGFloat = 0
        var fonts: [String: Font] = [:]
        var marks: [PDFMark] = []
        var path = CGMutablePath()

        var contentStreams: [CGPDFContentStreamRef] = []

        func scan(_ stream: CGPDFContentStreamRef) {
            contentStreams.append(stream)
            let table = Self.makeOperatorTable()
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFOperatorTableRelease(table)
            contentStreams.removeLast()
        }

        static func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
            Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
        }

        func resolveFont(_ name: String) -> Font? {
            guard let stream = contentStreams.last else { return nil }
            let key = "\(UInt(bitPattern: stream))/\(name)"
            if let cached = fonts[key] { return cached }
            guard let object = CGPDFContentStreamGetResource(stream, "Font", name) else { return nil }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return nil }
            let font = Font(dictionary)
            fonts[key] = font
            return font
        }

        func show(_ string: CGPDFStringRef) {
            guard let font, let bytes = CGPDFStringGetBytePtr(string) else { return }
            let length = CGPDFStringGetLength(string)
            var index = 0
            while index < length {
                var code = Int(bytes[index])
                if font.twoByte, index + 1 < length {
                    code = code << 8 | Int(bytes[index + 1])
                    index += 2
                } else {
                    index += 1
                }
                let advance = font.width(of: code) / 1000 * fontSize
                let render = CGAffineTransform(a: fontSize * horizontalScale, b: 0, c: 0, d: fontSize, tx: 0, ty: rise)
                    .concatenating(textMatrix).concatenating(graphics.ctm)
                let origin = CGPoint.zero.applying(render)
                let extra = (!font.twoByte && code == 32) ? wordSpacing : 0
                let tx = (advance + charSpacing + extra) * horizontalScale
                let end = CGPoint(x: tx, y: 0).applying(textMatrix.concatenating(graphics.ctm))
                let start = CGPoint.zero.applying(textMatrix.concatenating(graphics.ctm))
                glyphs.append(PDFGlyph(
                    text: font.text(of: code),
                    x: origin.x, y: origin.y,
                    width: hypot(end.x - start.x, end.y - start.y),
                    size: hypot(render.c, render.d),
                    bold: font.bold,
                    light: graphics.fillLuminance > 0.35,
                    font: font.name
                ))
                textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(textMatrix)
            }
        }

        func nextLine(tx: CGFloat, ty: CGFloat) {
            lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
            textMatrix = lineMatrix
        }

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x, y: y).applying(graphics.ctm)
        }

        func fillPath() {
            let bounds = path.boundingBoxOfPath
            if !path.isEmpty, graphics.fillLuminance < 0.35,
               bounds.width < PDFGlyphReader.markLimit, bounds.height < PDFGlyphReader.markLimit,
               bounds.width > 0.5, bounds.height > 0.5 {
                marks.append(PDFMark(bounds: bounds, accidental: PDFGlyphReader.accidental(of: path)))
            }
            endPath()
        }

        func endPath() {
            path = CGMutablePath()
        }

        func components(ofColorSpace name: String) -> Int {
            switch name {
            case "DeviceGray", "CalGray", "G": return 1
            case "DeviceRGB", "CalRGB", "RGB", "Lab": return 3
            case "DeviceCMYK", "CMYK": return 4
            case "Pattern": return 0
            default:
                guard let stream = contentStreams.last,
                      let object = CGPDFContentStreamGetResource(stream, "ColorSpace", name)
                else { return 1 }
                var named: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(object, .name, &named), let named {
                    return components(ofColorSpace: String(cString: named))
                }
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &array), let array else { return 1 }
                var family: UnsafePointer<CChar>?
                guard CGPDFArrayGetName(array, 0, &family), let family else { return 1 }
                switch String(cString: family) {
                case "ICCBased":
                    var profile: CGPDFStreamRef?
                    var count: CGPDFInteger = 1
                    if CGPDFArrayGetStream(array, 1, &profile), let profile, let dictionary = CGPDFStreamGetDictionary(profile) {
                        CGPDFDictionaryGetInteger(dictionary, "N", &count)
                    }
                    return count
                case "CalRGB", "Lab": return 3
                case "Pattern": return 0
                default: return 1
                }
            }
        }

        func setFill(_ components: [CGFloat]) {
            switch components.count {
            case 1: graphics.fillLuminance = components[0]
            case 3: graphics.fillLuminance = 0.299 * components[0] + 0.587 * components[1] + 0.114 * components[2]
            case 4: graphics.fillLuminance = (1 - components[3]) * (1 - (components[0] + components[1] + components[2]) / 3)
            default: break
            }
        }

        static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
            var values = [CGFloat](repeating: 0, count: count)
            for index in stride(from: count - 1, through: 0, by: -1) {
                var value: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
                values[index] = value
            }
            return values
        }

        static func makeOperatorTable() -> CGPDFOperatorTableRef {
            let table = CGPDFOperatorTableCreate()!
            CGPDFOperatorTableSetCallback(table, "q") { _, info in
                let state = ScanState.state(info)
                state.stack.append(state.graphics)
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in
                let state = ScanState.state(info)
                if let last = state.stack.popLast() { state.graphics = last }
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                let state = ScanState.state(info)
                guard let m = ScanState.numbers(scanner, 6) else { return }
                state.graphics.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
                    .concatenating(state.graphics.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "BT") { _, info in
                let state = ScanState.state(info)
                state.textMatrix = .identity
                state.lineMatrix = .identity
            }
            CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
                let state = ScanState.state(info)
                var size: CGPDFReal = 0
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
                state.fontSize = size
                state.font = state.resolveFont(String(cString: name))
            }
            CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
                if let value = ScanState.numbers(scanner, 1) { ScanState.state(info).charSpacing = value[0] }
            }
            CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in
                if let value = ScanState.numbers(scanner, 1) { ScanState.state(info).wordSpacing = value[0] }
            }
            CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
                if let value = ScanState.numbers(scanner, 1) { ScanState.state(info).horizontalScale = value[0] / 100 }
            }
            CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
                if let value = ScanState.numbers(scanner, 1) { ScanState.state(info).leading = value[0] }
            }
            CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in
                if let value = ScanState.numbers(scanner, 1) { ScanState.state(info).rise = value[0] }
            }
            CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
                let state = ScanState.state(info)
                guard let m = ScanState.numbers(scanner, 6) else { return }
                state.lineMatrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
                state.textMatrix = state.lineMatrix
            }
            CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
                guard let t = ScanState.numbers(scanner, 2) else { return }
                ScanState.state(info).nextLine(tx: t[0], ty: t[1])
            }
            CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
                let state = ScanState.state(info)
                guard let t = ScanState.numbers(scanner, 2) else { return }
                state.leading = -t[1]
                state.nextLine(tx: t[0], ty: t[1])
            }
            CGPDFOperatorTableSetCallback(table, "T*") { _, info in
                let state = ScanState.state(info)
                state.nextLine(tx: 0, ty: -state.leading)
            }
            CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
                var string: CGPDFStringRef?
                if CGPDFScannerPopString(scanner, &string), let string { ScanState.state(info).show(string) }
            }
            CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
                let state = ScanState.state(info)
                var string: CGPDFStringRef?
                guard CGPDFScannerPopString(scanner, &string), let string else { return }
                state.nextLine(tx: 0, ty: -state.leading)
                state.show(string)
            }
            CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
                let state = ScanState.state(info)
                var string: CGPDFStringRef?
                guard CGPDFScannerPopString(scanner, &string), let string, let spacing = ScanState.numbers(scanner, 2) else { return }
                state.wordSpacing = spacing[0]
                state.charSpacing = spacing[1]
                state.nextLine(tx: 0, ty: -state.leading)
                state.show(string)
            }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                let state = ScanState.state(info)
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &array), let array else { return }
                for index in 0..<CGPDFArrayGetCount(array) {
                    var string: CGPDFStringRef?
                    var adjustment: CGPDFReal = 0
                    if CGPDFArrayGetString(array, index, &string), let string {
                        state.show(string)
                    } else if CGPDFArrayGetNumber(array, index, &adjustment) {
                        let tx = -adjustment / 1000 * state.fontSize * state.horizontalScale
                        state.textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(state.textMatrix)
                    }
                }
            }
            CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
                ScanState.state(info).graphics.fillComponents = 1
                if let value = ScanState.numbers(scanner, 1) { ScanState.state(info).setFill(value) }
            }
            CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
                ScanState.state(info).graphics.fillComponents = 3
                if let value = ScanState.numbers(scanner, 3) { ScanState.state(info).setFill(value) }
            }
            CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
                ScanState.state(info).graphics.fillComponents = 4
                if let value = ScanState.numbers(scanner, 4) { ScanState.state(info).setFill(value) }
            }
            CGPDFOperatorTableSetCallback(table, "cs") { scanner, info in
                let state = ScanState.state(info)
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name else { return }
                state.graphics.fillComponents = state.components(ofColorSpace: String(cString: name))
                state.setFill([0])
            }

            CGPDFOperatorTableSetCallback(table, "sc") { scanner, info in
                let state = ScanState.state(info)
                if let value = ScanState.numbers(scanner, state.graphics.fillComponents) { state.setFill(value) }
            }
            CGPDFOperatorTableSetCallback(table, "scn") { scanner, info in
                let state = ScanState.state(info)
                if let value = ScanState.numbers(scanner, state.graphics.fillComponents) { state.setFill(value) }
            }
            CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
                let state = ScanState.state(info)
                guard let p = ScanState.numbers(scanner, 2) else { return }
                state.path.move(to: state.point(p[0], p[1]))
            }
            CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
                let state = ScanState.state(info)
                guard let p = ScanState.numbers(scanner, 2), !state.path.isEmpty else { return }
                state.path.addLine(to: state.point(p[0], p[1]))
            }
            CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
                let state = ScanState.state(info)
                guard let p = ScanState.numbers(scanner, 6), !state.path.isEmpty else { return }
                state.path.addCurve(
                    to: state.point(p[4], p[5]),
                    control1: state.point(p[0], p[1]), control2: state.point(p[2], p[3]))
            }
            CGPDFOperatorTableSetCallback(table, "v") { scanner, info in
                let state = ScanState.state(info)
                guard let p = ScanState.numbers(scanner, 4), !state.path.isEmpty else { return }
                state.path.addQuadCurve(to: state.point(p[2], p[3]), control: state.point(p[0], p[1]))
            }
            CGPDFOperatorTableSetCallback(table, "y") { scanner, info in
                let state = ScanState.state(info)
                guard let p = ScanState.numbers(scanner, 4), !state.path.isEmpty else { return }
                state.path.addQuadCurve(to: state.point(p[2], p[3]), control: state.point(p[0], p[1]))
            }
            CGPDFOperatorTableSetCallback(table, "h") { _, info in
                let state = ScanState.state(info)
                if !state.path.isEmpty { state.path.closeSubpath() }
            }
            CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
                let state = ScanState.state(info)
                guard let r = ScanState.numbers(scanner, 4) else { return }
                let corners = [(r[0], r[1]), (r[0] + r[2], r[1]), (r[0] + r[2], r[1] + r[3]), (r[0], r[1] + r[3])]
                state.path.move(to: state.point(corners[0].0, corners[0].1))
                for corner in corners.dropFirst() { state.path.addLine(to: state.point(corner.0, corner.1)) }
                state.path.closeSubpath()
            }
            for fill in ["f", "F", "f*", "B", "B*", "b", "b*"] {
                CGPDFOperatorTableSetCallback(table, fill) { _, info in ScanState.state(info).fillPath() }
            }
            for other in ["S", "s", "n"] {
                CGPDFOperatorTableSetCallback(table, other) { _, info in ScanState.state(info).endPath() }
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                let state = ScanState.state(info)
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name, let parent = state.contentStreams.last,
                      let object = CGPDFContentStreamGetResource(parent, "XObject", name)
                else { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream)
                else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                      String(cString: subtype) == "Form"
                else { return }
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                let saved = state.graphics
                var matrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var m = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { CGPDFArrayGetNumber(matrix, index, &m[index]) }
                    state.graphics.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
                        .concatenating(state.graphics.ctm)
                }
                let form = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
                state.scan(form)
                state.graphics = saved
            }
            return table
        }
    }
}
