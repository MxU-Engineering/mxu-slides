import Foundation
import Testing
@testable import PPTXImport

struct PPTXInheritanceChainTests {

    private static let pNS = "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    private static let aNS = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
    private static let rNS = "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
    private static let relsNS = "xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\""
    private static let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private func stageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-chain-\(UUID().uuidString)", isDirectory: true)

        let theme = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme \(Self.aNS) name="Test">
          <a:themeElements>
            <a:clrScheme name="Test">
              <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
              <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
              <a:dk2><a:srgbClr val="1F3864"/></a:dk2>
              <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
              <a:accent1><a:srgbClr val="0000FF"/></a:accent1>
              <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
              <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
              <a:accent4><a:srgbClr val="FFC000"/></a:accent4>
              <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>
              <a:accent6><a:srgbClr val="70AD47"/></a:accent6>
              <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
              <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
            </a:clrScheme>
            <a:fontScheme name="Test">
              <a:majorFont><a:latin typeface="Georgia"/></a:majorFont>
              <a:minorFont><a:latin typeface="Verdana"/></a:minorFont>
            </a:fontScheme>
            <a:fmtScheme name="Test">
              <a:fillStyleLst>
                <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
                <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
                <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
              </a:fillStyleLst>
              <a:lnStyleLst/>
              <a:effectStyleLst/>
              <a:bgFillStyleLst>
                <a:solidFill><a:schemeClr val="phClr"><a:shade val="50000"/></a:schemeClr></a:solidFill>
                <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
                <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
              </a:bgFillStyleLst>
            </a:fmtScheme>
          </a:themeElements>
        </a:theme>
        """

        let master = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster \(Self.pNS) \(Self.aNS) \(Self.rNS)>
          <p:cSld>
            <p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill></p:bgPr></p:bg>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Master Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="100000" y="200000"/><a:ext cx="3000000" cy="600000"/></a:xfrm></p:spPr>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Master Body"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="500000" y="2000000"/><a:ext cx="3000000" cy="1000000"/></a:xfrm></p:spPr>
              </p:sp>
              <p:pic>
                <p:nvPicPr><p:cNvPr id="4" name="Logo"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
                <p:blipFill><a:blip r:embed="rId10"/></p:blipFill>
                <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="457200" cy="457200"/></a:xfrm></p:spPr>
              </p:pic>
            </p:spTree>
          </p:cSld>
          <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
          <p:txStyles>
            <p:titleStyle>
              <a:lvl1pPr algn="ctr"><a:defRPr sz="4400" b="1"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/></a:defRPr></a:lvl1pPr>
            </p:titleStyle>
            <p:bodyStyle>
              <a:lvl1pPr><a:defRPr sz="2800"><a:latin typeface="+mn-lt"/></a:defRPr></a:lvl1pPr>
              <a:lvl2pPr><a:defRPr sz="2400"><a:latin typeface="+mn-lt"/></a:defRPr></a:lvl2pPr>
            </p:bodyStyle>
            <p:otherStyle/>
          </p:txStyles>
        </p:sldMaster>
        """

        let masterRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships \(Self.relsNS)>
          <Relationship Id="rId1" Type="\(Self.relType)/theme" Target="../theme/theme1.xml"/>
          <Relationship Id="rId10" Type="\(Self.relType)/image" Target="../media/logo.png"/>
        </Relationships>
        """

        let layout1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout \(Self.pNS) \(Self.aNS)>
          <p:cSld>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Layout Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="914400" y="304800"/><a:ext cx="10363200" cy="1325563"/></a:xfrm></p:spPr>
                <p:txBody>
                  <a:bodyPr/>
                  <a:lstStyle><a:lvl1pPr><a:defRPr sz="3600"/></a:lvl1pPr></a:lstStyle>
                  <a:p/>
                </p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Layout Body"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="457200" y="1600200"/><a:ext cx="5486400" cy="4525963"/></a:xfrm></p:spPr>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="4" name="Accent Bar"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="0" y="6400800"/><a:ext cx="12192000" cy="457200"/></a:xfrm>
                  <a:solidFill><a:schemeClr val="accent1"/></a:solidFill>
                </p:spPr>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:sldLayout>
        """

