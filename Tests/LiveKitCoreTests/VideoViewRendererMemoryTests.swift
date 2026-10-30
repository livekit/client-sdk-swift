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

/// Measures what a ``VideoView``'s native renderer costs in resident memory, isolated from the
/// decoder.
///
/// Motivated by a report of ~250 MB per 1080p stream under `.auto` (Metal). Frames are fed
/// straight into the view from a local `BufferCapturer`, so no `VTDecompressionSession` and no
/// pixel buffer pool exist — whatever the footprint moves by is the renderer and nothing else.
/// That separation is the point: a measurement taken against a live subscription cannot tell the
/// renderer's surfaces apart from the decoder's pool.
///
/// Fixtures and plumbing live in ``RendererProbe``.
@Suite(.tags(.media), .serialized)
@MainActor
struct VideoViewRendererMemoryTests {
    // MARK: - The drawable-size law

    /// Left to itself, `RTCMTLVideoView` sizes its `CAMetalLayer` drawables from the *video* and
    /// then multiplies by the screen scale: upstream assigns `drawableSize = videoFrameSize`, and
    /// LiveKit's WebRTC fork scales that by `contentScaleFactor` ("Metal renderer scale factor",
    /// xcframework 125.6422.25, shipped by 05fc61bb). `autoResizeDrawable = NO`, so the view's own
    /// bounds never enter into it — a 320x180 view showing 1080p on a 3x screen would allocate
    /// 5760x3240 drawables, 324x the pixels it displays and ~214 MB of pool.
    ///
    /// ``VideoView`` now hands the renderer the displayed size instead, so the pool tracks what is
    /// on screen rather than what arrived on the wire.
    @Test(arguments: RendererProbe.resolutions)
    func drawableSizeIsClampedToDisplayedPixels(_ resolution: RendererProbe.Resolution) async throws {
        // `.metal`, not `.auto`: on a real A14+ iPhone `.auto` resolves to `.metal`, but the
        // Simulator reports no Apple-family-7 GPU so `shouldAvoidMetalRenderer` sends `.auto` down
        // the sample-buffer path. Asking for `.metal` measures the code the device actually runs.
        let harness = try await RendererProbe.Harness(renderMode: .metal, resolution: resolution)
        defer { harness.tearDown() }

        let metalView = try #require(RendererProbe.metalView(in: harness.view), "`.metal` produced no MTKView")
        let metalLayer = try #require(metalView.layer as? CAMetalLayer)
        let scale = harness.view.currentScreenScale()
        let drawable = metalView.drawableSize
        let viewFrame = RendererProbe.viewFrame

        let displayedPixels = CGSize(width: viewFrame.width * scale, height: viewFrame.height * scale)
        let videoPixels = CGSize(width: CGFloat(resolution.width), height: CGFloat(resolution.height))
        // Both the view and every resolution here are 16:9, so the clamp lands on the per-axis min.
        let expected = CGSize(width: min(videoPixels.width, displayedPixels.width),
                              height: min(videoPixels.height, displayedPixels.height))

        let poolBytes = Int64(drawable.width * drawable.height) * 4 * Int64(metalLayer.maximumDrawableCount)
        let unclampedPool = Int64(videoPixels.width * scale * videoPixels.height * scale) * 4 * 3
        print("[drawable] video=\(resolution.label) view=\(Int(viewFrame.width))x\(Int(viewFrame.height)) " +
            "scale=\(scale) drawableSize=\(Int(drawable.width))x\(Int(drawable.height)) " +
            "maxDrawables=\(metalLayer.maximumDrawableCount) " +
            "=> \(RendererProbe.mb(poolBytes)) MB of drawables per view " +
            "(was \(RendererProbe.mb(unclampedPool)) MB before the clamp)")

        // A pixel of tolerance per axis: the renderer re-multiplies by the screen scale.
        #expect(abs(drawable.width - expected.width) <= 1)
        #expect(abs(drawable.height - expected.height) <= 1)
    }

