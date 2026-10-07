import Foundation

public enum PathPresets {

    public static let ellipse =
        "M 0.5 0 C 0.77614 0 1 0.22386 1 0.5 " +
        "C 1 0.77614 0.77614 1 0.5 1 " +
        "C 0.22386 1 0 0.77614 0 0.5 " +
        "C 0 0.22386 0.22386 0 0.5 0 Z"

    public static let rectanglePerimeter =
        "M 0.15 0 L 0.85 0 Q 1 0 1 0.15 L 1 0.85 " +
        "Q 1 1 0.85 1 L 0.15 1 Q 0 1 0 0.85 L 0 0.15 Q 0 0 0.15 0 Z"

    public static let line = "M 0 0.5 L 1 0.5"

    public static let arc = "M 0 1 Q 0.5 0 1 1"
}