        let layout2 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout \(Self.pNS) \(Self.aNS) showMasterSp="0">
          <p:cSld>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Layout2 Deco"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                  <a:solidFill><a:srgbClr val="123456"/></a:solidFill>
                </p:spPr>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:sldLayout>
        """

        let layoutRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships \(Self.relsNS)>
          <Relationship Id="rId1" Type="\(Self.relType)/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """

        let presentation = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation \(Self.pNS) \(Self.aNS)>
          <p:sldSz cx="12192000" cy="6858000"/>
          <p:defaultTextStyle>
            <a:lvl1pPr><a:defRPr sz="1400"/></a:lvl1pPr>
          </p:defaultTextStyle>
        </p:presentation>
        """

        let slide1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld \(Self.pNS) \(Self.aNS)>
          <p:cSld>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="ctrTitle"/></p:nvPr></p:nvSpPr>
                <p:spPr/>
                <p:txBody><a:bodyPr/><a:p><a:r><a:t>Inherited Title</a:t></a:r></a:p></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Body"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
                <p:spPr/>
                <p:txBody>
                  <a:bodyPr/>
                  <a:p><a:r><a:t>Level one</a:t></a:r></a:p>
                  <a:p><a:pPr lvl="1"/><a:r><a:t>Level two</a:t></a:r></a:p>
                </p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="4" name="Sub"/><p:cNvSpPr/><p:nvPr><p:ph type="subTitle"/></p:nvPr></p:nvSpPr>
                <p:spPr/>
                <p:txBody><a:bodyPr/><a:p><a:r><a:t>Sub</a:t></a:r></a:p></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="5" name="Plain Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="914400" y="914400"/><a:ext cx="1828800" cy="914400"/></a:xfrm></p:spPr>
                <p:txBody><a:bodyPr/><a:p><a:r><a:t>Plain</a:t></a:r></a:p></p:txBody>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:sld>
        """

        let slide2 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld \(Self.pNS) \(Self.aNS) showMasterSp="0">
          <p:cSld>
            <p:bg><p:bgRef idx="1001"><a:srgbClr val="FF0000"/></p:bgRef></p:bg>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Own"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                  <a:solidFill><a:srgbClr val="00FF00"/></a:solidFill>
                </p:spPr>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:sld>
        """

        let slide3 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld \(Self.pNS) \(Self.aNS)>
          <p:cSld>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Own3"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                  <a:solidFill><a:srgbClr val="00FF00"/></a:solidFill>
                </p:spPr>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:sld>
        """

