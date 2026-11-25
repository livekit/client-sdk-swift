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
@preconcurrency import LiveKitWebRTC
import Testing

/// This suite alone uses the process logger; helper tests inject their own independent emitters.
@Suite(.serialized)
struct MediaProducerTests {
    private final class Output: Logger, Sendable {
        let errors = StateSync(0)
        func log(_: @autoclosure () -> CustomStringConvertible, _ level: LogLevel,
                 source _: @autoclosure () -> String?, file _: StaticString, type _: Any.Type,
                 function _: StaticString, line _: UInt, metaData _: ScopedMetadataContainer)
        {
            if level == .error { errors.mutate { $0 += 1 } }
        }
    }

    private final class Frames: NSObject, LKRTCVideoCapturerDelegate {
        let count = StateSync(0)
        func capturer(_: LKRTCVideoCapturer, didCapture _: LKRTCVideoFrame) {
            count.mutate { $0 += 1 }
        }
    }

    private final class UnknownBuffer: NSObject, LKRTCVideoFrameBuffer {
        let width: Int32 = 16
        let height: Int32 = 16
        func toI420() -> any LKRTCI420BufferProtocol { LKRTCI420Buffer(width: width, height: height) }
    }

    @Test func captureConversionFailureHasOnlyOneCountedDiagnostic() {
        let output = Output()
        LiveKitSDK.setLogger(output)
        let frames = Frames()
        let native = LKRTCVideoCapturer(delegate: frames)
        let capturer = VideoCapturer(delegate: frames)
        let completed = DispatchSemaphore(value: 0)
        capturer._state.onDidMutate = { new, old in
            if old.isFrameProcessingBusy, !new.isFrameProcessingBusy { completed.signal() }
        }
        let frame = LKRTCVideoFrame(buffer: UnknownBuffer(), rotation: ._0, timeStampNs: 1)
        for _ in 0 ..< 20 {
            capturer.capture(frame: frame, capturer: native, options: BufferCaptureOptions())
            // Join the dedicated capture queue before submitting the next frame, without sleeps.
            #expect(completed.wait(timeout: .now() + 2) == .success)
        }
        #expect(frames.count.copy() == 0)
        #expect(output.errors.copy() == 1)
        // Other callers retain the converter's original diagnostic by default.
        #expect(frame.toLKType() == nil)
        #expect(output.errors.copy() == 2)
    }
}
