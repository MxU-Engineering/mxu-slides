import Foundation
import RenderEngine
import XCTest
@testable import OutputEngine

@MainActor
final class OutputSliceTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private func makeScreen(_ outputs: OutputManager) throws -> PlaceholderScreen {
        try XCTUnwrap(outputs.addPlaceholderScreen(name: "Wide", width: 384, height: 108))
    }

    func testDefaultSliceIsTheScreenItself() throws {
        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        let slices = outputs.slices(forScreen: screen.id)
        XCTAssertEqual(slices.map(\.id), [screen.id], "the implicit default carries the screen id")
        XCTAssertEqual(slices[0].sourceRect, Compositor.fullSourceRect)
        let info = try XCTUnwrap(outputs.sliceInfo(for: screen.id))
        XCTAssertEqual(info.screenID, screen.id)
        XCTAssertEqual(info.width, 384)
        XCTAssertEqual(info.height, 108)
    }

    func testExtraSlicesResolveRegionAndPixelSize() throws {
        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        let left = try XCTUnwrap(outputs.addSlice(
            toScreen: screen.id, name: "Left",
            sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(outputs.slices(forScreen: screen.id).count, 2)
        let info = try XCTUnwrap(outputs.sliceInfo(for: left.id))
        XCTAssertEqual(info.screenID, screen.id)
        XCTAssertEqual(info.width, 192, "half a 384-wide canvas")
        XCTAssertEqual(info.height, 108)
        XCTAssertEqual(info.name, "Left")

        outputs.setSliceSourceRect(
            CGRect(x: 0.9, y: -1, width: 5, height: 0), forSlice: left.id)
        let clamped = try XCTUnwrap(outputs.sliceInfo(for: left.id)).sourceRect
        XCTAssertEqual(clamped.minX, 0.9, accuracy: 0.001)
        XCTAssertEqual(clamped.minY, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(clamped.maxX, 1.0001)
        XCTAssertGreaterThan(clamped.height, 0)
    }

    func testDisplayExclusivityIsPerDisplayNotPerScreen() throws {

        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        let left = try XCTUnwrap(outputs.addSlice(
            toScreen: screen.id, sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        let right = try XCTUnwrap(outputs.addSlice(
            toScreen: screen.id, sourceRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))

        outputs.assignPlaceholderDevice(placeholderID: left.id, displayUUID: "DISPLAY-A")
        outputs.assignPlaceholderDevice(placeholderID: right.id, displayUUID: "DISPLAY-B")
        XCTAssertEqual(outputs.placeholderDevices[left.id], "DISPLAY-A")
        XCTAssertEqual(outputs.placeholderDevices[right.id], "DISPLAY-B",
                       "two slices of ONE screen hold two displays")

        outputs.assignPlaceholderDevice(placeholderID: right.id, displayUUID: "DISPLAY-A")
        XCTAssertNil(outputs.placeholderDevices[left.id], "DISPLAY-A stolen from the left slice")
        XCTAssertEqual(outputs.placeholderDevices[right.id], "DISPLAY-A")
    }

    func testClaimedSlicePausesTheOffscreenTimer() throws {
        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        XCTAssertTrue(screen.isRunning, "unbacked screens pace themselves")
        let slice = try XCTUnwrap(outputs.addSlice(
            toScreen: screen.id, sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        outputs.assignPlaceholderDevice(placeholderID: slice.id, displayUUID: "DISPLAY-A")
        XCTAssertFalse(screen.isRunning, "any claimed slice means glass paces the scene")
        outputs.assignPlaceholderDevice(placeholderID: slice.id, displayUUID: nil)
        XCTAssertTrue(screen.isRunning, "unclaimed again = self-paced again")
    }

    func testRemoveSliceClearsEveryStore() throws {
        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        let slice = try XCTUnwrap(outputs.addSlice(
            toScreen: screen.id, sourceRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        outputs.assignPlaceholderDevice(placeholderID: slice.id, displayUUID: "DISPLAY-A")
        var adjustments = OutputAdjustments()
        adjustments.brightness = -0.2
        outputs.setAdjustments(adjustments, forScreen: slice.id)
        outputs.setVideoDelay(3, forScreen: slice.id)

        outputs.removeSlice(id: slice.id)
        XCTAssertEqual(outputs.slices(forScreen: screen.id).count, 1)
        XCTAssertNil(outputs.sliceInfo(for: slice.id))
        XCTAssertNil(outputs.placeholderDevices[slice.id])
        XCTAssertNil(outputs.outputAdjustments[slice.id])
        XCTAssertEqual(outputs.videoDelay(forScreen: slice.id), 0)
    }

    func testRemoveScreenClearsItsSlices() throws {
        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        let slice = try XCTUnwrap(outputs.addSlice(toScreen: screen.id))
        outputs.assignPlaceholderDevice(placeholderID: slice.id, displayUUID: "DISPLAY-A")
        outputs.removePlaceholderScreen(id: screen.id)
        XCTAssertNil(outputs.sliceInfo(for: slice.id))
        XCTAssertNil(outputs.placeholderDevices[slice.id])
        XCTAssertTrue(outputs.slices(forScreen: screen.id).isEmpty)
    }

    func testSliceCRUDFiresPersistence() throws {
        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        var saves = 0
        outputs.placeholderConfigurationChanged = { saves += 1 }
        let slice = try XCTUnwrap(outputs.addSlice(toScreen: screen.id))
        XCTAssertEqual(saves, 1)
        outputs.setSliceSourceRect(
            CGRect(x: 0, y: 0, width: 0.5, height: 1), forSlice: slice.id)
        XCTAssertEqual(saves, 2)
        outputs.setSliceSourceRect(
            CGRect(x: 0, y: 0, width: 0.5, height: 1), forSlice: slice.id)
        XCTAssertEqual(saves, 2, "no-op region writes don't churn the save path")
        outputs.setSliceName("Left", forSlice: slice.id)
        XCTAssertEqual(saves, 3)
        outputs.removeSlice(id: slice.id)
        XCTAssertEqual(saves, 4)
    }

    func testProviderNormalizesSliceIdsToTheOwningScreen() throws {

        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        outputs.setRole(.confidence, forScreen: screen.id)
        var confidenceScene = RenderScene(canvasSize: CGSize(width: 384, height: 108))
        confidenceScene.addItem(
            RenderItem(
                id: "marker", frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                content: .solid(.white)),
            to: .slide
        )
        let marker = confidenceScene
        outputs.confidenceSceneProvider = { _ in marker }
        let slice = try XCTUnwrap(outputs.addSlice(
            toScreen: screen.id, sourceRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        let scene = outputs.previewProvider(for: slice.id.uuidString)()
        XCTAssertEqual(scene, marker, "the slice composites its screen's scene")
    }

    func testMaskSliceScoping() throws {

        let outputs = try makeManager()
        let screen = try makeScreen(outputs)
        let mirror = try XCTUnwrap(outputs.addSlice(toScreen: screen.id, name: "Lobby"))
        let band = "M 0.25 0 L 0.75 0 L 0.75 1 L 0.25 1 Z"
        outputs.setMasks(
            [OutputMask(name: "Column", pathData: band, sliceIds: [mirror.id])],
            forScreen: screen.id)
        XCTAssertNil(
            outputs.maskProvider(for: screen.id.uuidString)(),
            "scoped mask leaves the default output alone")
        XCTAssertNotNil(
            outputs.maskProvider(for: mirror.id.uuidString)(),
            "scoped mask covers its slice")

        outputs.setMasks([OutputMask(name: "Column", pathData: band)], forScreen: screen.id)
        let defaultTexture = try XCTUnwrap(outputs.maskProvider(for: screen.id.uuidString)())
        let mirrorTexture = try XCTUnwrap(outputs.maskProvider(for: mirror.id.uuidString)())
        XCTAssertTrue(defaultTexture === mirrorTexture,
                      "unscoped masks share one raster across a mirror's slices")
    }
}

@MainActor
final class AlignmentGridTests: XCTestCase {
    func testTestPatternReplacesProgramOnEveryOutput() throws {
        let outputs: OutputManager
        do {
            outputs = OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 384, height: 108))
        let program = RenderScene(canvasSize: CGSize(width: 384, height: 108))
        outputs.sceneProvider = { program }
        let slice = try XCTUnwrap(outputs.addSlice(
            toScreen: screen.id, sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))

        XCTAssertEqual(outputs.previewProvider(for: screen.id.uuidString)(), program)
        outputs.setTestPattern(true, forScreen: screen.id)
        let onDefault = outputs.previewProvider(for: screen.id.uuidString)()
        let onSlice = outputs.previewProvider(for: slice.id.uuidString)()
        XCTAssertNotEqual(onDefault, program, "the grid replaces program")
        XCTAssertEqual(onDefault, onSlice, "every output of the screen shows the same grid")
        XCTAssertGreaterThan(onDefault.layers.flatMap(\.items).count, 20,
                             "the grid actually carries lines")
        outputs.setTestPattern(false, forScreen: screen.id)
        XCTAssertEqual(outputs.previewProvider(for: screen.id.uuidString)(), program)
    }

    func testSyncTestReplacesProgramAndDrivesOnePlayerAcrossScreens() throws {
        let outputs: OutputManager
        do {
            outputs = OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        let wall = try XCTUnwrap(outputs.addPlaceholderScreen(name: "Wall", width: 384, height: 108))
        let stream = try XCTUnwrap(outputs.addPlaceholderScreen(name: "Stream", width: 192, height: 108))
        let program = RenderScene(canvasSize: CGSize(width: 384, height: 108))
        outputs.sceneProvider = { program }
        let slice = try XCTUnwrap(outputs.addSlice(
            toScreen: wall.id, sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        var playback: [Bool] = []
        outputs.syncTestPlayback = { playback.append($0) }

        outputs.setSyncTest(true, forScreen: wall.id)
        let onWall = outputs.previewProvider(for: wall.id.uuidString)()
        XCTAssertEqual(onWall, outputs.previewProvider(for: slice.id.uuidString)())
        XCTAssertEqual(
            onWall.layers.flatMap(\.items).map(\.content),
            [.media(id: OutputManager.syncTestMediaID, scaleMode: .fit, sourceRect: nil)])
        XCTAssertEqual(onWall.canvasSize, CGSize(width: 384, height: 108))
        XCTAssertEqual(outputs.previewProvider(for: stream.id.uuidString)(), program)
        outputs.setSyncTest(true, forScreen: stream.id)
        XCTAssertEqual(outputs.previewProvider(for: stream.id.uuidString)().canvasSize, CGSize(width: 192, height: 108))
        outputs.setSyncTest(false, forScreen: wall.id)
        XCTAssertEqual(outputs.previewProvider(for: wall.id.uuidString)(), program)
        outputs.setSyncTest(false, forScreen: stream.id)
        XCTAssertEqual(playback, [true, false], "one player, from the first screen on to the last off")
        outputs.setTestPattern(true, forScreen: wall.id)
        outputs.setSyncTest(true, forScreen: wall.id)
        XCTAssertGreaterThan(outputs.previewProvider(for: wall.id.uuidString)().layers.flatMap(\.items).count, 20,
                             "the rigging grid outranks the sync test")
    }
}

@MainActor
final class PackedFrameTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    func testNonExclusiveClaimsShareADisplay() throws {
        let outputs = try makeManager()
        let wall = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 832, height: 416))
        let strip = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Strip", width: 3840, height: 540))

        outputs.assignPlaceholderDevice(placeholderID: wall.id, displayUUID: "FRAME-4K")
        outputs.assignPlaceholderDevice(
            placeholderID: strip.id, displayUUID: "FRAME-4K", exclusive: false)
        XCTAssertEqual(outputs.placeholderDevices[wall.id], "FRAME-4K",
                       "alongside-claims keep the incumbent")
        XCTAssertEqual(outputs.placeholderDevices[strip.id], "FRAME-4K")

        let projector = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Projector", width: 1920, height: 1080))
        outputs.assignPlaceholderDevice(placeholderID: projector.id, displayUUID: "FRAME-4K")
        XCTAssertNil(outputs.placeholderDevices[wall.id])
        XCTAssertNil(outputs.placeholderDevices[strip.id])
        XCTAssertEqual(outputs.placeholderDevices[projector.id], "FRAME-4K")
    }

    func testCompositeMirrorPacksTwoScreensIntoOneFeed() throws {

        let compositor: Compositor
        do {
            compositor = try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        func solid(_ color: SceneColor, canvas: CGSize) -> RenderScene {
            var scene = RenderScene(canvasSize: canvas)
            scene.addItem(
                RenderItem(
                    id: "fill", frame: CGRect(origin: .zero, size: canvas),
                    content: .solid(color)),
                to: .stillGraphics
            )
            return scene
        }
        let wall = solid(SceneColor(red: 1, green: 0, blue: 0),
                         canvas: CGSize(width: 96, height: 54))
        let strip = solid(SceneColor(red: 0, green: 0, blue: 1),
                          canvas: CGSize(width: 160, height: 45))
        let delivery = expectation(description: "packed frame")
        let delivered = Locked<CVPixelBuffer?>(nil)
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 320, height: 180, framesPerSecond: 30,
            provider: { RenderScene(canvasSize: CGSize(width: 320, height: 180)) },
            composite: [
                OutputMirror.CompositeLayer(
                    provider: { wall }, sourceRect: nil,
                    placement: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                OutputMirror.CompositeLayer(
                    provider: { strip }, sourceRect: nil,
                    placement: CGRect(x: 0, y: 0.75, width: 1, height: 0.25)),
            ],
            sink: { buffer, _ in
                let first = delivered.withLock { held -> Bool in
                    guard held == nil else { return false }
                    held = buffer
                    return true
                }
                if first { delivery.fulfill() }
            }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }
        mirror.tick(at: 0)
        wait(for: [delivery], timeout: 5)

        let buffer = try XCTUnwrap(delivered.value)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func bgra(x: Int, y: Int) -> (b: UInt8, r: UInt8) {
            let pixels = base.advanced(by: y * rowBytes + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            return (pixels[0], pixels[2])
        }
        XCTAssertGreaterThan(bgra(x: 80, y: 40).r, 200, "wall lands top-left")
        XCTAssertGreaterThan(bgra(x: 160, y: 160).b, 200, "strip lands along the bottom")
        XCTAssertLessThan(bgra(x: 240, y: 40).r, 60, "unclaimed frame area is black")
        XCTAssertLessThan(bgra(x: 240, y: 40).b, 60)
    }
}

@MainActor
final class OutputPlacementTests: XCTestCase {
    func testPlacementStoreRoundTripsAndCleansUp() throws {
        let outputs: OutputManager
        do {
            outputs = OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 832, height: 416))
        var saves = 0
        outputs.placeholderConfigurationChanged = { saves += 1 }

        let placement = OutputPlacement(
            frameWidth: 1920, frameHeight: 1080, x: 0, y: 0, width: 832, height: 416)
        outputs.setPlacement(placement, forSlice: screen.id)
        XCTAssertEqual(saves, 1, "placements persist")
        XCTAssertEqual(outputs.placement(forSlice: screen.id), placement)
        let unit = try XCTUnwrap(outputs.placement(forSlice: screen.id)).unitRect
        XCTAssertEqual(unit.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(unit.width, 832.0 / 1920.0, accuracy: 0.0001)

        outputs.setPlacement(placement, forSlice: screen.id)
        XCTAssertEqual(saves, 1, "no-op writes don't churn the save path")

        outputs.setPlacement(
            OutputPlacement(frameWidth: 1920, frameHeight: 1080,
                            x: 0, y: 0, width: 1920, height: 1080),
            forSlice: screen.id)
        XCTAssertNil(outputs.placement(forSlice: screen.id))

        outputs.setPlacement(placement, forSlice: screen.id)
        outputs.removePlaceholderScreen(id: screen.id)
        XCTAssertNil(outputs.placement(forSlice: screen.id), "removal clears the store")
    }

    func testSlicePlacementClearsWithTheSlice() throws {
        let outputs: OutputManager
        do {
            outputs = OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: 832, height: 416))
        let slice = try XCTUnwrap(outputs.addSlice(toScreen: screen.id, name: "Banner"))
        outputs.setPlacement(
            OutputPlacement(frameWidth: 1920, frameHeight: 1080,
                            x: 1920 - 384, y: 0, width: 384, height: 768),
            forSlice: slice.id)
        XCTAssertNotNil(outputs.placement(forSlice: slice.id))
        outputs.removeSlice(id: slice.id)
        XCTAssertNil(outputs.placement(forSlice: slice.id))
    }
}
