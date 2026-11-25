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
import Testing

/// Every read goes through a message that is never bound to a name, so nothing but the read itself
/// keeps its storage alive.
@Suite("temporary message reads",
       .bug("https://github.com/livekit/client-sdk-swift/issues/1158"),
       .bug("https://github.com/livekit/client-sdk-swift/issues/1159"))
struct TemporaryMessageTests {
    @Test func singularGettersOnTemporaries() {
        let distance = LiveKit.Livekit_RegionInfo.with { $0.distance = 6_660_301 }.distance
        let kind = LiveKit.Livekit_DataPacket.with { $0.kind = .lossy }.kind
        let region = LiveKit.Livekit_RegionInfo.with { $0.region = "otokyo1a" }.region
        let payload = LiveKit.Livekit_UserPacket.with { $0.payload = Data([1, 2, 3]) }.payload
        let hasVersion = LiveKit.Livekit_Room.with { $0.version = .with { $0.ticks = 7 } }.hasVersion
        let unixMicro = LiveKit.Livekit_Room.with { $0.version = .with { $0.unixMicro = 42 } }.version.unixMicro

        #expect(distance == 6_660_301)
        #expect(kind == .lossy)
        #expect(region == "otokyo1a")
        #expect(payload == Data([1, 2, 3]))
        #expect(hasVersion)
        #expect(unixMicro == 42)
    }

    @Test func compositeGettersOnTemporaries() {
        let sources = LiveKit.Livekit_ParticipantPermission.with { $0.canPublishSources = [.camera, .microphone] }.canPublishSources
        let identities = LiveKit.Livekit_DataPacket.with { $0.destinationIdentities = ["alice", "bob"] }.destinationIdentities
        let regions = LiveKit.Livekit_RegionSettings.with {
            $0.regions = [.with { $0.region = "dblr1a" }, .with { $0.region = "dsyd1a" }]
        }.regions.map(\.region)
        let attributes = LiveKit.Livekit_ParticipantInfo.with { $0.attributes = ["role": "agent"] }.attributes
        let variantTopic = LiveKit.Livekit_DataPacket.with { $0.user = .with { $0.topic = "chat" } }.user.topic
        let value = LiveKit.Livekit_DataPacket.with { $0.user = .with { $0.topic = "chat" } }.value

        #expect(sources == [.camera, .microphone])
        #expect(identities == ["alice", "bob"])
        #expect(regions == ["dblr1a", "dsyd1a"])
        #expect(attributes == ["role": "agent"])
        #expect(variantTopic == "chat")
        guard case let .user(user) = value else {
            Issue.record("Expected a user packet, got \(String(describing: value))")
            return
        }
        let topic = user.topic
        #expect(topic == "chat")
    }

    @Test func serializedDataOfTemporary() throws {
        let data = try LiveKit.Livekit_DataPacket.with { $0.sequence = 9 }.serializedData()
        let sequence = try LiveKit.Livekit_DataPacket(serializedData: data).sequence
        #expect(sequence == 9)
    }

    @Test func ownedCopyOfTemporaryView() {
        let version = LiveKit.Livekit_Room.with { $0.version = .with { $0.unixMicro = 42 } }.version.owned()
        let ownsItsStorage = version._ownsItsStorage
        let unixMicro = version.unixMicro
        #expect(ownsItsStorage)
        #expect(unixMicro == 42)
    }

    @Test func nestedTemporaryIsEncodedIntoItsParent() throws {
        let data = try LiveKit.Livekit_DataPacket.with {
            $0.user = LiveKit.Livekit_UserPacket.with { $0.payload = Data([4, 5, 6]) }
        }.serializedData()
        let payload = try LiveKit.Livekit_DataPacket(serializedData: data).user.payload
        #expect(payload == Data([4, 5, 6]))
    }
}
