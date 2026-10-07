import Foundation
import Testing
@testable import PPTXImport

struct PPTXSlideParserTests {

    private func stageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-parser-\(UUID().uuidString)", isDirectory: true)

        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <p:cSld>
            <p:bg><p:bgPr><a:solidFill><a:srgbClr val="101010"/></a:solidFill></p:bgPr></p:bg>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Title Box"/><p:cNvSpPr/><p:nvPr><p:ph type="title" idx="4"/></p:nvPr></p:nvSpPr>
                <p:spPr>
                  <a:xfrm rot="5400000" flipH="1"><a:off x="914400" y="457200"/><a:ext cx="1828800" cy="914400"/></a:xfrm>
                  <a:prstGeom prst="roundRect"><a:avLst><a:gd name="adj" fmla="val 25000"/></a:avLst></a:prstGeom>
                  <a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>
                  <a:ln w="25400"><a:solidFill><a:srgbClr val="00FF00"/></a:solidFill></a:ln>
                </p:spPr>
                <p:txBody>
                  <a:bodyPr anchor="ctr" tIns="91440"><a:normAutofit fontScale="62500"/></a:bodyPr>
                  <a:p>
                    <a:pPr algn="ctr"/>
                    <a:r>
                      <a:rPr lang="en-US" sz="4000" b="1" u="sng" spc="200">
                        <a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill>
                        <a:latin typeface="Helvetica"/>
                      </a:rPr>
                      <a:t>Hello</a:t>
                    </a:r>
                    <a:br/>
                    <a:r><a:rPr sz="2000" strike="sngStrike"/><a:t>World</a:t></a:r>
                  </a:p>
                </p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="4" name="Floating"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr/>
                <p:txBody><a:bodyPr/><a:p><a:r><a:t>No frame</a:t></a:r></a:p></p:txBody>
              </p:sp>
              <p:pic>
                <p:nvPicPr><p:cNvPr id="3" name="Picture 1"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
                <p:blipFill>
                  <a:blip r:embed="rId2"/>
                  <a:srcRect l="25000" r="25000"/>
                  <a:stretch><a:fillRect/></a:stretch>
                </p:blipFill>
                <p:spPr>
                  <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                  <a:prstGeom prst="rect"/>
                </p:spPr>
              </p:pic>
              <p:graphicFrame>
                <p:nvGraphicFramePr><p:cNvPr id="7" name="Chart 1"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
                <p:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></p:xfrm>
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">
                  <c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="rId9"/>
                </a:graphicData></a:graphic>
              </p:graphicFrame>
            </p:spTree>
          </p:cSld>
          <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">
            <mc:Choice xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" Requires="p14">
              <p:transition p14:dur="700" advTm="3000"><p:push dir="l"/></p:transition>
            </mc:Choice>
            <mc:Fallback>
              <p:transition spd="fast" advTm="3000"><p:push dir="l"/></p:transition>
            </mc:Fallback>
          </mc:AlternateContent>
          <p:timing>
            <p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>
              <p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>
                <p:par><p:cTn id="3" fill="hold"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst><p:childTnLst>
                  <p:par><p:cTn id="4" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>
                    <p:par><p:cTn id="5" presetID="2" presetClass="entr" presetSubtype="8" fill="hold" nodeType="clickEffect">
                      <p:stCondLst><p:cond delay="0"/></p:stCondLst>
                      <p:childTnLst>
                        <p:set><p:cBhvr><p:cTn id="6" dur="1" fill="hold"/><p:tgtEl><p:spTgt spid="2"><p:txEl><p:pRg st="0" end="0"/></p:txEl></p:spTgt></p:tgtEl></p:cBhvr></p:set>
                        <p:anim calcmode="lin" valueType="num"><p:cBhvr><p:cTn id="7" dur="750" fill="hold"/><p:tgtEl><p:spTgt spid="2"><p:txEl><p:pRg st="0" end="0"/></p:txEl></p:spTgt></p:tgtEl></p:cBhvr></p:anim>
                      </p:childTnLst>
                    </p:cTn></p:par>
                    <p:par><p:cTn id="8" presetID="10" presetClass="entr" fill="hold" nodeType="withEffect">
                      <p:stCondLst><p:cond delay="250"/></p:stCondLst>
                      <p:childTnLst>
                        <p:set><p:cBhvr><p:cTn id="9" dur="1" fill="hold"/><p:tgtEl><p:spTgt spid="3"/></p:tgtEl></p:cBhvr></p:set>
                        <p:animEffect transition="in" filter="fade"><p:cBhvr><p:cTn id="10" dur="500"/><p:tgtEl><p:spTgt spid="3"/></p:tgtEl></p:cBhvr></p:animEffect>
                      </p:childTnLst>
                    </p:cTn></p:par>
                  </p:childTnLst></p:cTn></p:par>
                </p:childTnLst></p:cTn></p:par>
              </p:childTnLst></p:cTn></p:seq>
            </p:childTnLst></p:cTn></p:par></p:tnLst>
          </p:timing>
        </p:sld>
        """

        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide1.xml"/>
        </Relationships>
        """