    /// The clamp in isolation, without a renderer in the way.
    @Test
    func rendererSizeClampPreservesAspectAndNeverUpscales() {
        let hd = CGSize(width: 1920, height: 1080)
        // The helper returns points; the renderer multiplies by the scale to get the drawable.
        func drawable(video: CGSize, displayed: CGSize?, scale: CGFloat) -> CGSize {
            let points = VideoView.rendererSize(forVideoSize: video, displayedSize: displayed, screenScale: scale)
            return CGSize(width: points.width * scale, height: points.height * scale)
        }

        // A 320x180 point view on a 3x screen displays 960x540 pixels; the drawable matches it.
        #expect(drawable(video: hd, displayed: CGSize(width: 320, height: 180), scale: 3) == CGSize(width: 960, height: 540))

        // A view larger than the video does not get a drawable bigger than the video.
        #expect(drawable(video: hd, displayed: CGSize(width: 1920, height: 1080), scale: 3) == hd)

        // Unknown geometry still caps at the video's native resolution.
        #expect(drawable(video: hd, displayed: nil, scale: 3) == hd)
        #expect(drawable(video: hd, displayed: .zero, scale: 3) == hd)

        // A degenerate scale is treated as 1 rather than dividing by zero.
        #expect(VideoView.rendererSize(forVideoSize: hd, displayedSize: nil, screenScale: 0) == hd)

        // Degenerate video size is passed through untouched.
        #expect(VideoView.rendererSize(forVideoSize: .zero,
                                       displayedSize: CGSize(width: 320, height: 180),
                                       screenScale: 3) == .zero)

        // Aspect ratio is preserved through the clamp.
        #expect(drawable(video: CGSize(width: 1080, height: 1920),
                         displayed: CGSize(width: 180, height: 320),
                         scale: 3) == CGSize(width: 540, height: 960))
    }

    // MARK: - Is the drawable pool real memory?

    /// `drawableSize` only states what the layer is configured to allocate. This forces the layer
    /// to actually vend its drawables, so the pool is priced from observation rather than from the
    /// BGRA8 arithmetic alone.
    @Test(arguments: RendererProbe.resolutions)
    func drawablePoolIsResidentMemory(_ resolution: RendererProbe.Resolution) async throws {
        let harness = try await RendererProbe.Harness(renderMode: .metal, resolution: resolution)
        defer { harness.tearDown() }

        let metalView = try #require(RendererProbe.metalView(in: harness.view))
        let metalLayer = try #require(metalView.layer as? CAMetalLayer)
        try await RendererProbe.quiesce()

        let before = RendererProbe.physFootprint()
        // Hold every drawable at once: releasing one would let the next reuse its surface.
        var held: [CAMetalDrawable] = []
        for _ in 0 ..< metalLayer.maximumDrawableCount {
            guard let drawable = metalLayer.nextDrawable() else { break }
            held.append(drawable)
        }
        let after = RendererProbe.physFootprint()

        let texture = held.first?.texture
        let perDrawable = texture.map { Int64($0.width * $0.height) * 4 } ?? 0
        print("[pool] video=\(resolution.label) vended=\(held.count)/\(metalLayer.maximumDrawableCount) " +
            "texture=\(texture.map { "\($0.width)x\($0.height)" } ?? "none") " +
            "perDrawable=\(RendererProbe.mb(perDrawable)) MB " +
            "expected=\(RendererProbe.mb(perDrawable * Int64(held.count))) MB " +
            "measured=\(RendererProbe.mb(after - before)) MB")

        // A headless macOS run has no display attached, so the layer vends nothing and there is
        // no pool to price. Not a failure — just an environment that cannot answer the question.
        guard let texture else {
            print("[pool] no drawables vended on this host; skipping (needs an attached display)")
            return
        }

        // The vended texture is the drawable, so its dimensions are the allocation, observed
        // rather than inferred.
        #expect(texture.width == Int(metalLayer.drawableSize.width))
        #expect(texture.height == Int(metalLayer.drawableSize.height))
        held.removeAll()
    }

    // MARK: - Footprint

    /// Prints resident-memory cost per renderer across resolutions and both render modes.
    @Test
    func rendererFootprint() async throws {
        RendererProbe.reportEnvironment()

        // Pay the one-time Metal costs (device, shader library, command queue) before any baseline.
        let warmUp = try await RendererProbe.Harness(renderMode: .metal, resolution: RendererProbe.reported)
        warmUp.tearDown()
        try await RendererProbe.quiesce()

        var rows: [RendererProbe.Row] = []
        for resolution in RendererProbe.resolutions {
            try await rows.append(RendererProbe.sample(renderMode: .metal, resolution: resolution))
        }
        // Control: the same stream through AVSampleBufferDisplayLayer.
        try await rows.append(RendererProbe.sample(renderMode: .sampleBuffer, resolution: RendererProbe.reported))

        RendererProbe.report(rows)

        let metal1080 = try #require(rows.first { $0.renderMode == .metal && $0.resolution.label == "1920x1080" })
        let size = try #require(metal1080.drawableSize)
        let count = try #require(metal1080.maximumDrawableCount)
        let drawables = Int64(size.width * size.height) * 4 * Int64(count)

        // With the clamp in place a 320x180 view must cost far less than the 1080p stream feeding
        // it. The pre-clamp pool was 213.6 MB on a 3x screen; the bar here is deliberately loose
        // so it holds at any screen scale.
        let videoSizedPool = metal1080.resolution.drawableBytes * Int64(count)
        let comparison = "\(RendererProbe.mb(drawables)) MB vs video-sized \(RendererProbe.mb(videoSizedPool)) MB"
        #expect(drawables < videoSizedPool, "drawable pool should be smaller: \(comparison)")
    }
}
#endif
