import Foundation
import Testing
@testable import PPTXImport

struct PPTXColorResolverTests {

    private let resolver = PPTXColorResolver(
        scheme: ["accent1": "0000FF", "lt1": "FFFFFF", "dk1": "000000"],
        slotMap: ["bg1": "lt1", "tx1": "dk1"])

    private func resolve(_ inner: String, phClr: String? = nil, warnings: inout [String]) throws -> String? {
        let xml = """
        <fill xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(inner)</fill>
        """
        let document = try XMLDocument(data: Data(xml.utf8), options: [])
        return resolver.color(in: document.rootElement(), phClr: phClr, warnings: &warnings)
    }

    @Test func plainSRGBGetsOpaqueAlpha() throws {
        var warnings: [String] = []
        #expect(try resolve("<a:srgbClr val=\"1a2b3c\"/>", warnings: &warnings) == "1A2B3CFF")
        #expect(warnings.isEmpty)
    }

    @Test func schemeSlotResolvesThroughClrMap() throws {
        var warnings: [String] = []

        #expect(try resolve("<a:schemeClr val=\"bg1\"/>", warnings: &warnings) == "FFFFFFFF")
        #expect(try resolve("<a:schemeClr val=\"accent1\"/>", warnings: &warnings) == "0000FFFF")
    }

    @Test func lumModDarkensViaHSL() throws {
        var warnings: [String] = []

        let hex = try resolve("<a:schemeClr val=\"accent1\"><a:lumMod val=\"60000\"/></a:schemeClr>", warnings: &warnings)
        #expect(hex == "000099FF")
    }

    @Test func satModDesaturatesViaHSL() throws {
        var warnings: [String] = []

        let hex = try resolve("<a:schemeClr val=\"accent1\"><a:satMod val=\"50000\"/></a:schemeClr>", warnings: &warnings)
        #expect(hex == "4040BFFF")
    }

    @Test func tintBlendsTowardWhite() throws {
        var warnings: [String] = []

        let hex = try resolve("<a:srgbClr val=\"808080\"><a:tint val=\"50000\"/></a:srgbClr>", warnings: &warnings)
        #expect(hex == "CDCDCDFF")
    }

    @Test func shadeScalesTowardBlack() throws {
        var warnings: [String] = []
        let hex = try resolve("<a:srgbClr val=\"FF0000\"><a:shade val=\"50000\"/></a:srgbClr>", warnings: &warnings)
        #expect(hex == "BC0000FF")
    }

    @Test func alphaLandsInTheAlphaByte() throws {
        var warnings: [String] = []
        let hex = try resolve("<a:srgbClr val=\"FF0000\"><a:alpha val=\"50000\"/></a:srgbClr>", warnings: &warnings)
        #expect(hex == "FF000080")
    }

    @Test func phClrBindsThePlaceholderColor() throws {
        var warnings: [String] = []
        let bound = try resolve("<a:schemeClr val=\"phClr\"/>", phClr: "112233", warnings: &warnings)
        #expect(bound == "112233FF")

        #expect(try resolve("<a:schemeClr val=\"phClr\"/>", warnings: &warnings) == nil)
        #expect(warnings.contains { $0.contains("phClr") })
    }

    @Test func unknownSlotWarnsOnceAndSkips() throws {
        var warnings: [String] = []
        #expect(try resolve("<a:schemeClr val=\"accent9\"/>", warnings: &warnings) == nil)
        #expect(try resolve("<a:schemeClr val=\"accent9\"/>", warnings: &warnings) == nil)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("accent9"))
    }

    @Test func unhandledTransformAppliesNothingAndWarns() throws {
        var warnings: [String] = []
        let hex = try resolve("<a:srgbClr val=\"FF0000\"><a:gamma/></a:srgbClr>", warnings: &warnings)
        #expect(hex == "FF0000FF")
        #expect(warnings.contains { $0.contains("gamma") })
    }

    @Test func presetColorsResolveFromTheStandardTable() throws {
        var warnings: [String] = []
        #expect(try resolve("<a:prstClr val=\"red\"/>", warnings: &warnings) == "FF0000FF")
        #expect(try resolve("<a:prstClr val=\"dkBlue\"/>", warnings: &warnings) == "00008BFF")
        #expect(try resolve("<a:prstClr val=\"ltSteelBlue\"/>", warnings: &warnings) == "B0C4DEFF")
        #expect(try resolve("<a:prstClr val=\"black\"/>", warnings: &warnings) == "000000FF")
        #expect(try resolve("<a:prstClr val=\"white\"/>", warnings: &warnings) == "FFFFFFFF")

        #expect(try resolve("<a:prstClr val=\"darkBlue\"/>", warnings: &warnings) == "00008BFF")
        #expect(try resolve("<a:prstClr val=\"lightGrey\"/>", warnings: &warnings) == "D3D3D3FF")
        #expect(try resolve("<a:prstClr val=\"grey\"/>", warnings: &warnings) == "808080FF")
        #expect(warnings.isEmpty)

        let shaded = try resolve("<a:prstClr val=\"red\"><a:shade val=\"50000\"/></a:prstClr>", warnings: &warnings)
        #expect(shaded == "BC0000FF")

        #expect(try resolve("<a:prstClr val=\"notAColor\"/>", warnings: &warnings) == nil)
        #expect(warnings.contains { $0.contains("notAColor") })
    }

    @Test func sysClrUsesLastRenderedColor() throws {
        var warnings: [String] = []
        let hex = try resolve("<a:sysClr val=\"windowText\" lastClr=\"0A0B0C\"/>", warnings: &warnings)
        #expect(hex == "0A0B0CFF")
    }

    @Test func transformsApplyInDocumentOrder() throws {
        var warnings: [String] = []

        let hex = try resolve(
            "<a:srgbClr val=\"FF0000\"><a:shade val=\"50000\"/><a:tint val=\"50000\"/></a:srgbClr>",
            warnings: &warnings)
        #expect(hex == "E1BCBCFF")
    }
}
