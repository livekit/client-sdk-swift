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

@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
@preconcurrency import LiveKitWebRTC

class E2EEThreadTests: LKTestCase {
    // Attempt to crash LKRTCFrameCryptor initialization
    func testCreateFrameCryptor() async throws {
        // Create peerConnection
        let peerConnection = RTC.peerConnectionFactory.peerConnection(with: .liveKitDefault(),
                                                                      constraints: .defaultPCConstraints,
                                                                      delegate: nil)

        let keyprovider = LKRTCFrameCryptorKeyProvider()

        // Run Tasks concurrently
        try await withThrowingTaskGroup(of: LKRTCFrameCryptor?.self) { group in
            for _ in 1 ... 100 {
                group.addTask {
                    let ns = UInt64(Double.random(in: 1 ..< 3) * 1_000_000)
                    try await Task.sleep(nanoseconds: ns)

                    // Create a sender
                    guard let sender = peerConnection?.addTransceiver(of: .video)?.sender else {
                        XCTFail("Failed to create transceiver")
                        fatalError()
                    }

                    // Remove sender from pc
                    peerConnection?.removeTrack(sender)

                    // sender.track will be nil at this point.
                    // Causing crashes in previous WebRTC versions. (patched in 114.5735.19)
                    return LKRTCFrameCryptor(factory: RTC.peerConnectionFactory,
                                             rtpSender: sender,
                                             participantId: "dummy",
                                             algorithm: .aesGcm,
                                             keyProvider: keyprovider)
                }
            }

            try await group.waitForAll()
        }

        peerConnection?.close()
    }
}