        func slideRels(layout: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships \(Self.relsNS)>
              <Relationship Id="rId1" Type="\(Self.relType)/slideLayout" Target="../slideLayouts/\(layout)"/>
            </Relationships>
            """
        }

        let parts: [String: String] = [
            "ppt/presentation.xml": presentation,
            "ppt/theme/theme1.xml": theme,
            "ppt/slideMasters/slideMaster1.xml": master,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": masterRels,
            "ppt/slideLayouts/slideLayout1.xml": layout1,
            "ppt/slideLayouts/slideLayout2.xml": layout2,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": layoutRels,
            "ppt/slideLayouts/_rels/slideLayout2.xml.rels": layoutRels,
            "ppt/slides/slide1.xml": slide1,
            "ppt/slides/slide2.xml": slide2,
            "ppt/slides/slide3.xml": slide3,
            "ppt/slides/_rels/slide1.xml.rels": slideRels(layout: "slideLayout1.xml"),
            "ppt/slides/_rels/slide2.xml.rels": slideRels(layout: "slideLayout1.xml"),
            "ppt/slides/_rels/slide3.xml.rels": slideRels(layout: "slideLayout2.xml"),
            "ppt/media/logo.png": "png-bytes",
        ]
        for (path, contents) in parts {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func parse(_ slidePart: String, root: URL, warnings: inout [String]) throws -> PPTXSlide {
        try PPTXSlideParser.parse(
            partPath: slidePart, presentationPart: "ppt/presentation.xml",
            in: PPTXPackage(root: root), warnings: &warnings)
    }

    @Test func placeholderGeometryAndTextCascadeResolve() throws {
        let root = try stageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var warnings: [String] = []
        let slide = try parse("ppt/slides/slide1.xml", root: root, warnings: &warnings)

        #expect(slide.shapes.count == 6)
        #expect(slide.shapes[0].name == "Logo")
        #expect(slide.shapes[0].kind == .picture)
        #expect(slide.shapes[0].mediaPath == root.appendingPathComponent("ppt/media/logo.png").path)
        #expect(slide.shapes[1].name == "Accent Bar")
        #expect(slide.shapes[1].fill == .solid(colorHex: "0000FFFF"))

        let title = slide.shapes[2]
        #expect(title.transform == PPTXTransform(offXEMU: 914_400, offYEMU: 304_800, extXEMU: 10_363_200, extYEMU: 1_325_563))
        let titleRun = try #require(title.textBody?.paragraphs.first?.runs.first)
        #expect(titleRun.fontFamily == "Georgia")
        #expect(titleRun.sizeHundredthsPt == 3600)
        #expect(titleRun.bold)
        #expect(titleRun.colorHex == "000000FF")
        #expect(title.textBody?.paragraphs.first?.alignment == "ctr")

        let body = slide.shapes[3]
        #expect(body.transform == PPTXTransform(offXEMU: 457_200, offYEMU: 1_600_200, extXEMU: 5_486_400, extYEMU: 4_525_963))
        let levelOne = try #require(body.textBody?.paragraphs[0].runs.first)
        #expect(levelOne.sizeHundredthsPt == 2800)
        #expect(levelOne.fontFamily == "Verdana")
        let levelTwo = try #require(body.textBody?.paragraphs[1].runs.first)
        #expect(levelTwo.sizeHundredthsPt == 2400)

        let sub = slide.shapes[4]
        #expect(sub.transform == PPTXTransform(offXEMU: 500_000, offYEMU: 2_000_000, extXEMU: 3_000_000, extYEMU: 1_000_000))
        #expect(sub.textBody?.paragraphs.first?.runs.first?.sizeHundredthsPt == 2800)

        let plain = slide.shapes[5]
        let plainRun = try #require(plain.textBody?.paragraphs.first?.runs.first)
        #expect(plainRun.sizeHundredthsPt == 1400)
        #expect(plainRun.fontFamily == "Verdana")

        #expect(slide.backgroundFill == .solid(colorHex: "FFFFFFFF"))
        #expect(warnings.isEmpty)
    }

    @Test func bgRefResolvesThemeStyleWithBoundPhClr() throws {
        let root = try stageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var warnings: [String] = []
        let slide = try parse("ppt/slides/slide2.xml", root: root, warnings: &warnings)

        #expect(slide.backgroundFill == .solid(colorHex: "BC0000FF"))
    }

    @Test func slideLevelShowMasterSpZeroHidesAllDecorations() throws {
        let root = try stageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var warnings: [String] = []
        let slide = try parse("ppt/slides/slide2.xml", root: root, warnings: &warnings)
        #expect(slide.shapes.count == 1)
        #expect(slide.shapes[0].name == "Own")
    }

    @Test func layoutLevelShowMasterSpZeroHidesOnlyMasterDecorations() throws {
        let root = try stageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var warnings: [String] = []
        let slide = try parse("ppt/slides/slide3.xml", root: root, warnings: &warnings)
        #expect(slide.shapes.map(\.name) == ["Layout2 Deco", "Own3"])
        #expect(slide.shapes[0].fill == .solid(colorHex: "123456FF"))
    }
}
