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
import LiveKitUniFFI
import Testing

/// Covers the FFI → public bridging that replaced the v1 protobuf → `StreamInfo` conversions
/// (previously `ByteStreamInfoTests` / `TextStreamInfoTests`). These conversions run on every opened
/// stream and every opened writer, so each field mapping is pinned here — including the millisecond
/// timestamp scaling, the optional/sentinel translations, and the enum mappings.
@Suite(.tags(.dataStream))
struct StreamInfoBridgeTests {
    // MARK: - TextStreamInfo

    private func ffiTextInfo(
        totalLength: UInt64? = 128,
        operationType: LiveKitUniFFI.OperationType = .create,
        replyToStreamId: String? = "replyID",
        encryptionType: LiveKitUniFFI.EncryptionType = .gcm,
    ) -> LiveKitUniFFI.TextStreamInfo {
        LiveKitUniFFI.TextStreamInfo(
            id: "id",
            topic: "topic",
            timestampMs: 100_000,
            totalLength: totalLength,
            attributes: ["key": "value"],
            mimeType: "text/plain",
            operationType: operationType,
            version: 10,
            replyToStreamId: replyToStreamId,
            attachedStreamIds: ["attachedID"],
            generated: true,
            encryptionType: encryptionType,
        )
    }

    @Test func textInfoMapsEveryField() {
        let info = LiveKit.TextStreamInfo(ffiTextInfo(), encryptionType: .gcm)

        #expect(info.id == "id")
        #expect(info.topic == "topic")
        // Milliseconds on the wire, `Date` in the API.
        #expect(info.timestamp == Date(timeIntervalSince1970: 100))
        #expect(info.totalLength == 128)
        #expect(info.attributes == ["key": "value"])
        #expect(info.operationType == .create)
        #expect(info.version == 10)
        #expect(info.replyToStreamID == "replyID")
        #expect(info.attachedStreamIDs == ["attachedID"])
        #expect(info.generated == true)
    }

    @Test func textInfoTotalLengthIsOptional() {
        #expect(LiveKit.TextStreamInfo(ffiTextInfo(totalLength: nil), encryptionType: .none).totalLength == nil)
        #expect(LiveKit.TextStreamInfo(ffiTextInfo(totalLength: 0), encryptionType: .none).totalLength == 0)
    }

    @Test func textInfoReplyToStreamIDIsOptional() {
        #expect(LiveKit.TextStreamInfo(ffiTextInfo(replyToStreamId: nil), encryptionType: .none).replyToStreamID == nil)
    }

    /// The initializer takes the encryption type as a parameter rather than reading the FFI record,
    /// so callers control it: inbound streams pass the wire value the core reports, outgoing ones the
    /// room's data-channel setting (there is no per-packet value to read for a stream being sent).
    @Test func textInfoEncryptionTypeComesFromTheCallerNotTheFFI() {
        let ffi = ffiTextInfo(encryptionType: .gcm)
        #expect(LiveKit.TextStreamInfo(ffi, encryptionType: .none).encryptionType == .none)
        #expect(LiveKit.TextStreamInfo(ffi, encryptionType: .gcm).encryptionType == .gcm)
    }

    @Test(arguments: [
        (LiveKitUniFFI.OperationType.create, LiveKit.TextStreamInfo.OperationType.create),
        (.update, .update),
        (.delete, .delete),
        (.reaction, .reaction),
    ])
    func textInfoOperationTypeMapping(_ ffi: LiveKitUniFFI.OperationType, _ expected: LiveKit.TextStreamInfo.OperationType) {
        #expect(LiveKit.TextStreamInfo(ffiTextInfo(operationType: ffi), encryptionType: .none).operationType == expected)
    }

    // MARK: - ByteStreamInfo

    private func ffiByteInfo(
        totalLength: UInt64? = 128,
        name: String = "filename.bin",
    ) -> LiveKitUniFFI.ByteStreamInfo {
        LiveKitUniFFI.ByteStreamInfo(
            id: "id",
            topic: "topic",
            timestampMs: 100_000,
            totalLength: totalLength,
            attributes: ["key": "value"],
            mimeType: "image/jpeg",
            name: name,
            encryptionType: .gcm,
        )
    }

    @Test func byteInfoMapsEveryField() {
        let info = LiveKit.ByteStreamInfo(ffiByteInfo(), encryptionType: .gcm)

        #expect(info.id == "id")
        #expect(info.topic == "topic")
        #expect(info.timestamp == Date(timeIntervalSince1970: 100))
        #expect(info.totalLength == 128)
        #expect(info.attributes == ["key": "value"])
        #expect(info.mimeType == "image/jpeg")
        #expect(info.name == "filename.bin")
        #expect(info.encryptionType == .gcm)
    }

    /// The FFI carries an absent name as the empty string; the public API models it as `nil`, which
    /// `ByteStreamReader.resolveFileName` relies on to fall back to the stream ID.
    @Test func byteInfoEmptyNameBecomesNil() {
        #expect(LiveKit.ByteStreamInfo(ffiByteInfo(name: ""), encryptionType: .none).name == nil)
        #expect(LiveKit.ByteStreamInfo(ffiByteInfo(name: "a.bin"), encryptionType: .none).name == "a.bin")
    }

    @Test func byteInfoTotalLengthIsOptional() {
        #expect(LiveKit.ByteStreamInfo(ffiByteInfo(totalLength: nil), encryptionType: .none).totalLength == nil)
    }

    // MARK: - StreamError

    /// The public error set predates the FFI core, so several Rust cases collapse onto one public
    /// case. Pinned exhaustively: a new Rust variant that lands on the wrong case is otherwise silent.
    @Test(arguments: [
        (LiveKitUniFFI.DataStreamError.AbnormalEnd(reason: "why"), StreamError.abnormalEnd(reason: "why")),
        (.Io(reason: "disk"), .abnormalEnd(reason: "disk")),
        (.Utf8(reason: "bad"), .decodeFailed),
        (.Decompression, .decodeFailed),
        (.LengthExceeded, .lengthExceeded),
        (.HeaderTooLarge, .lengthExceeded),
        (.PayloadTooLarge, .lengthExceeded),
        (.Incomplete, .incomplete),
        (.AlreadyClosed, .terminated),
        (.InvalidHeader, .terminated),
        (.MissedChunk, .terminated),
        (.SendFailed, .terminated),
        (.Internal, .terminated),
        (.InvalidFileName, .terminated),
    ])
    func streamErrorMapping(_ ffi: LiveKitUniFFI.DataStreamError, _ expected: StreamError) {
        #expect(StreamError(ffi) == expected)
    }

    /// `EncryptionTypeMismatch` now carries both types, so the bridge reports what actually
    /// disagreed rather than a sentinel. Reachable again now that the wire encryption type is passed
    /// to `handlePacketReceived`.
    @Test func streamErrorEncryptionTypeMismatchCarriesBothTypes() {
        #expect(
            StreamError(.EncryptionTypeMismatch(expected: .gcm, received: .none))
                == .encryptionTypeMismatch(expected: .gcm, received: .none),
        )
        #expect(
            StreamError(.EncryptionTypeMismatch(expected: .none, received: .custom))
                == .encryptionTypeMismatch(expected: .none, received: .custom),
        )
    }
}
