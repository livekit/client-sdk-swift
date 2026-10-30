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

/// How the render target follows the things that change under a live view: the view's own size,
/// the device orientation, the source resolution, and the track itself. Each of these rebuilds or
/// re-sizes the renderer, and each is a chance to strand an oversized drawable pool.
///
/// Static geometry — aspect ratio across fit/fill and orientation — lives in
/// VideoViewRendererGeometryTests.
@Suite(.tags(.media), .serialized)
@MainActor
struct VideoViewRendererLifecycleTests {
    nonisolated static let landscapeVideo = RendererProbe.Resolution(width: 1920, height: 1080)

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

    /// `rotationOverride` is applied by the renderer, which swaps the axes of the size it was given
    /// when the override and the frame's own rotation disagree. So the size it gets has to be in the
    /// frame's orientation, as `VideoRendererAdapter` reports it, or the axes get swapped twice.
    @Test(arguments: [VideoRotation._90, ._270])
    func rotationOverrideKeepsTheDrawableInDisplayOrientation(_ rotationOverride: VideoRotation) async throws {
        // Landscape frames with no rotation of their own, turned into a portrait viewport.
        let frame = CGRect(x: 0, y: 0, width: 180, height: 320)
        let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                      resolution: Self.landscapeVideo,
                                                      frame: frame,
                                                      rotationOverride: rotationOverride)
        defer { harness.tearDown() }

        let drawable = try #require(RendererProbe.metalView(in: harness.view)).drawableSize
        let displayedAspect = CGFloat(Self.landscapeVideo.height) / CGFloat(Self.landscapeVideo.width)
        print("[override] \(rotationOverride) drawable=\(Int(drawable.width))x\(Int(drawable.height))")

        #expect(abs((drawable.width / drawable.height) - displayedAspect) / displayedAspect < 0.01,
                "drawable is not in the overridden orientation")
    }

    /// Switching to a track whose capture has stopped: `reconcileNativeRenderer` replays the
    /// track's cached frame straight into the new renderer, bypassing `render(frame:)`. With the
    /// native size cleared by the switch there is nothing to size the render target from, and no
    /// further frame arrives to correct it.
    /// Both directions matter. A fresh `MTKView` still has `autoResizeDrawable = YES` — WebRTC
    /// only clears it inside `addRenderingDestination:`, which runs lazily on the first draw — so
    /// an unsized renderer auto-sizes to `bounds x scale`. That happens to equal the clamp when
    /// the source is larger than the display, and to overshoot it enormously when it is smaller.
    struct CachedFrameCase: Sendable, CustomTestStringConvertible {
        let name: String
        let view: CGRect
        let source: RendererProbe.Resolution
        var testDescription: String { name }
    }

    // Both views are exactly 16:9, matching the sources. The clamp scales by the *larger* of the
    // two axis ratios so neither axis is under-sampled, which overshoots a per-axis minimum by a
    // pixel or two when the aspects differ — real behaviour, but noise for this particular test.
    nonisolated static let cachedFrameCases: [CachedFrameCase] = [
        .init(name: "source-larger-than-view", view: CGRect(x: 0, y: 0, width: 128, height: 72),
              source: RendererProbe.Resolution(width: 1920, height: 1080)),
        .init(name: "source-smaller-than-view", view: CGRect(x: 0, y: 0, width: 1200, height: 675),
              source: RendererProbe.Resolution(width: 320, height: 180)),
    ]

    @Test(arguments: cachedFrameCases)
    func cachedFrameOnASwitchedToTrackIsSizedCorrectly(_ testCase: CachedFrameCase) async throws {
        let host = try await RendererProbe.Harness(renderMode: .metal,
                                                   resolution: RendererProbe.Resolution(width: 640, height: 360),
                                                   frame: testCase.view)
        defer { host.tearDown() }
        // Priming leaves a cached frame on this track, and capture then stops.
        let paused = try await RendererProbe.Harness(renderMode: .metal,
                                                     resolution: testCase.source,
                                                     frame: testCase.view)
        defer { paused.tearDown() }
        try #require(paused.track.videoFrame != nil, "precondition: the track must have a cached frame")

        // Switch, and deliberately deliver no further frames.
        host.view.track = paused.track
        await RTC.run {}
        await Task { @MainActor in }.value
        host.layOut()
        await Task { @MainActor in }.value

        let scale = host.view.currentScreenScale()
        let after = try #require(RendererProbe.metalView(in: host.view)).drawableSize
        let displayed = CGSize(width: testCase.view.width * scale, height: testCase.view.height * scale)
        let expected = CGSize(width: min(CGFloat(testCase.source.width), displayed.width),
                              height: min(CGFloat(testCase.source.height), displayed.height))

        print("[cached] \(testCase.name) view=\(Int(testCase.view.width))x\(Int(testCase.view.height))pt " +
            "source=\(testCase.source.label) displayed=\(Int(displayed.width))x\(Int(displayed.height))px " +
            "expected=\(Int(expected.width))x\(Int(expected.height)) " +
            "actual=\(Int(after.width))x\(Int(after.height))")

        #expect(abs(after.width - expected.width) <= 1,
                "cached frame rendered into a \(Int(after.width))px target, expected \(Int(expected.width))px")
        #expect(abs(after.height - expected.height) <= 1)
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
        // Detach is applied on the RTC executor, which by this point in a serialized suite has a
        // queue of teardowns behind it from earlier cases. The default 2s was marginal.
        try await RendererProbe.pollOnMain(timeout: 10, for: "renderer torn down") { [view = harness.view] in
            view.subviews.isEmpty
        }
        try await RendererProbe.quiesce()

        #expect(metalView == nil)
        #expect(layer == nil)
    }
}
#endif
