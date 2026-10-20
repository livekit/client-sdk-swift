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
    enum SingularGetter: CaseIterable {
        case int64, enumeration, string, bytes, presence, submessage
    }

    enum CompositeGetter: CaseIterable {
        case repeatedEnums, repeatedStrings, repeatedMessages, map, oneof, oneofVariant
    }

    @Test(arguments: SingularGetter.allCases)
    func singularGetterOnTemporary(_ getter: SingularGetter) {
        switch getter {
        case .int64:
            #expect(LiveKit.Livekit_RegionInfo.with { $0.distance = 6_660_301 }.distance == 6_660_301)
        case .enumeration:
            #expect(LiveKit.Livekit_DataPacket.with { $0.kind = .lossy }.kind == .lossy)
        case .string:
            #expect(LiveKit.Livekit_RegionInfo.with { $0.region = "otokyo1a" }.region == "otokyo1a")
        case .bytes:
            #expect(LiveKit.Livekit_UserPacket.with { $0.payload = Data([1, 2, 3]) }.payload == Data([1, 2, 3]))
        case .presence:
            #expect(LiveKit.Livekit_Room.with { $0.version = .with { $0.ticks = 7 } }.hasVersion)
        case .submessage:
            #expect(LiveKit.Livekit_Room.with { $0.version = .with { $0.unixMicro = 42 } }.version.unixMicro == 42)
        }
    }

    @Test(arguments: CompositeGetter.allCases)
    func compositeGetterOnTemporary(_ getter: CompositeGetter) {
        switch getter {
        case .repeatedEnums:
            #expect(LiveKit.Livekit_ParticipantPermission.with {
                $0.canPublishSources = [.camera, .microphone]
            }.canPublishSources == [.camera, .microphone])
        case .repeatedStrings:
            #expect(LiveKit.Livekit_DataPacket.with {
                $0.destinationIdentities = ["alice", "bob"]
            }.destinationIdentities == ["alice", "bob"])
        case .repeatedMessages:
            #expect(LiveKit.Livekit_RegionSettings.with {
                $0.regions = [.with { $0.region = "dblr1a" }, .with { $0.region = "dsyd1a" }]
            }.regions.map(\.region) == ["dblr1a", "dsyd1a"])
        case .map:
            #expect(LiveKit.Livekit_ParticipantInfo.with {
                $0.attributes = ["role": "agent"]
            }.attributes == ["role": "agent"])
        case .oneof:
            let value = LiveKit.Livekit_DataPacket.with { $0.user = .with { $0.topic = "chat" } }.value
            guard case let .user(user) = value else {
                Issue.record("Expected a user packet, got \(String(describing: value))")
                return
            }
            #expect(user.topic == "chat")
        case .oneofVariant:
            #expect(LiveKit.Livekit_DataPacket.with { $0.user = .with { $0.topic = "chat" } }.user.topic == "chat")
        }
    }

    @Test func serializedDataOfTemporary() throws {
        let data = try LiveKit.Livekit_DataPacket.with { $0.sequence = 9 }.serializedData()
        #expect(try LiveKit.Livekit_DataPacket(serializedData: data).sequence == 9)
    }

    @Test func ownedCopyOfTemporaryView() {
        let version = LiveKit.Livekit_Room.with { $0.version = .with { $0.unixMicro = 42 } }.version.owned()
        #expect(version._ownsItsStorage)
        #expect(version.unixMicro == 42)
    }

    @Test func nestedTemporaryIsEncodedIntoItsParent() throws {
        let data = try LiveKit.Livekit_DataPacket.with {
            $0.user = LiveKit.Livekit_UserPacket.with { $0.payload = Data([4, 5, 6]) }
        }.serializedData()
        #expect(try LiveKit.Livekit_DataPacket(serializedData: data).user.payload == Data([4, 5, 6]))
    }
}
