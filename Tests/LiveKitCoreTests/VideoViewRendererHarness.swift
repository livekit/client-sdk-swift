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
import Darwin
import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

#if os(iOS) || os(macOS)
import MetalKit

/// Fixtures and measurement plumbing for ``VideoViewRendererMemoryTests``.
enum RendererProbe {
    struct Resolution: Sendable, CustomTestStringConvertible {
        let width: Int32
        let height: Int32

        var label: String { "\(width)x\(height)" }
        var testDescription: String { label }

        /// Bytes one BGRA8 drawable occupies at this resolution.
        var drawableBytes: Int64 { Int64(width) * Int64(height) * 4 }
        /// Bytes one NV12 (4:2:0 bi-planar) frame occupies at this resolution.
        var nv12Bytes: Int64 { Int64(width) * Int64(height) * 3 / 2 }
    }

    static let resolutions = [
        Resolution(width: 1920, height: 1080),
        Resolution(width: 1280, height: 720),
        Resolution(width: 960, height: 540),
        Resolution(width: 640, height: 360),
    ]

    /// The reported setup: 1080p H.264, which VideoToolbox emits as NV12.
    static let reported = resolutions[0]

    /// Views built per measurement. Enough that one-off Metal costs (device, shader library,
    /// command queue) and sampling noise are small next to the per-view term.
    static let viewsPerSample = 8

    /// Deliberately much smaller than any of the video resolutions, to show the renderer's
    /// allocation does not track it.
    static let viewFrame = CGRect(x: 0, y: 0, width: 320, height: 180)

    // MARK: - Harness

    /// What the synthetic source frame contains.
    enum Pattern: Sendable {
        /// Smooth gradients — stands in for ordinary video, where most energy is low-frequency.
        case gradient
        /// Gradients plus an 8px checkerboard: near-Nyquist detail, the worst case for any
        /// resampling change. Real H.264 rarely carries this much high-frequency energy.
        case checkerboard
    }

    /// One `VideoView` wired to a local buffer track, primed until its native renderer exists and
    /// has drawn.
    @MainActor
    final class Harness {
        let track: LocalVideoTrack
        let view: VideoView
        private let capturer: BufferCapturer
        private var pixelBuffer: CVPixelBuffer
        /// Applied to every capture, so a rotated stream can be exercised end to end.
        private var rotation: VideoRotation = ._0

        init(renderMode: VideoView.RenderMode,
             resolution: Resolution,
             frame: CGRect = viewFrame,
             layoutMode: VideoView.LayoutMode = .fill,
             pattern: Pattern = .checkerboard,
             rotation: VideoRotation = ._0,
             rotationOverride: VideoRotation? = nil) async throws
        {
            track = await LocalVideoTrack.createBufferTrack(name: "memory", source: .camera)
            capturer = try #require(track.capturer as? BufferCapturer)
            pixelBuffer = try Self.makePixelBuffer(resolution, pattern: pattern)
            self.rotation = rotation

            view = VideoView(frame: frame)
            view.renderMode = renderMode
            view.layoutMode = layoutMode
            view.rotationOverride = rotationOverride
            view.track = track

            // The native renderer is created on a main-actor hop off the state mutation.
            try await RendererProbe.pollOnMain(for: "native renderer created") { [view] in
                !view.subviews.isEmpty
            }

            // WebRTC's `VideoRendererAdapter` calls `setSize:` with the frame's dimensions, rotated
            // by the frame's rotation, on every size change. The local `BufferCapturer` path only
            // calls `render(frame:)`, so drive it explicitly to match a subscribed remote track.
            view.set(size: RendererProbe.adapterSize(resolution, rotation: rotation))

            try await prime()
        }

        /// Feeds frames and forces draws until the drawable pool is fully realised. `drawInMTKView:`
        /// skips a frame whose `timeStampNs` it already drew, so each draw needs a fresh capture.
        func prime() async throws {
            for _ in 0 ..< 6 {
                capturer.capture(pixelBuffer, rotation: rotation)
                try await Task.sleep(nanoseconds: 20_000_000)
                layOut()
                RendererProbe.metalView(in: view)?.draw()
            }
            try await poll(for: "first frame rendered") { [view] in view.didRenderFirstFrame }
        }

