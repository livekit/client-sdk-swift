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

import Foundation
@testable import LiveKit
import LiveKitWebRTC
import Testing

/// Emulates a capturer whose device-level start work fails after
/// `super.startCapture()` has already transitioned the state to `.started`,
/// using the same balancing pattern as the built-in capturers.
private final class StartFailingCapturer: VideoCapturer, @unchecked Sendable {
    override func startCapture() async throws -> Bool {
        do {
            let didStart = try await super.startCapture()
            guard didStart else { return false }
            throw LiveKitError(.invalidState, message: "Simulated device failure")
        } catch {
            try? await stopCapture()
            throw error
        }
    }
}

private final class NullCapturerDelegate: NSObject, LKRTCVideoCapturerDelegate {
    func capturer(_: LKRTCVideoCapturer, didCapture _: LKRTCVideoFrame) {}
}

@Suite(.tags(.media))
struct VideoCapturerStartFailureTests {
    @Test func startFailureLeavesCapturerStopped() async throws {
        let capturer = StartFailingCapturer(delegate: NullCapturerDelegate())
        #expect(capturer.captureState == .stopped)

        await #expect(throws: LiveKitError.self) {
            try await capturer.startCapture()
        }
        // Without balancing the counter stays at 1: the capturer reports
        // `.started` while nothing is capturing.
        #expect(capturer.captureState == .stopped)
    }

    @Test func startCanRetryAfterFailure() async throws {
        let capturer = StartFailingCapturer(delegate: NullCapturerDelegate())

        await #expect(throws: LiveKitError.self) {
            try await capturer.startCapture()
        }
        // Without balancing this second call would return `false` early
        // ("already started") instead of reaching the subclass again.
        await #expect(throws: LiveKitError.self) {
            try await capturer.startCapture()
        }
        #expect(capturer.captureState == .stopped)
    }
}
