import SwiftUI

enum GlyphKind: String {
    case services       
    case presentations  
    case overlays       
    case media          
    case audio          
    case themes         
    case libraries      
    case folder
    case viewOptions    
    case timers         
    case alerts         
    case broadcast      
    case combos         
    case screens        
    case confidence     
    case clear          
    case midi           
    case mixer          
    case sync           
    case notes          
    case fade           
    case crossfade      
}

struct Glyph: View {
    let kind: GlyphKind
    var size: CGFloat = 17

    private var stroke: CGFloat { 1.4 }

    var body: some View {
        canvasBody

            .frame(width: size, height: kind == .viewOptions ? size * (13.5 / 17) : size)
    }

    @ViewBuilder
    private var canvasBody: some View {
        switch kind {
        case .services:
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                    .padding(.top, 2)
                HStack(spacing: 5) {
                    tick
                    tick
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        case .presentations:
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                    .padding([.leading, .top], 3.5)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                    .padding([.trailing, .bottom], 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.cardSurface)
                            .padding([.trailing, .bottom], 3.5)
                    )
            }
        case .overlays:
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                RoundedRectangle(cornerRadius: 1)
                    .frame(height: 3)
                    .padding(.horizontal, 3.5)
                    .padding(.bottom, 3)
            }
        case .media:
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                MountainShape()
                    .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                    .padding(3.5)
            }
        case .audio:
            HStack(spacing: 2.6) {
                bar(7)
                bar(13)
                bar(9)
            }
        case .viewOptions:

            VStack(spacing: 1.2) {
                sliderRail(knobAt: 0.72)
                sliderRail(knobAt: 0.26)
                sliderRail(knobAt: 0.55)
            }
        case .mixer:

            VStack(spacing: 1.2) {
                sliderRail(knobAt: 0.30)
                sliderRail(knobAt: 0.62)
                sliderRail(knobAt: 0.42)
            }
            .rotationEffect(.degrees(-90))
        case .themes:
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                DiagonalShape()
                    .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .padding(3.5)
            }
        case .fade:

            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                EaseCurveShape(rising: true)
                    .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .padding(3.5)
            }
        case .crossfade:

            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                EaseCurveShape(rising: true)
                    .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .padding(3.5)
                EaseCurveShape(rising: false)
                    .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .padding(3.5)
            }
        case .libraries:
            VStack(spacing: 1.6) {
                HStack(spacing: 2.6) {
                    spine(height: 11)
                    spine(height: 11)
                    spine(height: 11)
                }
                Capsule().frame(width: 15, height: 1.4)
            }
        case .folder:
            FolderShape()
                .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                .padding(1)
        case .timers:

            StopwatchShape()
                .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                .padding(0.5)
        case .alerts:

            BellShape()
                .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                .padding(0.5)
        case .broadcast:

            ZStack {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: stroke))
                Circle()
                    .frame(width: 5, height: 5)
            }
        case .combos:

            BoltShape()
                .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                .padding(1.5)
        case .screens:

            VStack(spacing: 1.2) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                Rectangle().frame(width: 1.4, height: 1.6)
                Capsule().frame(width: 7, height: 1.4)
            }
            .padding(.vertical, 0.5)
        case .confidence:

            VStack(spacing: 1.2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(lineWidth: stroke)
                    VStack(alignment: .leading, spacing: 1.8) {
                        Capsule().frame(width: 7, height: 1.2)
                        Capsule().frame(width: 4.5, height: 1.2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 3.2)
                }
                Rectangle().frame(width: 1.4, height: 1.6)
                Capsule().frame(width: 7, height: 1.4)
            }
            .padding(.vertical, 0.5)
        case .notes:

            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(lineWidth: stroke)
                    .padding(.horizontal, 1.5)
                VStack(alignment: .leading, spacing: 2.2) {
                    Capsule().frame(width: 8, height: 1.3)
                    Capsule().frame(width: 8, height: 1.3)
                    Capsule().frame(width: 5, height: 1.3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4.5)
            }
        case .sync:

            SyncArcsShape()
                .stroke(style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                .padding(1)
        case .clear:

            ZStack {
                Circle().stroke(style: StrokeStyle(lineWidth: stroke))
                Capsule()
                    .frame(width: stroke, height: 11)
                    .rotationEffect(.degrees(45))
            }
            .padding(1)
        case .midi:

            ZStack {
                Circle().stroke(style: StrokeStyle(lineWidth: stroke))
                HStack(spacing: 1.8) {
                    Circle().frame(width: 1.8, height: 1.8)
                    Circle().frame(width: 1.8, height: 1.8)
                        .offset(y: -1.6)
                    Circle().frame(width: 1.8, height: 1.8)
                }
            }
            .padding(1)
            .padding(1)
        }
    }

    private var tick: some View {
        Capsule().frame(width: 1.4, height: 4)
            .frame(maxHeight: .infinity, alignment: .top)
            .fixedSize()
    }

    private func bar(_ height: CGFloat) -> some View {
        Capsule().frame(width: 2, height: height)
    }

    private func sliderRail(knobAt fraction: CGFloat) -> some View {
        GeometryReader { geo in
            let knob: CGFloat = 4.4
            let gap: CGFloat = 1.1
            let centerX = (geo.size.width - knob) * fraction + knob / 2
            ZStack(alignment: .leading) {
                Capsule()
                    .frame(width: max(0, centerX - knob / 2 - gap), height: stroke)
                    .frame(maxHeight: .infinity)
                Capsule()
                    .frame(
                        width: max(0, geo.size.width - (centerX + knob / 2 + gap)),
                        height: stroke
                    )
                    .frame(maxHeight: .infinity)
                    .offset(x: centerX + knob / 2 + gap)
                Circle()
                    .strokeBorder(lineWidth: stroke)
                    .frame(width: knob, height: knob)
                    .frame(maxHeight: .infinity)
                    .offset(x: centerX - knob / 2)
            }
        }
    }


    private func spine(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .strokeBorder(lineWidth: 1.2)
            .frame(width: 3.6, height: height)
    }
}

