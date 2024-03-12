/*
 * Copyright 2024 LiveKit
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
import LiveKitWebRTC
import XCTest

class E2EEThreadTests: XCTestCase {
    // Attempt to crash LKRTCFrameCryptor initialization
    func testCreateFrameCryptor() async throws {
        // Run Tasks concurrently
        let result = try await withThrowingTaskGroup(of: LKRTCFrameCryptor.self, returning: [LKRTCFrameCryptor].self) { group in
            for _ in 1 ... 10000 {
                group.addTask {
                    let ns = UInt64(Double.random(in: 1 ..< 3) * 1_000_000)
                    try await Task.sleep(nanoseconds: ns)

                    let pc = Engine.peerConnectionFactory.peerConnection(with: .liveKitDefault(),
                                                                         constraints: .defaultPCConstraints,
                                                                         delegate: nil)

                    guard let transceiver = pc?.addTransceiver(of: .audio) else {
                        XCTFail("Failed to create transceiver")
                        throw fatalError()
                    }

                    let keyprovider = LKRTCFrameCryptorKeyProvider()

                    return LKRTCFrameCryptor(factory: Engine.peerConnectionFactory,
                                             rtpReceiver: transceiver.receiver,
                                             participantId: "dummy",
                                             algorithm: RTCCyrptorAlgorithm.aesGcm,
                                             keyProvider: keyprovider)
                }
            }

            var result: [LKRTCFrameCryptor] = []
            for try await e in group {
                result.append(e)
            }
            return result
        }

        print("frameCryptors: \(result)")
    }
}
