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

@Suite(.tags(.broadcast))
struct BroadcastScreenCapturerTests {
    @Test func stopBeforeExtensionConnectsReleasesCapturer() async throws {
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.temporaryDirectory.path)
        let socketPath = try #require(SocketPath(UUID().uuidString + ".sock"))

        weak var weakCapturer: BroadcastScreenCapturer?
        do {
            let capturer = await RTC.run {
                BroadcastScreenCapturer(delegate: RTC.createVideoSource(forScreenShare: true),
                                        options: ScreenShareCaptureOptions(),
                                        socketPath: socketPath)
            }
            weakCapturer = capturer
            #expect(try await capturer.startCapture())
            #expect(try await capturer.stopCapture())
        }

        for _ in 0 ..< 50 where weakCapturer != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(weakCapturer == nil)
    }
}

#endif
