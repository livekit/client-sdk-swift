/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import CoreVideo
import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

#if os(iOS) || os(macOS)
import MetalKit

/// Guards the *rendering* contract of the drawable-size clamp, as distinct from the memory win:
/// the clamp must not change what the viewer sees.
///
/// Two invariants carry that, and both are checked for every layout mode / orientation / aspect
/// combination below:
///
/// 1. **Aspect preserved.** The drawable keeps the video's aspect ratio, so the renderer's vertex
///    and crop maths — which `RTCMTLRenderer` derives from the frame, not the drawable — lands
///    identically, and the rotation flip in `-drawableSize` still agrees with the frame rotation.
/// 2. **No under-sampling.** The drawable is `min(video pixels, displayed pixels)`, so it is never
///    smaller than what is on screen unless the source itself is. A 1:1 or better pixel mapping
///    cannot soften the image.
///
/// Together these also mean the clamp *removes* a resample: previously the shader upsampled the
/// video into an oversized drawable and Core Animation then scaled that down to the view. Now the
/// shader writes a drawable the size of what is displayed and Core Animation blits it 1:1.
@Suite(.tags(.media), .serialized)
@MainActor
struct VideoViewRendererGeometryTests {
    struct Geometry: Sendable, CustomTestStringConvertible {
        let name: String
        let video: RendererProbe.Resolution
        let frame: CGRect
        let layoutMode: VideoView.LayoutMode

        var testDescription: String { name }
    }

    nonisolated static let landscapeVideo = RendererProbe.Resolution(width: 1920, height: 1080)
    nonisolated static let portraitVideo = RendererProbe.Resolution(width: 1080, height: 1920)
    nonisolated static let squareVideo = RendererProbe.Resolution(width: 1080, height: 1080)

    nonisolated static let geometries: [Geometry] = [
        // Matching aspect, both modes.
        .init(name: "landscape-video/landscape-view/fill", video: landscapeVideo,
              frame: CGRect(x: 0, y: 0, width: 320, height: 180), layoutMode: .fill),
        .init(name: "landscape-video/landscape-view/fit", video: landscapeVideo,
              frame: CGRect(x: 0, y: 0, width: 320, height: 180), layoutMode: .fit),
        // Portrait source — the case where `-drawableSize` flips width and height.
        .init(name: "portrait-video/portrait-view/fill", video: portraitVideo,
              frame: CGRect(x: 0, y: 0, width: 180, height: 320), layoutMode: .fill),
        .init(name: "portrait-video/portrait-view/fit", video: portraitVideo,
              frame: CGRect(x: 0, y: 0, width: 180, height: 320), layoutMode: .fit),
        // Mismatched aspect: `.fill` overflows and clips, `.fit` letterboxes. The renderer frame
        // is larger than the view in the first case, which is why the clamp reads `rendererSize`
        // and not the view's own bounds.
        .init(name: "landscape-video/portrait-view/fill", video: landscapeVideo,
              frame: CGRect(x: 0, y: 0, width: 180, height: 320), layoutMode: .fill),
        .init(name: "landscape-video/portrait-view/fit", video: landscapeVideo,
              frame: CGRect(x: 0, y: 0, width: 180, height: 320), layoutMode: .fit),
        .init(name: "portrait-video/landscape-view/fill", video: portraitVideo,
              frame: CGRect(x: 0, y: 0, width: 320, height: 180), layoutMode: .fill),
        .init(name: "square-video/landscape-view/fill", video: squareVideo,
              frame: CGRect(x: 0, y: 0, width: 320, height: 180), layoutMode: .fill),
        .init(name: "square-video/portrait-view/fit", video: squareVideo,
              frame: CGRect(x: 0, y: 0, width: 180, height: 320), layoutMode: .fit),
        // A view larger than the source: the clamp must not upscale the render target.
        .init(name: "small-video/large-view/fill",
              video: RendererProbe.Resolution(width: 320, height: 180),
              frame: CGRect(x: 0, y: 0, width: 800, height: 450), layoutMode: .fill),
    ]

    @Test(arguments: geometries)
    func clampPreservesAspectAndNeverUnderSamples(_ geometry: Geometry) async throws {
        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: geometry.video,
                                                      frame: geometry.frame,
                                                      layoutMode: geometry.layoutMode)
        defer { harness.tearDown() }

