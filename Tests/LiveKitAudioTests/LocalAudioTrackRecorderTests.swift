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

import AVFAudio
@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class LocalAudioTrackRecorderTests: LKTestCase {
    func testRecording() async throws {
        let localTrack = LocalAudioTrack.createTrack(options: .noProcessing)

        let recorder = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatInt16,
            sampleRate: 48000
        )

        let stream = try await recorder.start()

        let expectation = expectation(description: "Received audio data")
        expectation.assertForOverFulfill = false

        let recordingTask = Task {
            var dataCount = 0
            var totalBytes = 0

            for await data in stream {
                dataCount += 1
                totalBytes += data.count

                if dataCount >= 10 {
                    expectation.fulfill()
                    break
                }
            }

            return (dataCount, totalBytes)
        }

        await fulfillment(of: [expectation], timeout: 5)

        recorder.stop()

        let (dataCount, totalBytes) = await recordingTask.value

        XCTAssertGreaterThan(dataCount, 0, "Should have received audio data")
        XCTAssertGreaterThan(totalBytes, 0, "Should have received non-empty audio data")
    }

    func testRecordingWithMaxBufferSize() async throws {
        let localTrack = LocalAudioTrack.createTrack(options: .noProcessing)

        let maxBufferSize = 5
        let recorder = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatInt16,
            sampleRate: 48000,
            maxSize: maxBufferSize
        )

        let stream = try await recorder.start()

        let expectation = expectation(description: "Received audio data")
        expectation.assertForOverFulfill = false

        let recordingTask = Task {
            var dataCount = 0

            for await _ in stream {
                dataCount += 1

                if dataCount >= maxBufferSize * 2 {
                    expectation.fulfill()
                    break
                }
            }

            return dataCount
        }

        await fulfillment(of: [expectation], timeout: 10)

        recorder.stop()

        let dataCount = await recordingTask.value

        XCTAssertGreaterThan(dataCount, 0, "Should have received audio data")
    }

    func testMultipleRecorders() async throws {
        let localTrack = LocalAudioTrack.createTrack(options: .noProcessing)

        let recorder1 = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatInt16,
            sampleRate: 48000
        )

        let recorder2 = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatFloat32,
            sampleRate: 16000
        )

        let stream1 = try await recorder1.start()
        let stream2 = try await recorder2.start()

        let expectation1 = expectation(description: "Received audio data from recorder1")
        let expectation2 = expectation(description: "Received audio data from recorder2")
        expectation1.assertForOverFulfill = false
        expectation2.assertForOverFulfill = false

        let task1 = Task {
            var dataCount = 0

            for await _ in stream1 {
                dataCount += 1
                if dataCount >= 10 {
                    expectation1.fulfill()
                    break
                }
            }

            return dataCount
        }

        let task2 = Task {
            var dataCount = 0

            for await _ in stream2 {
                dataCount += 1
                if dataCount >= 10 {
                    expectation2.fulfill()
                    break
                }
            }

            return dataCount
        }

        await fulfillment(of: [expectation1, expectation2], timeout: 5)

        recorder1.stop()
        recorder2.stop()

        let dataCount1 = await task1.value
        let dataCount2 = await task2.value

        XCTAssertGreaterThan(dataCount1, 0, "Should have received audio data from recorder1")
        XCTAssertGreaterThan(dataCount2, 0, "Should have received audio data from recorder2")
    }

    func testObjCCompatibility() async throws {
        let localTrack = LocalAudioTrack.createTrack(options: .noProcessing)

        let recorder = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatInt16,
            sampleRate: 48000
        )

        let dataExpectation = expectation(description: "Received audio data")
        let completionExpectation = expectation(description: "Completion called")
        dataExpectation.assertForOverFulfill = false

        recorder.start(onData: { _ in
            dataExpectation.fulfill()
        }, onCompletion: { _ in
            completionExpectation.fulfill()
        })

        await fulfillment(of: [dataExpectation], timeout: 5)

        recorder.stop()

        await fulfillment(of: [completionExpectation], timeout: 5)
    }
}