private struct StopwatchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()

        p.move(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.06))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.06))

        p.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.06))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.2))

        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.6)
        let radius = rect.width * 0.36
        p.addEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))

        p.move(to: center)
        p.addLine(to: CGPoint(
            x: center.x + radius * 0.55, y: center.y - radius * 0.55
        ))
        return p
    }
}

private struct BellShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let lipY = rect.minY + rect.height * 0.74

        p.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: lipY))
        p.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.08),
            control1: CGPoint(x: rect.minX + rect.width * 0.24, y: lipY - rect.height * 0.42),
            control2: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.08)
        )
        p.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.12, y: lipY),
            control1: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.minY + rect.height * 0.08),
            control2: CGPoint(x: rect.maxX - rect.width * 0.24, y: lipY - rect.height * 0.42)
        )

        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.12, y: lipY))

        p.move(to: CGPoint(x: rect.midX - rect.width * 0.1, y: lipY + rect.height * 0.1))
        p.addQuadCurve(
            to: CGPoint(x: rect.midX + rect.width * 0.1, y: lipY + rect.height * 0.1),
            control: CGPoint(x: rect.midX, y: lipY + rect.height * 0.24)
        )
        return p
    }
}

private struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.35))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.maxY - rect.height * 0.3))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

private struct SyncArcsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        func pt(_ degrees: Double) -> CGPoint {
            let t = degrees * .pi / 180
            return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
        }
        func arc(from a: Double, to b: Double) {
            p.move(to: pt(a))
            var t = a + 8
            while t < b { p.addLine(to: pt(t)); t += 8 }
            p.addLine(to: pt(b))

            let end = pt(b)
            let tangent = CGPoint(x: -sin(b * .pi / 180), y: cos(b * .pi / 180))
            let back = CGPoint(x: -tangent.x, y: -tangent.y)
            let length = r * 0.55
            for turn in [-38.0, 38.0] {
                let radians = turn * .pi / 180
                let d = CGPoint(
                    x: back.x * cos(radians) - back.y * sin(radians),
                    y: back.x * sin(radians) + back.y * cos(radians))
                p.move(to: end)
                p.addLine(to: CGPoint(x: end.x + d.x * length, y: end.y + d.y * length))
            }
        }

        arc(from: 200, to: 340)
        arc(from: 20, to: 160)
        return p
    }
}

private struct EaseCurveShape: Shape {
    let rising: Bool
    func path(in rect: CGRect) -> Path {
        let startY = rising ? rect.maxY : rect.minY
        let endY = rising ? rect.minY : rect.maxY
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: startY))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: endY),
            control1: CGPoint(x: rect.minX + rect.width * 0.62, y: startY),
            control2: CGPoint(x: rect.maxX - rect.width * 0.62, y: endY)
        )
        return p
    }
}

private struct DiagonalShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

private struct FolderShape: Shape {

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r: CGFloat = min(rect.width, rect.height) * 0.14
        let shoulderY = rect.minY + rect.height * 0.24
        let tabEnd = rect.minX + rect.width * 0.38
        let slopeEnd = tabEnd + rect.width * 0.18
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: tabEnd, y: rect.minY), radius: r
        )
        p.addArc(
            tangent1End: CGPoint(x: tabEnd + rect.width * 0.06, y: rect.minY),
            tangent2End: CGPoint(x: slopeEnd, y: shoulderY), radius: r * 0.9
        )
        p.addArc(
            tangent1End: CGPoint(x: slopeEnd, y: shoulderY),
            tangent2End: CGPoint(x: rect.maxX, y: shoulderY), radius: r * 0.9
        )
        p.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: shoulderY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r
        )
        p.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r
        )
        p.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r
        )
        p.closeSubpath()
        return p
    }
}

extension LibrarySection {
    var glyph: GlyphKind {
        switch self {
        case .services: .services
        case .presentations: .presentations
        case .overlays: .overlays
        case .media: .media
        case .audio: .audio
        case .themes: .themes
        case .confidence: .confidence
        }
    }
}

private struct BoltShape: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var p = Path()
        p.move(to: pt(0.60, 0.02))
        p.addLine(to: pt(0.16, 0.58))
        p.addLine(to: pt(0.44, 0.58))
        p.addLine(to: pt(0.40, 0.98))
        p.addLine(to: pt(0.84, 0.42))
        p.addLine(to: pt(0.56, 0.42))
        p.closeSubpath()
        return p
    }
}
