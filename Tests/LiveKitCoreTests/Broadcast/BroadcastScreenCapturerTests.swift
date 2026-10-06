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

#if os(iOS)

import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.broadcast), .serialized)
struct BroadcastScreenCapturerTests {
    private func makeCapturer(socketPath: SocketPath?) async -> BroadcastScreenCapturer {
        await RTC.run {
            BroadcastScreenCapturer(delegate: RTC.createVideoSource(forScreenShare: true),
                                    options: ScreenShareCaptureOptions(),
                                    socketPath: socketPath)
        }
    }

    private func temporarySocketPath() throws -> SocketPath {
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.temporaryDirectory.path)
        return try #require(SocketPath(UUID().uuidString + ".sock"))
    }

    @Test func stopBeforeExtensionConnectsReleasesCapturer() async throws {
        let socketPath = try temporarySocketPath()

        weak var weakCapturer: BroadcastScreenCapturer?
        do {
            let capturer = await makeCapturer(socketPath: socketPath)
            weakCapturer = capturer
            #expect(try await capturer.startCapture())
            #expect(try await capturer.stopCapture())
        }

        for _ in 0 ..< 50 where weakCapturer != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(weakCapturer == nil)
    }

    @Test func restartIsNotStoppedByPreviousReceiver() async throws {
        let socketPath = try temporarySocketPath()
        let capturer = await makeCapturer(socketPath: socketPath)

        for _ in 0 ..< 20 {
            #expect(try await capturer.startCapture())
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(try await capturer.stopCapture())
            #expect(BroadcastScreenCapturer.activeCount == 0)
            #expect(try await capturer.startCapture())
            #expect(BroadcastScreenCapturer.activeCount == 1)
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(capturer.captureState == .started)

            let uploader = Task { try await IPCChannel(connectingTo: socketPath) }
            let timeout = Task {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                uploader.cancel()
            }
            let channel = try await uploader.value
            timeout.cancel()
            channel.close()
            _ = try await capturer.stopCapture()
        }
    }

    @Test func receiverFailureStopsCaptureAndIsNotCounted() async throws {
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.temporaryDirectory.path)
        let socketPath = try #require(SocketPath("missing-\(UUID().uuidString.prefix(8))/b.sock"))
        let capturer = await makeCapturer(socketPath: socketPath)

        #expect(try await capturer.startCapture())
        for _ in 0 ..< 50 where capturer.captureState != .stopped || BroadcastScreenCapturer.activeCount != 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(capturer.captureState == .stopped)
        #expect(BroadcastScreenCapturer.activeCount == 0)
    }

    @Test func concurrentStartStopReleasesReceiver() async throws {
        let socketPath = try temporarySocketPath()
        weak var weakCapturer: BroadcastScreenCapturer?
        do {
            let capturer = await makeCapturer(socketPath: socketPath)
            weakCapturer = capturer
            for _ in 0 ..< 50 {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0 ..< 8 {
                        group.addTask {
                            _ = try await capturer.startCapture()
                            await Task.yield()
                            _ = try await capturer.stopCapture()
                        }
                    }
                    try await group.waitForAll()
                }
                #expect(capturer.captureState == .stopped)
            }
        }

        for _ in 0 ..< 100 where weakCapturer != nil || BroadcastScreenCapturer.activeCount != 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(weakCapturer == nil)
        #expect(BroadcastScreenCapturer.activeCount == 0)
    }

    @Test func receiverExitIsNotCountedWithOutstandingStart() async throws {
        let socketPath = try temporarySocketPath()
        let capturer = await makeCapturer(socketPath: socketPath)
        #expect(try await capturer.startCapture())
        #expect(try await capturer.startCapture() == false)

        let uploader = Task { try await IPCChannel(connectingTo: socketPath) }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            uploader.cancel()
        }
        defer { timeout.cancel() }
        let channel = try await uploader.value
        channel.close()

        for _ in 0 ..< 100 where BroadcastScreenCapturer.activeCount != 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let activeCountAfterExit = BroadcastScreenCapturer.activeCount
        _ = try await capturer.stopCapture()
        #expect(activeCountAfterExit == 0)
    }

    @Test func startWithoutSocketPathIsNotCounted() async throws {
        let capturer = await makeCapturer(socketPath: nil)

        #expect(try await capturer.startCapture() == false)
        #expect(BroadcastScreenCapturer.activeCount == 0)
        _ = try await capturer.stopCapture()
        #expect(BroadcastScreenCapturer.activeCount == 0)
    }
}

#endif