        let metalView = try #require(RendererProbe.metalView(in: harness.view))
        let drawable = metalView.drawableSize
        let scale = harness.view.currentScreenScale()

        let video = CGSize(width: CGFloat(geometry.video.width), height: CGFloat(geometry.video.height))
        // What the renderer actually occupies on screen. `.fill` makes this larger than the view.
        let rendererSize = try #require(harness.view._state.rendererSize)
        let displayed = CGSize(width: rendererSize.width * scale, height: rendererSize.height * scale)

        let videoAspect = video.width / video.height
        let drawableAspect = drawable.width / drawable.height

        print("[geometry] \(geometry.name) video=\(geometry.video.label) " +
            "view=\(Int(geometry.frame.width))x\(Int(geometry.frame.height)) scale=\(scale) " +
            "renderer=\(Int(rendererSize.width))x\(Int(rendererSize.height))pt " +
            "displayed=\(Int(displayed.width))x\(Int(displayed.height))px " +
            "drawable=\(Int(drawable.width))x\(Int(drawable.height))px " +
            "aspect video=\(String(format: "%.4f", videoAspect)) drawable=\(String(format: "%.4f", drawableAspect))")

        // 1. Aspect preserved, so the vertex/crop mapping and the rotation flip are untouched.
        #expect(abs(drawableAspect - videoAspect) / videoAspect < 0.01)

        // 2. Never under-sampled: at least what is displayed, unless the source is smaller.
        let floorWidth = min(video.width, displayed.width)
        let floorHeight = min(video.height, displayed.height)
        #expect(drawable.width >= floorWidth - 1)
        #expect(drawable.height >= floorHeight - 1)