        /// Pushes one caller-owned buffer through the capturer and draws it, so the caller controls
        /// the buffer's lifetime rather than the harness.
        func captureAndDraw(_ buffer: CVPixelBuffer) async throws {
            capturer.capture(buffer, rotation: rotation)
            try await Task.sleep(nanoseconds: 8_000_000)
            layOut()
            RendererProbe.metalView(in: view)?.draw()
        }

        /// Captures and draws without a layout pass, so a `drawableSize` the caller forced on the
        /// `MTKView` survives — `-layoutSubviews` would recompute it from `videoFrameSize`. The
        /// capture still stamps a fresh `timeStampNs`, which is what stops `drawInMTKView:` from
        /// skipping the frame as a duplicate.
        /// Returns the time spent inside `draw()` alone, so callers can time rendering without the
        /// delivery sleep in the measurement.
        @discardableResult
        func captureAndDrawWithoutLayout() async throws -> TimeInterval {
            capturer.capture(pixelBuffer, rotation: rotation)
            try await Task.sleep(nanoseconds: 8_000_000)
            let started = CFAbsoluteTimeGetCurrent()
            RendererProbe.metalView(in: view)?.draw()
            return CFAbsoluteTimeGetCurrent() - started
        }

        func layOut() {
            #if os(macOS)
            view.layoutSubtreeIfNeeded()
            #else
            view.setNeedsLayout()
            view.layoutIfNeeded()
            #endif
        }

        /// Resizes the hosting view, as a tile growing to fullscreen or an orientation change would.
        func resize(to frame: CGRect) async throws {
            view.frame = frame
            layOut()
            try await prime()
        }

        /// Switches the source to a different resolution, as a simulcast layer change would.
        func changeSourceResolution(to resolution: Resolution) async throws {
            pixelBuffer = try Self.makePixelBuffer(resolution, pattern: .checkerboard)
            view.set(size: RendererProbe.adapterSize(resolution, rotation: rotation))
            try await prime()
        }

        func tearDown() {
            view.track = nil
            view.removeFromSuperview()
        }

