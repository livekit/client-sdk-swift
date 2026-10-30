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

/// Tests whether the Metal renderer pins decoded frames.
///
/// `RTCMTLNV12Renderer` creates a `CVMetalTextureCache` and never calls `CVMetalTextureCacheFlush`
/// — the symbol is absent from the shipped framework's import table entirely. That is suggestive,
/// but on its own it proves nothing: the cache ages entries out internally, and a renderer that
/// holds only the current frame is perfectly well behaved.
///
/// So this measures the thing that actually matters to a running app. Frames are allocated from a
/// `CVPixelBufferPool` with a hard allocation threshold — the same shape as a
/// `VTDecompressionSession`'s output pool. If the renderer releases each frame once it is done,
/// the pool recycles and allocation never fails no matter how many frames go through. If the
/// renderer accumulates frames, the pool is exhausted and allocation starts failing with
/// `kCVReturnWouldExceedAllocationThreshold`, which is exactly how a real decoder starves.
@Suite(.tags(.media), .serialized)
@MainActor
struct VideoViewFrameRetentionTests {
    /// Enough headroom for the frames legitimately in flight between the capturer and the
    /// renderer, which on a loaded machine is more than the two or three a quiet one needs.
    /// Accumulation still blows through twelve long before 60 frames are pushed.
    static let poolThreshold = 12
    static let framesPushed = 60

    nonisolated static let resolution = RendererProbe.Resolution(width: 1920, height: 1080)

    nonisolated static let renderModes: [VideoView.RenderMode] = [.metal, .sampleBuffer]

    @Test(arguments: renderModes)
    func rendererReleasesFramesBackToThePool(_ renderMode: VideoView.RenderMode) async throws {
        let harness = try await RendererProbe.Harness(renderMode: renderMode, resolution: Self.resolution)
        defer { harness.tearDown() }

        let pool = try Self.makePool(Self.resolution)
        var transient = 0
        var unrecoverable = 0
        var firstFailureAt: Int?

        for index in 0 ..< Self.framesPushed {
            // Scoped so our own reference is gone before the next allocation is attempted; the
            // only thing that can still be holding it is the renderer.
            var buffer = Self.allocate(from: pool, threshold: Self.poolThreshold)

            if buffer == nil {
                // Exhaustion on its own does not mean the renderer is accumulating: delivery is
                // asynchronous, so several frames can be in flight at once on a busy machine.
                // Let those drain and try again. A renderer that actually holds frames will not
                // give them back, so the retry still fails and the count below is what trips.
                transient += 1
                if firstFailureAt == nil { firstFailureAt = index }
                try await RendererProbe.quiesce()
                buffer = Self.allocate(from: pool, threshold: Self.poolThreshold)
            }

            guard let buffer else {
                unrecoverable += 1
                continue
            }
            try await harness.captureAndDraw(buffer)
        }

        let mode = renderMode == .metal ? ".metal" : ".sampleBuffer"
        print("[retention] \(mode) pushed=\(Self.framesPushed) poolThreshold=\(Self.poolThreshold) " +
            "transient=\(transient) unrecoverable=\(unrecoverable) " +
            "firstFailureAt=\(firstFailureAt.map(String.init) ?? "none")")

        #expect(unrecoverable == 0,
                "renderer held \(Self.poolThreshold) buffers through a drain, first starved at frame \(firstFailureAt ?? -1)")
    }

    /// How many buffers the renderer is holding once it has settled, measured by draining the pool
    /// dry and counting what it will still hand out.
    @Test(arguments: renderModes)
    func steadyStateRetentionIsBounded(_ renderMode: VideoView.RenderMode) async throws {
        let harness = try await RendererProbe.Harness(renderMode: renderMode, resolution: Self.resolution)
        defer { harness.tearDown() }

        let capacity = 16
        let pool = try Self.makePool(Self.resolution)

        // Run frames through until behaviour is steady.
        for _ in 0 ..< 30 {
            if let buffer = Self.allocate(from: pool, threshold: capacity) {
                try await harness.captureAndDraw(buffer)
            }
        }
        try await RendererProbe.quiesce()

        // Drain: whatever the pool still yields is what the renderer is not holding.
        var drained: [CVPixelBuffer] = []
        while drained.count < capacity, let buffer = Self.allocate(from: pool, threshold: capacity) {
            drained.append(buffer)
        }
        let heldByRenderer = capacity - drained.count

        let mode = renderMode == .metal ? ".metal" : ".sampleBuffer"
        print("[retention] \(mode) steady-state: pool capacity \(capacity), " +
            "drained \(drained.count), held by renderer \(heldByRenderer) " +
            "(\(RendererProbe.mb(Int64(heldByRenderer) * Self.resolution.nv12Bytes)) MB)")

        // A renderer legitimately holds the frame it is showing and the one just handed to it.
        // More than a handful means frames are piling up.
        #expect(heldByRenderer <= 4, "renderer is holding \(heldByRenderer) frames")
    }

    // MARK: - Pool helpers

    private static func makePool(_ resolution: RendererProbe.Resolution) throws -> CVPixelBufferPool {
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferWidthKey: Int(resolution.width),
            kCVPixelBufferHeightKey: Int(resolution.height),
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             nil,
                                             pixelBufferAttributes as CFDictionary,
                                             &pool)
        try #require(status == kCVReturnSuccess, "CVPixelBufferPoolCreate failed: \(status)")
        return try #require(pool)
    }

    /// Allocates with a hard ceiling, the way a decoder's pool behaves under pressure. Returns
    /// `nil` once the ceiling is hit rather than growing without bound.
    private static func allocate(from pool: CVPixelBufferPool, threshold: Int) -> CVPixelBuffer? {
        let auxAttributes: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: threshold,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
                                                                         pool,
                                                                         auxAttributes as CFDictionary,
                                                                         &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}
#endif
