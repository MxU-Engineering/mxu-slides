import CoreGraphics

public extension RenderScene {

    static func sampleLyricScene() -> RenderScene {

        var scene = RenderScene(canvasSize: CGSize(width: 1920, height: 1080))

        scene.addItem(
            RenderItem(
                id: "bg-wash",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                content: .solid(SceneColor(red: 0.07, green: 0.12, blue: 0.22))
            ),
            to: .stillGraphics
        )

        scene.addItem(
            RenderItem(
                id: "lyric-1",
                frame: CGRect(x: 160, y: 300, width: 1600, height: 480),
                content: .text(
                    StyledText(
                        string: "Amazing grace, how sweet the sound\nThat saved a wretch like me",
                        fontName: "HelveticaNeue-Bold",
                        fontSize: 96,
                        color: .white,
                        alignment: .center,
                        shadow: TextShadow(
                            color: SceneColor(red: 0, green: 0, blue: 0, alpha: 0.6),
                            blurRadius: 12,
                            offsetX: 0,
                            offsetY: 4
                        )
                    )
                )
            ),
            to: .slide
        )

        scene.addItem(
            RenderItem(
                id: "overlay-bar",
                frame: CGRect(x: 0, y: 1000, width: 1920, height: 80),
                content: .solid(SceneColor(red: 0.85, green: 0.55, blue: 0.10, alpha: 0.9))
            ),
            to: .overlays
        )

        return scene
    }
}