        static func makePixelBuffer(_ resolution: Resolution, pattern: Pattern = .checkerboard) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            // NV12 full range: what VideoToolbox hands back for H.264.
            let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                             Int(resolution.width),
                                             Int(resolution.height),
                                             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                             attributes as CFDictionary,
                                             &buffer)
            try #require(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
            let pixelBuffer = try #require(buffer)
            RendererProbe.fillWithTestPattern(pixelBuffer, pattern: pattern)
            return pixelBuffer
        }
    }

    // MARK: - Sampling

    struct Row {
        let renderMode: VideoView.RenderMode
        let resolution: Resolution
        let perViewBytes: Int64
        let reclaimedBytes: Int64
        let drawableSize: CGSize?
        let maximumDrawableCount: Int?
    }

    @MainActor
    static func sample(renderMode: VideoView.RenderMode, resolution: Resolution) async throws -> Row {
        try await quiesce()
        let baseline = physFootprint()

        var harnesses: [Harness] = []
        for _ in 0 ..< viewsPerSample {
            try await harnesses.append(Harness(renderMode: renderMode, resolution: resolution))
        }
        try await quiesce()
        let peak = physFootprint()

        // Spelled out rather than `.first.flatMap`: on Swift 6.1 that resolves `first` to the
        // `first(where:)` overload, which has no `flatMap`.
        var metalView: MTKView?
        if let firstHarness = harnesses.first {
            metalView = RendererProbe.metalView(in: firstHarness.view)
        }
        let drawableSize = metalView?.drawableSize
        let maximumDrawableCount = (metalView?.layer as? CAMetalLayer)?.maximumDrawableCount

        for harness in harnesses {
            harness.tearDown()
        }
        harnesses.removeAll()
        try await quiesce()
        let settled = physFootprint()

        return Row(renderMode: renderMode,
                   resolution: resolution,
                   perViewBytes: (peak - baseline) / Int64(viewsPerSample),
                   reclaimedBytes: (peak - settled) / Int64(viewsPerSample),
                   drawableSize: drawableSize,
                   maximumDrawableCount: maximumDrawableCount)
    }

    /// ``poll(timeout:interval:for:until:)`` takes a nonisolated condition; view-hierarchy checks
    /// have to run on the main actor, so this is the main-actor-bound equivalent.
    @MainActor
    static func pollOnMain(timeout: TimeInterval = 2,
                           interval: TimeInterval = 0.005,
                           for description: String,
                           until condition: () -> Bool) async throws
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        guard condition() else {
            throw MainActorPollTimeout(description: "timed out waiting for: \(description)")
        }
    }

    struct MainActorPollTimeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Lets deferred teardown (`RTC.park` releases, autorelease pools, CA transactions) land before
    /// the footprint is read.
    static func quiesce() async throws {
        for _ in 0 ..< 3 {
            await RTC.run {}
            await Task { @MainActor in }.value
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// The `MTKView` lives inside the `RTCMTLVideoView` the ``VideoView`` hosts, so it is two
    /// levels down; `findMTKView()` only looks at direct subviews.
    @MainActor
    static func metalView(in view: NativeViewType) -> MTKView? {
        if let metalView = view as? MTKView { return metalView }
        for subview in view.subviews {
            if let found = metalView(in: subview) { return found }
        }
        return nil
    }

    static func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    // MARK: - Reporting

    /// Records which renderer `.auto` actually picks here, so a run on a host that diverges from a
    /// real device cannot be mistaken for one that does not.
    @MainActor
    static func reportEnvironment() {
        let resolved = VideoView.shouldAvoidMetalRenderer ? ".sampleBuffer" : ".metal"
        print("")
        print("[env] isMetalAvailable=\(VideoView.isMetalAvailable()) " +
            "shouldAvoidMetalRenderer=\(VideoView.shouldAvoidMetalRenderer) -> .auto resolves to \(resolved)")
        #if targetEnvironment(simulator)
        print("[env] SIMULATOR: GPU is the host's; `.auto` diverges from a real A14+ iPhone, " +
            "so the rows below force `.metal` explicitly.")
        #endif
    }

    static func report(_ rows: [Row]) {
        func pad(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
        }
        func padLeft(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
        }

        print("")
        print("=== VideoView renderer footprint (decoder excluded, \(viewsPerSample) views per sample) ===")
        print("view frame: \(Int(viewFrame.width))x\(Int(viewFrame.height)) for every row")
        print("")
        let header = pad("mode", 15) + pad("video", 12) + pad("drawableSize", 14) + padLeft("maxDraw", 8) +
            padLeft("drawables MB", 14) + padLeft("footprint MB", 14) + padLeft("reclaimed MB", 14)
        print(header)
        print(String(repeating: "-", count: header.count))
        for row in rows {
            let mode = row.renderMode == .metal ? ".metal" : ".sampleBuffer"
            let drawable = row.drawableSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "n/a"
            let maxDrawable = row.maximumDrawableCount.map(String.init) ?? "n/a"
            var drawablesMB = "n/a"
            if let size = row.drawableSize, let count = row.maximumDrawableCount {
                drawablesMB = mb(Int64(size.width * size.height) * 4 * Int64(count))
            }
            print(pad(mode, 15) + pad(row.resolution.label, 12) + pad(drawable, 14) +
                padLeft(maxDrawable, 8) + padLeft(drawablesMB, 14) +
                padLeft(mb(row.perViewBytes), 14) + padLeft(mb(row.reclaimedBytes), 14))
        }
        print("")
        print("drawables MB = drawableSize.w * drawableSize.h * 4 (BGRA8) * maximumDrawableCount")
        print("             = what CAMetalLayer must allocate, by construction")
        print("footprint MB = measured phys_footprint delta per view")
        print("NV12 frame at 1920x1080 = \(mb(reported.nv12Bytes)) MB (what was measured as '<4 MB')")
        print("")
    }
}

extension RendererProbe {
    /// The size `VideoRendererAdapter` passes to `setSize:`: the frame's dimensions, rotated by
    /// the frame's rotation.
    static func adapterSize(_ resolution: Resolution, rotation: VideoRotation) -> CGSize {
        let size = CGSize(width: CGFloat(resolution.width), height: CGFloat(resolution.height))
        switch rotation {
        case ._90, ._270: return CGSize(width: size.height, height: size.width)
        default: return size
        }
    }
}
#endif
