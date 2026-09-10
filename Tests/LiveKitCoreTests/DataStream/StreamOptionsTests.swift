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

/// Covers the public `compress` option added for data streams v2.
@Suite(.tags(.dataStream))
struct StreamOptionsTests {
    /// On by default, and the core reads the same value (`unwrap_or(true)`) when it isn't set.
    @Test func compressDefaultsToOn() {
        #expect(StreamTextOptions(topic: "t").compress)
        #expect(StreamTextOptions(topic: "t", version: 2).compress)
        #expect(StreamByteOptions(topic: "t").compress)
    }

    @Test func compressExplicit() {
        #expect(StreamTextOptions(topic: "t", compress: true).compress)
        #expect(!StreamTextOptions(topic: "t", compress: false).compress)
        #expect(StreamByteOptions(topic: "t", compress: true).compress)
        #expect(!StreamByteOptions(topic: "t", compress: false).compress)
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

    @Test func dataStreamMaxPayloadByteLengthOption() {
        #expect(DataStreamOptions().maxPayloadByteLength == nil)
        #expect(DataStreamOptions(maxPayloadByteLength: 1000).maxPayloadByteLength == 1000)
        #expect(RoomOptions().dataStreamOptions.maxPayloadByteLength == nil)
        #expect(RoomOptions(dataStreamOptions: DataStreamOptions(maxPayloadByteLength: 42)).dataStreamOptions.maxPayloadByteLength == 42)
        // Objective-C accessor mirrors the Swift `Int?`.
        #expect(DataStreamOptions().maxPayloadByteLengthNumber == nil)
        #expect(DataStreamOptions(maxPayloadByteLength: 1000).maxPayloadByteLengthNumber == 1000)
        #expect(DataStreamOptions(maxPayloadByteLengthNumber: 1000).maxPayloadByteLength == 1000)
    }

    /// A non-positive cap used to reach `UInt64(_:)` at the FFI boundary and trap the process on the
    /// first inbound packet. Normalized to `nil` (the built-in cap) at construction instead.
    @Test(arguments: [-1, 0, Int.min])
    func dataStreamNonPositiveMaxPayloadByteLengthIsIgnored(_ value: Int) {
        #expect(DataStreamOptions(maxPayloadByteLength: value).maxPayloadByteLength == nil)
        #expect(DataStreamOptions(maxPayloadByteLengthNumber: NSNumber(value: value)).maxPayloadByteLength == nil)
    }

    /// Same hazard on the other side: a negative expected size reached `UInt64(_:)` when the stream
    /// was opened. Zero is a legitimate length (an empty file), so only negatives are dropped.
    @Test(arguments: [-1, Int.min])
    func byteNegativeTotalSizeIsIgnored(_ value: Int) {
        #expect(StreamByteOptions(topic: "t", totalSize: value).totalSize == nil)
        #expect(StreamByteOptions(topic: "t", totalSize: 0).totalSize == 0)
    }
}