        let notesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Notes Placeholder"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
                <p:spPr/>
                <p:txBody><a:bodyPr/><a:p><a:r><a:t>Speaker note</a:t></a:r></a:p></p:txBody>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:notes>
        """

        for (path, contents) in [
            ("ppt/slides/slide1.xml", slideXML),
            ("ppt/slides/_rels/slide1.xml.rels", relsXML),
            ("ppt/notesSlides/notesSlide1.xml", notesXML),
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test func parsesShapesPicturesTextAndTransition() throws {
        let root = try stageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = PPTXPackage(root: root)
        var warnings: [String] = []
        let slide = try PPTXSlideParser.parse(partPath: "ppt/slides/slide1.xml", in: package, warnings: &warnings)

        #expect(slide.backgroundFill == .solid(colorHex: "101010FF"))
        #expect(slide.shapes.count == 2)

        let shape = slide.shapes[0]
        #expect(shape.kind == .shape)
        #expect(shape.name == "Title Box")
        #expect(shape.transform == PPTXTransform(
            offXEMU: 914_400, offYEMU: 457_200, extXEMU: 1_828_800, extYEMU: 914_400,
            rotation60k: 5_400_000, flipH: true, flipV: false))
        #expect(shape.presetGeometry == "roundRect")
        #expect(shape.roundRectAdjustment == 25_000)
        #expect(shape.fill == .solid(colorHex: "FF0000FF"))
        #expect(shape.stroke == PPTXStroke(colorHex: "00FF00FF", widthEMU: 25_400))
        #expect(shape.placeholderType == "title")
        #expect(shape.placeholderIndex == 4)

        let body = try #require(shape.textBody)
        #expect(body.anchor == "ctr")
        #expect(body.topInsetEMU == 91_440)
        #expect(body.leftInsetEMU == nil)
        #expect(body.hasNormAutofit)
        #expect(body.autofitFontScale == 62_500)
        #expect(body.paragraphs.count == 1)
        #expect(body.paragraphs[0].alignment == "ctr")
        let runs = body.paragraphs[0].runs
        #expect(runs.count == 3)
        #expect(runs[0] == PPTXRun(
            text: "Hello", fontFamily: "Helvetica", sizeHundredthsPt: 4000, bold: true,
            underline: true, colorHex: "FFFFFFFF", trackingHundredthsPt: 200))
        #expect(runs[1].isBreak)
        #expect(runs[2] == PPTXRun(text: "World", sizeHundredthsPt: 2000, strike: true))
        #expect(body.plainText == "Hello\nWorld")

        let picture = slide.shapes[1]
        #expect(picture.kind == .picture)
        #expect(picture.name == "Picture 1")
        #expect(picture.mediaRelationshipID == "rId2")
        #expect(picture.mediaPath == root.appendingPathComponent("ppt/media/image1.png").path)
        #expect(picture.sourceRect == PPTXSourceRect(l: 25_000, t: 0, r: 25_000, b: 0))

        let transition = try #require(slide.transition)
        #expect(transition.kind == "push")
        #expect(transition.durationSeconds == 0.7)
        #expect(transition.advanceAfterMs == 3000)

        #expect(slide.notes == "Speaker note")

        #expect(shape.shapeID == 2 && picture.shapeID == 3)
        #expect(slide.animationSteps.count == 2)
        #expect(slide.animationSteps[0] == PPTXAnimation(
            shapeID: 2, presetClass: "entr", presetID: 2, presetSubtype: 8, nodeType: "clickEffect",
            delayMs: 0, durationMs: 750, paragraphStart: 0, paragraphEnd: 0))
        #expect(slide.animationSteps[1] == PPTXAnimation(
            shapeID: 3, presetClass: "entr", presetID: 10, presetSubtype: nil, nodeType: "withEffect",
            delayMs: 250, durationMs: 500, paragraphStart: nil, paragraphEnd: nil))

        #expect(warnings.contains { $0.contains("Floating") && $0.contains("dropped") })
        #expect(warnings.contains { $0.contains("chart \"Chart 1\" was skipped") })
    }

    @Test func parsesLinearGradientAndApproximatesRadial() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-gradient-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld>
            <p:spTree>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Linear"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                  <a:gradFill>
                    <a:gsLst>
                      <a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs>
                      <a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs>
                    </a:gsLst>
                    <a:lin ang="2700000" scaled="1"/>
                  </a:gradFill>
                </p:spPr>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Radial"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                  <a:gradFill>
                    <a:gsLst>
                      <a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs>
                      <a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs>
                    </a:gsLst>
                    <a:path path="circle"><a:fillToRect l="50000" t="50000" r="50000" b="50000"/></a:path>
                  </a:gradFill>
                </p:spPr>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:sld>
        """
        let url = root.appendingPathComponent("ppt/slides/slide1.xml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(slideXML.utf8).write(to: url)

        var warnings: [String] = []
        let slide = try PPTXSlideParser.parse(
            partPath: "ppt/slides/slide1.xml", in: PPTXPackage(root: root), warnings: &warnings)

        let expectedStops = [
            PPTXGradientStop(position: 0, colorHex: "FF0000FF"),
            PPTXGradientStop(position: 100_000, colorHex: "0000FFFF"),
        ]
        #expect(slide.shapes[0].fill == .gradient(PPTXGradient(angle60k: 2_700_000, stops: expectedStops)))
        #expect(slide.shapes[1].fill == .gradient(PPTXGradient(angle60k: nil, stops: expectedStops)))
        #expect(warnings.contains("radial gradient approximated as linear"))
    }

