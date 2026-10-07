import Foundation

public enum FontReplacement {
    public static func applying(_ map: [String: String], to presentation: Presentation) -> Presentation {
        guard !map.isEmpty else { return presentation }
        var result = presentation
        result.slides = presentation.slides.map { slide in
            var slide = slide
            slide.objects = slide.objects.map { object in
                var object = object
                if var style = object.textStyle {
                    if let name = style.fontName, let replacement = map[name] {
                        style.fontName = replacement
                    }
                    if let lines = style.lineStyles {
                        style.lineStyles = lines.map { line in
                            var line = line
                            if let name = line.fontName, let replacement = map[name] {
                                line.fontName = replacement
                            }
                            return line
                        }
                    }
                    object.textStyle = style
                }
                if let runs = object.styleRuns {
                    object.styleRuns = runs.map { run in
                        var run = run
                        if let name = run.fontName, let replacement = map[name] {
                            run.fontName = replacement
                        }
                        return run
                    }
                }
                return object
            }
            return slide
        }
        return result
    }
}
