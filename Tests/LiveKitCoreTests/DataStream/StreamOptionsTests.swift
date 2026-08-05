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

/// Covers the public `compress` option added for data streams v2, including the two `StreamTextOptions`
/// initializers (the compress-bearing designated initializer and the compatibility initializer that
/// preserves the pre-`compress` — and Objective-C — call site).
@Suite(.tags(.dataStream))
struct StreamOptionsTests {
    @Test func textCompressDefaultsToNilViaCompatInit() {
        #expect(StreamTextOptions(topic: "t").compress == nil)
        #expect(StreamTextOptions(topic: "t", version: 2).compress == nil)
    }

    @Test func textCompressExplicit() {
        #expect(StreamTextOptions(topic: "t", compress: true).compress == true)
        #expect(StreamTextOptions(topic: "t", compress: false).compress == false)
        #expect(StreamTextOptions(topic: "t", compress: nil).compress == nil)
    }

    @Test func byteCompressDefaultsToNil() {
        #expect(StreamByteOptions(topic: "t").compress == nil)
    }

    @Test func byteCompressExplicit() {
        #expect(StreamByteOptions(topic: "t", compress: true).compress == true)
        #expect(StreamByteOptions(topic: "t", compress: false).compress == false)
    }

    @Test func otherFieldsUnaffected() {
        let text = StreamTextOptions(topic: "t", version: 3, compress: true)
        #expect(text.topic == "t")
        #expect(text.version == 3)

        let byte = StreamByteOptions(topic: "b", mimeType: "image/png", totalSize: 42, compress: false)
        #expect(byte.topic == "b")
        #expect(byte.mimeType == "image/png")
        #expect(byte.totalSize == 42)
    }

    @Test func dataStreamMaxPayloadSizeOption() {
        #expect(DataStreamOptions().maxPayloadSize == nil)
        #expect(DataStreamOptions(maxPayloadSize: 1000).maxPayloadSize == 1000)
        #expect(RoomOptions().dataStreamOptions.maxPayloadSize == nil)
        #expect(RoomOptions(dataStreamOptions: DataStreamOptions(maxPayloadSize: 42)).dataStreamOptions.maxPayloadSize == 42)
        // Objective-C accessor mirrors the Swift `Int?`.
        #expect(DataStreamOptions().maxPayloadSizeNumber == nil)
        #expect(DataStreamOptions(maxPayloadSize: 1000).maxPayloadSizeNumber == 1000)
        #expect(DataStreamOptions(maxPayloadSizeNumber: 1000).maxPayloadSize == 1000)
    }
}
