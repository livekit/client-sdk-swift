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

/// After a burst of `track` / `isEnabled` writes, the sink a ``VideoView`` holds on a track and the
/// native renderer it hosts must both match the last write, never an earlier one. Headless: local
/// buffer tracks, no room, no server. Ported from the reporter's standalone probe.
///
/// Serialized because the scenarios stress the process-wide RTC executor; interleaving them would
/// blur which burst a failure belongs to.
@Suite(.tags(.media, .concurrency), .serialized,
       .bug("https://github.com/livekit/client-sdk-swift/issues/1139"))
@MainActor
struct VideoViewBindingTests {
    enum Scenario: CaseIterable {
        /// (disable, enable) pairs, ending enabled on A.
        case enable
        /// (disable, enable) pairs, then disable.
        case disable
        /// (A, B) pairs, ending on B.
        case replace
        /// (A, B) pairs, then nil.
        case teardown
    }

    /// What the view is bound to, read from the track side and from the view hierarchy.
    struct RendererBinding: Equatable, CustomTestStringConvertible {
        var feedsFromA: Bool
        var feedsFromB: Bool
        var hasRenderer: Bool

        static let a = RendererBinding(feedsFromA: true, feedsFromB: false, hasRenderer: true)
        static let b = RendererBinding(feedsFromA: false, feedsFromB: true, hasRenderer: true)
        static let none = RendererBinding(feedsFromA: false, feedsFromB: false, hasRenderer: false)

        var testDescription: String {
            "sinkA=\(feedsFromA) sinkB=\(feedsFromB) renderer=\(hasRenderer)"
        }
    }

    // 20 bursts were not enough to reproduce the original race; 100 caught it in every run.
    private static let bursts = 100
    private static let pairsPerBurst = 50

    @Test(arguments: Scenario.allCases)
    func bindingMatchesLastWrite(_ scenario: Scenario) async throws {
        let a = await LocalVideoTrack.createBufferTrack(name: "a", source: .camera)
        let b = await LocalVideoTrack.createBufferTrack(name: "b", source: .camera)
        let view = VideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))

        // Positive control: the sink attaches and frames reach the view.
        view.track = a
        let baseline = await Self.binding(of: view, a, b)
        try #require(baseline == .a)
        try await Self.feedFrames(to: a)
        try await poll(for: "frames reach the view") { view.isRendering }

        for burst in 0 ..< Self.bursts {
            view.isEnabled = true
            view.track = a
            let reset = await Self.binding(of: view, a, b)
            try #require(reset == .a, "burst \(burst) reset")

            for _ in 0 ..< Self.pairsPerBurst {
                switch scenario {
                case .enable, .disable:
                    view.isEnabled = false
                    view.isEnabled = true
                case .replace, .teardown:
                    view.track = a
                    view.track = b
                }
            }
            if scenario == .disable { view.isEnabled = false }
            if scenario == .teardown { view.track = nil }

            let expected: RendererBinding = switch scenario {
            case .enable: .a
            case .replace: .b
            case .disable, .teardown: .none
            }
            let settled = await Self.binding(of: view, a, b)
            try #require(settled == expected, "burst \(burst)")
        }

        view.track = nil
        let afterTeardown = await Self.binding(of: view, a, b)
        #expect(afterTeardown == .none)
    }

    // MARK: - Helpers

    /// Reads the binding once every attach/detach and renderer update queued so far has run.
    /// Attach/detach jobs land on the RTC executor's serial queue as they are requested, and
    /// renderer updates on the main actor in creation order (SE-0431), so one hop onto each, made
    /// after the writes, is queued behind all of them.
    private static func binding(of view: VideoView, _ a: LocalVideoTrack, _ b: LocalVideoTrack) async -> RendererBinding {
        await RTC.run {}
        await Task { @MainActor in }.value
        return RendererBinding(feedsFromA: isAttached(view, to: a),
                               feedsFromB: isAttached(view, to: b),
                               hasRenderer: !view.subviews.isEmpty)
    }

    private nonisolated static func isAttached(_ view: VideoView, to track: LocalVideoTrack) -> Bool {
        track.capturer.rendererDelegates.allDelegates.contains { $0 as AnyObject === view }
    }

    private static func feedFrames(to track: LocalVideoTrack, count: Int = 3) async throws {
        let capturer = try #require(track.capturer as? BufferCapturer)
        let buffer = try makePixelBuffer()
        for _ in 0 ..< count {
            capturer.capture(buffer)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return try #require(buffer)
    }
}
