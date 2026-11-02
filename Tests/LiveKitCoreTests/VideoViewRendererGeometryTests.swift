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
        // is larger than the view in the first case, which is why the clamp works from the
        // renderer's bounds and not the `VideoView`'s.
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
}
#endif