        // 3. Never larger than either bound — that is the whole point of the change.
        #expect(drawable.width <= max(floorWidth, 1) + 1)
        #expect(drawable.height <= max(floorHeight, 1) + 1)
    }

    // MARK: - Dynamic resizing and lifecycle

    /// A tile growing to fullscreen and shrinking back must re-size the render target each way —
    /// growing so the image does not soften, shrinking so the memory is actually returned.
    @Test
    func drawableTracksViewResizeBothWays() async throws {
        let tile = CGRect(x: 0, y: 0, width: 320, height: 180)
        let fullscreen = CGRect(x: 0, y: 0, width: 1200, height: 675)

        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: Self.landscapeVideo,
                                                      frame: tile)
        defer { harness.tearDown() }
        let metalView = try #require(RendererProbe.metalView(in: harness.view))
        let scale = harness.view.currentScreenScale()

        let asTile = metalView.drawableSize
        try await harness.resize(to: fullscreen)
        let asFullscreen = metalView.drawableSize
        try await harness.resize(to: tile)
        let backToTile = metalView.drawableSize

        print("[resize] tile=\(Int(asTile.width))x\(Int(asTile.height)) " +
            "fullscreen=\(Int(asFullscreen.width))x\(Int(asFullscreen.height)) " +
            "back=\(Int(backToTile.width))x\(Int(backToTile.height)) scale=\(scale)")

        #expect(asFullscreen.width > asTile.width, "growing the view must grow the render target")
        #expect(backToTile == asTile, "shrinking must return the render target to its former size")
        // Still capped at the source resolution even when the view is bigger than it.
        #expect(asFullscreen.width <= CGFloat(Self.landscapeVideo.width))
    }

    /// An orientation change swaps the view's axes; the drawable must follow and keep the video's
    /// aspect rather than the view's.
    @Test
    func drawableFollowsOrientationChange() async throws {
        let portrait = CGRect(x: 0, y: 0, width: 390, height: 844)
        let landscape = CGRect(x: 0, y: 0, width: 844, height: 390)

        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: Self.landscapeVideo,
                                                      frame: portrait)
        defer { harness.tearDown() }
        let metalView = try #require(RendererProbe.metalView(in: harness.view))

        let inPortrait = metalView.drawableSize
        try await harness.resize(to: landscape)
        let inLandscape = metalView.drawableSize

        let videoAspect = CGFloat(Self.landscapeVideo.width) / CGFloat(Self.landscapeVideo.height)
        print("[orientation] portrait=\(Int(inPortrait.width))x\(Int(inPortrait.height)) " +
            "landscape=\(Int(inLandscape.width))x\(Int(inLandscape.height))")

        for size in [inPortrait, inLandscape] {
            #expect(abs((size.width / size.height) - videoAspect) / videoAspect < 0.01)
            #expect(size.width <= CGFloat(Self.landscapeVideo.width) + 1)
        }
    }

    /// A simulcast layer switch changes the source resolution under a fixed view. The render
    /// target must follow it down, and back up without exceeding the new source.
    @Test
    func drawableFollowsSourceResolutionChange() async throws {
        // Large enough that the source, not the view, is the binding constraint.
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 675)
        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: Self.landscapeVideo,
                                                      frame: frame)
        defer { harness.tearDown() }
        let metalView = try #require(RendererProbe.metalView(in: harness.view))

        let atFullHd = metalView.drawableSize
        try await harness.changeSourceResolution(to: RendererProbe.Resolution(width: 640, height: 360))
        let atLowLayer = metalView.drawableSize
        try await harness.changeSourceResolution(to: Self.landscapeVideo)
        let backToFullHd = metalView.drawableSize

        print("[source] 1080p=\(Int(atFullHd.width))x\(Int(atFullHd.height)) " +
            "360p=\(Int(atLowLayer.width))x\(Int(atLowLayer.height)) " +
            "back=\(Int(backToFullHd.width))x\(Int(backToFullHd.height))")

        #expect(atLowLayer.width < atFullHd.width, "dropping a layer must shrink the render target")
        #expect(atLowLayer.width <= 640 + 1, "must not render above the new source resolution")
        #expect(backToFullHd.width > atLowLayer.width, "returning to 1080p must grow it back")
    }

    /// Switching render mode recreates the native renderer. The old `MTKView` — and with it the
    /// old drawable pool — has to be released, or every switch would ratchet memory up.
    @Test
    func recreatingTheRendererReleasesTheOldDrawablePool() async throws {
        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: Self.landscapeVideo)
        defer { harness.tearDown() }

        weak var oldMetalView = RendererProbe.metalView(in: harness.view)
        weak var oldLayer = oldMetalView?.layer
        try #require(oldMetalView != nil)
        let oldDrawableSize = try #require(oldMetalView?.drawableSize)

        // Force a renderer swap.
        harness.view.renderMode = .sampleBuffer
        try await RendererProbe.pollOnMain(for: "metal renderer torn down") { [view = harness.view] in
            RendererProbe.metalView(in: view) == nil
        }
        try await RendererProbe.quiesce()

        print("[lifecycle] old drawable was \(Int(oldDrawableSize.width))x\(Int(oldDrawableSize.height)); " +
            "after swap metalView=\(oldMetalView == nil ? "released" : "RETAINED") " +
            "layer=\(oldLayer == nil ? "released" : "RETAINED")")

        #expect(oldMetalView == nil, "old MTKView leaked; its drawable pool is still resident")
        #expect(oldLayer == nil, "old CAMetalLayer leaked; its drawable pool is still resident")

        // And back again, to confirm the swap is symmetric.
        harness.view.renderMode = .metal
        try await RendererProbe.pollOnMain(for: "metal renderer recreated") { [view = harness.view] in
            RendererProbe.metalView(in: view) != nil
        }
        try await harness.prime()
        let recreated = try #require(RendererProbe.metalView(in: harness.view)?.drawableSize)
        #expect(recreated == oldDrawableSize, "a recreated renderer must land on the same size")
    }

    /// Reusing one view across tracks is supported, so nothing derived from the outgoing track may
    /// outlive it. The native size is the risk: a remote track learns it from
    /// `VideoRendererAdapter.setSize`, but a local capturer never calls that, so a stale value
    /// would stick and size the new track's renderer from the old track's resolution.
    @Test
    func switchingTracksDoesNotCarryTheOldNativeSize() async throws {
        // Big enough that the source, not the view, decides the drawable.
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 675)
        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: Self.landscapeVideo,
                                                      frame: frame)
        defer { harness.tearDown() }
        let metalView = try #require(RendererProbe.metalView(in: harness.view))
        let atFullHd = metalView.drawableSize

        // Stand in for a remote track reporting a much smaller layer.
        harness.view.set(size: CGSize(width: 320, height: 180))
        try await RendererProbe.pollOnMain(for: "small size applied") { metalView.drawableSize != atFullHd }
        let atSmallRemote = metalView.drawableSize

        // Now hand the same view a different track, as a UI reusing a cell would.
        let replacement = try await RendererProbe.Harness(renderMode: .metal,
                                                          resolution: Self.landscapeVideo,
                                                          frame: frame)
        defer { replacement.tearDown() }
        harness.view.track = replacement.track
        // The sink is swapped on the RTC executor and the renderer rebuilt on the main actor.
        await RTC.run {}
        await Task { @MainActor in }.value

        // Frames now come from the replacement's capturer; drive the reused view off them.
        for _ in 0 ..< 8 {
            try await replacement.captureAndDrawWithoutLayout()
            harness.layOut()
            RendererProbe.metalView(in: harness.view)?.draw()
        }
        // The renderer is recreated on a track change, so the old MTKView reference is stale.
        let afterSwitch = try #require(RendererProbe.metalView(in: harness.view)).drawableSize

        print("[switch] 1080p=\(Int(atFullHd.width))x\(Int(atFullHd.height)) " +
            "after-small-remote=\(Int(atSmallRemote.width))x\(Int(atSmallRemote.height)) " +
            "after-track-switch=\(Int(afterSwitch.width))x\(Int(afterSwitch.height))")

        #expect(atSmallRemote.width < atFullHd.width, "control: the small size must take effect")
        #expect(afterSwitch == atFullHd,
                "new track rendered at the previous track's size (\(Int(afterSwitch.width))px)")
    }

    /// A 90°-rotated stream is displayed with its axes swapped. The adapter reports the rotated
    /// size and `render(frame:)` applies rotation before updating the track, so both sides of the
    /// clamp are in display orientation — a drawable sized off the unrotated axes would be ~3x
    /// larger than needed on one of them.
    @Test(arguments: [VideoRotation._90, ._270])
    func rotatedFramesDoNotOversizeTheDrawable(_ rotation: VideoRotation) async throws {
        // Landscape buffer, rotated into a portrait viewport.
        let frame = CGRect(x: 0, y: 0, width: 180, height: 320)
        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: Self.landscapeVideo,
                                                      frame: frame,
                                                      rotation: rotation)
        defer { harness.tearDown() }

        let metalView = try #require(RendererProbe.metalView(in: harness.view))
        let drawable = metalView.drawableSize
        let scale = harness.view.currentScreenScale()
        let rendererSize = try #require(harness.view._state.rendererSize)
        let displayed = CGSize(width: rendererSize.width * scale, height: rendererSize.height * scale)

        // Rotated by a quarter turn, so the displayed aspect is the source's inverted.
        let displayedAspect = CGFloat(Self.landscapeVideo.height) / CGFloat(Self.landscapeVideo.width)
        print("[rotation] \(rotation) drawable=\(Int(drawable.width))x\(Int(drawable.height)) " +
            "displayed=\(Int(displayed.width))x\(Int(displayed.height)) " +
            "aspect=\(String(format: "%.4f", drawable.width / drawable.height))")

        #expect(abs((drawable.width / drawable.height) - displayedAspect) / displayedAspect < 0.01)
        #expect(drawable.width <= displayed.width + 1, "drawable wider than the rotated display")
        #expect(drawable.height <= displayed.height + 1, "drawable taller than the rotated display")
    }

    /// Detaching the track tears the renderer down entirely; nothing may survive it.
    @Test
    func detachingTheTrackReleasesTheRenderer() async throws {
        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: Self.landscapeVideo)
        weak var metalView = RendererProbe.metalView(in: harness.view)
        weak var layer = metalView?.layer
        try #require(metalView != nil)

        harness.view.track = nil
        try await poll(for: "renderer torn down") { [view = harness.view] in view.subviews.isEmpty }
        try await RendererProbe.quiesce()

        #expect(metalView == nil)
        #expect(layer == nil)
    }
}
#endif