    private func parseStagedSlide(
        _ slideXML: String, extras: [String: String] = [:], warnings: inout [String]
    ) throws -> PPTXSlide {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-staged-\(UUID().uuidString)", isDirectory: true)
        var parts = extras
        parts["ppt/slides/slide1.xml"] = slideXML
        for (path, contents) in parts {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        return try PPTXSlideParser.parse(
            partPath: "ppt/slides/slide1.xml", in: PPTXPackage(root: root), warnings: &warnings)
    }

    private func slideXML(spTree: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <p:cSld><p:spTree>\(spTree)</p:spTree></p:cSld>
        </p:sld>
        """
    }

    @Test func customGeometryPromotesQuadsAndNormalizes() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:sp>
              <p:nvSpPr><p:cNvPr id="2" name="Custom"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
              <p:spPr>
                <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                <a:custGeom>
                  <a:avLst/><a:gdLst/><a:rect l="0" t="0" r="0" b="0"/>
                  <a:pathLst>
                    <a:path w="200" h="100">
                      <a:moveTo><a:pt x="0" y="0"/></a:moveTo>
                      <a:lnTo><a:pt x="200" y="0"/></a:lnTo>
                      <a:quadBezTo><a:pt x="200" y="100"/><a:pt x="100" y="100"/></a:quadBezTo>
                      <a:close/>
                    </a:path>
                  </a:pathLst>
                </a:custGeom>
                <a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>
              </p:spPr>
            </p:sp>
            """), warnings: &warnings)

