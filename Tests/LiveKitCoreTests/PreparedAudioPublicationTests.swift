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

@Suite(.serialized)
struct PreparedAudioPublicationTests {
    @Test func tracklessAudioOfferHasStableIdentity() async throws {
        let room = Room()
        let transport = try await Transport(config: .liveKitDefault(), target: .publisher,
                                            primary: true, singlePCMode: true, delegate: room)
        do {
            let sender = try await RTC.run {
                let options = LKRTCRtpTransceiverInit()
                options.direction = .sendOnly
                options.streamIds = ["prepared-microphone"]
                let transceiver = try transport.addTransceiver(ofType: .audio, transceiverInit: options)
                #expect(transceiver.sender.track == nil)
                return RTCSender(transceiver.sender)
            }
            let offer = try #require(try await transport.createInitialOffer())
            let document = SDP(parsing: offer.offer.sdp)
            let audio = try #require(document.mediaSections.first(where: { $0.mediaType == "audio" }))
            #expect(audio.msidTrackId == sender.senderId)
            #expect(await transport.localDescription == nil)
            await RTC.run {
                let track = RTC.createAudioTrack(source: RTC.createAudioSource(nil))
                track.isEnabled = false
                sender.raw.track = track
            }
            let attached = try #require(try await transport.createInitialOffer())
            #expect(SDP(parsing: attached.offer.sdp).mediaSections.first(where: { $0.mediaType == "audio" })?.msidTrackId == sender.senderId)
            await transport.close()
        } catch {
            await transport.close()
            throw error
        }
    }
}
