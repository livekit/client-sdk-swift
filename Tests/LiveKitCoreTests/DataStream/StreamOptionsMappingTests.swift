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
import LiveKitFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Public stream options map completely onto the native send options.
@Suite(.tags(.dataStream))
struct StreamOptionsMappingTests {}

// MARK: - Options

extension StreamOptionsMappingTests {
    @Test func optionDefaultsMapToFFIOptions() {
        let text = LiveKit.StreamTextOptions(topic: "t").ffi
        #expect(text.operationType == .create)
        #expect(text.generated == false)
        #expect(text.compress == true)
        #expect(text.totalLength == nil)
        #expect(LiveKit.StreamByteOptions(topic: "t").ffi.compress == true)
    }

    @Test func textOptionsMapCompletelyToFFIOptions() {
        let ffi = LiveKit.StreamTextOptions(
            topic: "topic",
            attributes: ["k": "v"],
            destinationIdentities: [Participant.Identity(from: "alice"), Participant.Identity(from: "bob")],
            id: "sid",
            operationType: .reaction,
            version: 2,
            attachedStreamIDs: ["a"],
            replyToStreamID: "r",
            generated: true,
            compress: false,
            totalSize: 99,
        ).ffi

        #expect(ffi.topic == "topic")
        #expect(ffi.attributes == ["k": "v"])
        #expect(ffi.destinationIdentities == ["alice", "bob"])
        #expect(ffi.id == "sid")
        #expect(ffi.operationType == .reaction)
        #expect(ffi.version == 2)
        #expect(ffi.attachedStreamIds == ["a"])
        #expect(ffi.replyToStreamId == "r")
        #expect(ffi.generated == true)
        #expect(ffi.compress == false)
        #expect(ffi.totalLength == 99)
    }

    @Test func byteOptionsMapCompletelyToFFIOptions() {
        let ffi = LiveKit.StreamByteOptions(
            topic: "topic",
            attributes: ["k": "v"],
            destinationIdentities: [Participant.Identity(from: "alice")],
            id: "sid",
            mimeType: "application/pdf",
            name: "doc.pdf",
            totalSize: 99,
            compress: false,
        ).ffi

        #expect(ffi.topic == "topic")
        #expect(ffi.attributes == ["k": "v"])
        #expect(ffi.destinationIdentities == ["alice"])
        #expect(ffi.id == "sid")
        #expect(ffi.mimeType == "application/pdf")
        #expect(ffi.name == "doc.pdf")
        #expect(ffi.totalLength == 99)
        #expect(ffi.compress == false)
    }

    @Test(arguments: [
        (LiveKit.TextStreamInfo.OperationType.create, LiveKitFFI.OperationType.create),
        (.update, .update),
        (.delete, .delete),
        (.reaction, .reaction),
    ])
    func operationTypeMapsToFFI(_ operationType: LiveKit.TextStreamInfo.OperationType, _ expected: LiveKitFFI.OperationType) {
        #expect(operationType.ffiValue == expected)
        #expect(LiveKit.StreamTextOptions(topic: "t", operationType: operationType).ffi.operationType == expected)
    }
}