        #expect(slide.shapes[0].customPathData == "M 0.0000 0.0000 C 0.0000 0.0000 1.0000 0.0000 1.0000 0.0000 C 1.0000 0.6667 0.8333 1.0000 0.5000 1.0000 C 0.5000 1.0000 0.0000 0.0000 0.0000 0.0000 Z")
        #expect(warnings.isEmpty)
    }

    @Test func customGeometryArcBecomesChordWithWarning() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:sp>
              <p:nvSpPr><p:cNvPr id="2" name="Arc"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
              <p:spPr>
                <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                <a:custGeom><a:pathLst>
                  <a:path w="100" h="100">
                    <a:moveTo><a:pt x="100" y="50"/></a:moveTo>
                    <a:arcTo wR="50" hR="50" stAng="0" swAng="5400000"/>
                  </a:path>
                </a:pathLst></a:custGeom>
                <a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>
              </p:spPr>
            </p:sp>
            """), warnings: &warnings)

        #expect(slide.shapes[0].customPathData == "M 1.0000 0.5000 C 1.0000 0.5000 0.5000 1.0000 0.5000 1.0000")
        #expect(warnings.contains { $0.contains("arc") && $0.contains("straight") })
    }

    @Test func formulaDrivenCustomGeometrySkipsWithWarning() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:sp>
              <p:nvSpPr><p:cNvPr id="2" name="Guided"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
              <p:spPr>
                <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                <a:custGeom><a:pathLst>
                  <a:path w="100" h="100">
                    <a:moveTo><a:pt x="adj1" y="0"/></a:moveTo>
                    <a:lnTo><a:pt x="100" y="100"/></a:lnTo>
                  </a:path>
                </a:pathLst></a:custGeom>
                <a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>
              </p:spPr>
            </p:sp>
            """), warnings: &warnings)
        #expect(slide.shapes[0].customPathData == nil)
        #expect(warnings.contains { $0.contains("formula-driven") })
    }

    @Test func grpFillResolvesThroughNestedGroups() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:grpSp>
              <p:nvGrpSpPr><p:cNvPr id="2" name="Outer"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr>
                <a:xfrm>
                  <a:off x="0" y="0"/><a:ext cx="1000000" cy="1000000"/>
                  <a:chOff x="0" y="0"/><a:chExt cx="1000000" cy="1000000"/>
                </a:xfrm>
                <a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill>
              </p:grpSpPr>
              <p:grpSp>
                <p:nvGrpSpPr><p:cNvPr id="3" name="Inner"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
                <p:grpSpPr><a:xfrm>
                  <a:off x="0" y="0"/><a:ext cx="1000000" cy="1000000"/>
                  <a:chOff x="0" y="0"/><a:chExt cx="1000000" cy="1000000"/>
                </a:xfrm></p:grpSpPr>
                <p:sp>
                  <p:nvSpPr><p:cNvPr id="4" name="Paper"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                  <p:spPr>
                    <a:xfrm><a:off x="0" y="0"/><a:ext cx="200000" cy="200000"/></a:xfrm>
                    <a:grpFill/>
                  </p:spPr>
                </p:sp>
              </p:grpSp>
            </p:grpSp>
            """), warnings: &warnings)
        #expect(slide.shapes.count == 1)
        #expect(slide.shapes[0].fill == .solid(colorHex: "FFFFFFFF"))
        #expect(slide.shapes[0].usesGroupFill == false)
    }

    @Test func groupsFlattenWithScaleTranslateAndFlip() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:grpSp>
              <p:nvGrpSpPr><p:cNvPr id="2" name="Group"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr><a:xfrm>
                <a:off x="1000000" y="1000000"/><a:ext cx="2000000" cy="2000000"/>
                <a:chOff x="0" y="0"/><a:chExt cx="1000000" cy="1000000"/>
              </a:xfrm></p:grpSpPr>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Scaled"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="100000" y="100000"/><a:ext cx="200000" cy="200000"/></a:xfrm>
                  <a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>
                </p:spPr>
              </p:sp>
            </p:grpSp>
            <p:grpSp>
              <p:nvGrpSpPr><p:cNvPr id="4" name="Flipped"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr><a:xfrm flipH="1">
                <a:off x="0" y="0"/><a:ext cx="1000000" cy="1000000"/>
                <a:chOff x="0" y="0"/><a:chExt cx="1000000" cy="1000000"/>
              </a:xfrm></p:grpSpPr>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="5" name="Mirrored"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="0" y="0"/><a:ext cx="200000" cy="200000"/></a:xfrm>
                  <a:solidFill><a:srgbClr val="00FF00"/></a:solidFill>
                </p:spPr>
              </p:sp>
            </p:grpSp>
            """), warnings: &warnings)

        let scaled = slide.shapes[0]
        #expect(scaled.transform == PPTXTransform(
            offXEMU: 1_200_000, offYEMU: 1_200_000, extXEMU: 400_000, extYEMU: 400_000))

        let mirrored = slide.shapes[1]
        #expect(mirrored.transform == PPTXTransform(
            offXEMU: 800_000, offYEMU: 0, extXEMU: 200_000, extYEMU: 200_000, flipH: true))
        #expect(warnings.isEmpty)
    }

    @Test func groupRotationSpinsChildCentersAndAddsAngles() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:grpSp>
              <p:nvGrpSpPr><p:cNvPr id="2" name="Turned"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr><a:xfrm rot="5400000">
                <a:off x="1000000" y="1000000"/><a:ext cx="2000000" cy="2000000"/>
                <a:chOff x="0" y="0"/><a:chExt cx="2000000" cy="2000000"/>
              </a:xfrm></p:grpSpPr>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Child"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm rot="600000"><a:off x="0" y="0"/><a:ext cx="400000" cy="400000"/></a:xfrm>
                  <a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>
                </p:spPr>
              </p:sp>
            </p:grpSp>
            """), warnings: &warnings)

        let child = slide.shapes[0].transform
        #expect(abs(child.offXEMU - 2_600_000) < 1)
        #expect(abs(child.offYEMU - 1_000_000) < 1)
        #expect(child.rotation60k == 6_000_000)
    }

    @Test func connectorParsesAsLineShape() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:cxnSp>
              <p:nvCxnSpPr><p:cNvPr id="2" name="Straight Arrow"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>
              <p:spPr>
                <a:xfrm flipV="1"><a:off x="0" y="0"/><a:ext cx="914400" cy="457200"/></a:xfrm>
                <a:prstGeom prst="line"><a:avLst/></a:prstGeom>
                <a:ln w="19050"><a:solidFill><a:srgbClr val="000000"/></a:solidFill></a:ln>
              </p:spPr>
            </p:cxnSp>
            """), warnings: &warnings)
        let connector = slide.shapes[0]
        #expect(connector.name == "Straight Arrow")
        #expect(connector.presetGeometry == "line")
        #expect(connector.transform.flipV)
        #expect(connector.stroke == PPTXStroke(colorHex: "000000FF", widthEMU: 19_050))
    }

    @Test func tableFlattensToTabSeparatedText() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:graphicFrame>
              <p:nvGraphicFramePr><p:cNvPr id="2" name="Table 1"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
              <p:xfrm><a:off x="914400" y="914400"/><a:ext cx="1828800" cy="914400"/></p:xfrm>
              <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">
                <a:tbl>
                  <a:tblGrid><a:gridCol w="914400"/><a:gridCol w="914400"/></a:tblGrid>
                  <a:tr h="457200">
                    <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:rPr sz="1800"/><a:t>A</a:t></a:r></a:p></a:txBody></a:tc>
                    <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>B</a:t></a:r></a:p></a:txBody></a:tc>
                  </a:tr>
                  <a:tr h="457200">
                    <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>C</a:t></a:r></a:p></a:txBody></a:tc>
                    <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>D</a:t></a:r></a:p></a:txBody></a:tc>
                  </a:tr>
                </a:tbl>
              </a:graphicData></a:graphic>
            </p:graphicFrame>
            """), warnings: &warnings)
        let table = slide.shapes[0]
        #expect(table.name == "Table 1")
        #expect(table.textBody?.plainText == "A\tB\nC\tD")

        #expect(table.textBody?.paragraphs.allSatisfy { $0.runs.first?.sizeHundredthsPt == 1800 } == true)
        #expect(warnings.contains { $0.contains("tabs") })
    }

    @Test func videoAndAudioPicturesResolveTheirMedia() throws {
        var warnings: [String] = []
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/video" Target="../media/media1.mp4"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/poster1.png"/>
          <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/audio" Target="file:///Volumes/SFX/bell%20tone.wav" TargetMode="External"/>
        </Relationships>
        """
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:pic>
              <p:nvPicPr><p:cNvPr id="2" name="Clip"/><p:cNvPicPr/><p:nvPr><a:videoFile r:link="rId2"/></p:nvPr></p:nvPicPr>
              <p:blipFill><a:blip r:embed="rId3"/></p:blipFill>
              <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm></p:spPr>
            </p:pic>
            <p:pic>
              <p:nvPicPr><p:cNvPr id="3" name="Bell"/><p:cNvPicPr/><p:nvPr><a:audioFile r:link="rId4"/></p:nvPr></p:nvPicPr>
              <p:blipFill><a:blip r:embed="rId3"/></p:blipFill>
              <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="457200" cy="457200"/></a:xfrm></p:spPr>
            </p:pic>
            """), extras: ["ppt/slides/_rels/slide1.xml.rels": rels], warnings: &warnings)
        let video = slide.shapes[0]
        #expect(video.mediaKind == .video)
        #expect(video.mediaPath?.hasSuffix("ppt/media/media1.mp4") == true)
        let audio = slide.shapes[1]
        #expect(audio.mediaKind == .audio)

        #expect(audio.mediaPath == "/Volumes/SFX/bell tone.wav")
        #expect(warnings.isEmpty)
    }

    @Test func picturesParseTheirClippingGeometry() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:pic>
              <p:nvPicPr><p:cNvPr id="2" name="Torn"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
              <p:blipFill><a:blip r:embed="rId9"/></p:blipFill>
              <p:spPr>
                <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                <a:custGeom><a:pathLst>
                  <a:path w="100" h="100">
                    <a:moveTo><a:pt x="0" y="0"/></a:moveTo>
                    <a:lnTo><a:pt x="100" y="0"/></a:lnTo>
                    <a:lnTo><a:pt x="50" y="100"/></a:lnTo>
                    <a:close/>
                  </a:path>
                </a:pathLst></a:custGeom>
              </p:spPr>
            </p:pic>
            <p:pic>
              <p:nvPicPr><p:cNvPr id="3" name="Round"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
              <p:blipFill><a:blip r:embed="rId9"/></p:blipFill>
              <p:spPr>
                <a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
                <a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>
              </p:spPr>
            </p:pic>
            """), warnings: &warnings)
        #expect(slide.shapes[0].customPathData?.hasPrefix("M 0.0000 0.0000") == true)
        #expect(slide.shapes[0].customPathData?.hasSuffix("Z") == true)
        #expect(slide.shapes[1].presetGeometry == "ellipse")
    }

    @Test func dynamicFieldsImportAsStaticTextWithWarning() throws {
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:sp>
              <p:nvSpPr><p:cNvPr id="2" name="Slide Number"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
              <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="457200"/></a:xfrm></p:spPr>
              <p:txBody>
                <a:bodyPr/>
                <a:p>
                  <a:r><a:t>Page </a:t></a:r>
                  <a:fld id="{11111111-2222-3333-4444-555555555555}" type="slidenum"><a:rPr b="1"/><a:t>7</a:t></a:fld>
                </a:p>
              </p:txBody>
            </p:sp>
            """), warnings: &warnings)
        #expect(slide.shapes[0].textBody?.plainText == "Page 7")
        #expect(slide.shapes[0].textBody?.paragraphs[0].runs[1].bold == true)
        #expect(warnings.contains { $0.contains("static text") })
    }

    @Test func smartArtImportsThePreLaidOutDrawing() throws {
        let dgmNS = "xmlns:dgm=\"http://schemas.openxmlformats.org/drawingml/2006/diagram\""
        let dspNS = "xmlns:dsp=\"http://schemas.microsoft.com/office/drawing/2008/diagram\""
        let aNS = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
        let rNS = "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        let extras: [String: String] = [
            "ppt/slides/_rels/slide1.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/diagramData" Target="../diagrams/data1.xml"/>
            </Relationships>
            """,
            "ppt/diagrams/data1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <dgm:dataModel \(dgmNS) \(aNS) \(rNS)>
              <dgm:ptLst/>
              <dgm:extLst><a:ext uri="http://schemas.microsoft.com/office/drawing/2008/diagram">
                <dsp:dataModelExt \(dspNS) relId="rId1" minVer="http://schemas.openxmlformats.org/drawingml/2006/diagram"/>
              </a:ext></dgm:extLst>
            </dgm:dataModel>
            """,
            "ppt/diagrams/_rels/data1.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.microsoft.com/office/2007/relationships/diagramDrawing" Target="drawing1.xml"/>
            </Relationships>
            """,
            "ppt/diagrams/drawing1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <dsp:drawing \(dspNS) \(aNS)>
              <dsp:spTree>
                <dsp:sp modelId="{1}">
                  <dsp:spPr>
                    <a:xfrm><a:off x="100000" y="200000"/><a:ext cx="500000" cy="300000"/></a:xfrm>
                    <a:prstGeom prst="roundRect"><a:avLst/></a:prstGeom>
                    <a:solidFill><a:srgbClr val="336699"/></a:solidFill>
                  </dsp:spPr>
                  <dsp:txBody><a:bodyPr/><a:p><a:r><a:t>Step 1</a:t></a:r></a:p></dsp:txBody>
                </dsp:sp>
              </dsp:spTree>
            </dsp:drawing>
            """,
        ]
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:graphicFrame>
              <p:nvGraphicFramePr><p:cNvPr id="2" name="Diagram 1"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
              <p:xfrm><a:off x="1000000" y="500000"/><a:ext cx="4000000" cy="3000000"/></p:xfrm>
              <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram">
                <dgm:relIds \(dgmNS) r:dm="rId5" r:lo="rId5" r:qs="rId5" r:cs="rId5"/>
              </a:graphicData></a:graphic>
            </p:graphicFrame>
            """), extras: extras, warnings: &warnings)
        #expect(slide.shapes.count == 1)
        let step = slide.shapes[0]

        #expect(step.transform.offXEMU == 1_100_000)
        #expect(step.transform.offYEMU == 700_000)
        #expect(step.presetGeometry == "roundRect")
        #expect(step.fill == .solid(colorHex: "336699FF"))
        #expect(step.textBody?.plainText == "Step 1")
        #expect(warnings.isEmpty)
    }

    @Test func sectionListResolvesSlideMembership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-sections-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parts: [String: String] = [
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
            </Relationships>
            """,
            "ppt/presentation.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <p:sldIdLst>
                <p:sldId id="256" r:id="rId2"/>
                <p:sldId id="257" r:id="rId3"/>
              </p:sldIdLst>
              <p:sldSz cx="12192000" cy="6858000"/>
              <p:extLst>
                <p:ext uri="{521415D9-36F7-43E2-AB2F-B90AF26B5E84}">
                  <p14:sectionLst xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main">
                    <p14:section name="Opening" id="{AB12CD34-0000-1111-2222-333344445555}">
                      <p14:sldIdLst><p14:sldId id="256"/></p14:sldIdLst>
                    </p14:section>
                    <p14:section name="Message" id="{FF12CD34-0000-1111-2222-333344445555}">
                      <p14:sldIdLst><p14:sldId id="257"/></p14:sldIdLst>
                    </p14:section>
                  </p14:sectionLst>
                </p:ext>
              </p:extLst>
            </p:presentation>
            """,
            "ppt/_rels/presentation.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
              <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
            </Relationships>
            """,
        ]
        for (path, contents) in parts {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        var warnings: [String] = []
        let result = try PPTXPresentationParser.parse(in: PPTXPackage(root: root), warnings: &warnings)
        #expect(result.sections == [
            PPTXSection(id: "ab12cd34-0000-1111-2222-333344445555", name: "Opening", slideIndexes: [0]),
            PPTXSection(id: "ff12cd34-0000-1111-2222-333344445555", name: "Message", slideIndexes: [1]),
        ])
    }

    @Test func smartArtWithoutDrawingPartSkipsWithWarning() throws {
        let dgmNS = "xmlns:dgm=\"http://schemas.openxmlformats.org/drawingml/2006/diagram\""
        var warnings: [String] = []
        let slide = try parseStagedSlide(slideXML(spTree: """
            <p:graphicFrame>
              <p:nvGraphicFramePr><p:cNvPr id="2" name="Diagram 2"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
              <p:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></p:xfrm>
              <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram">
                <dgm:relIds \(dgmNS) r:dm="rId9" r:lo="rId9" r:qs="rId9" r:cs="rId9"/>
              </a:graphicData></a:graphic>
            </p:graphicFrame>
            """), warnings: &warnings)
        #expect(slide.shapes.isEmpty)
        #expect(warnings.contains { $0.contains("Diagram 2") && $0.contains("skipped") })
    }
}
