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

/// Covers the FFI → public bridging that replaced the v1 protobuf → `StreamInfo` conversions
/// (previously `ByteStreamInfoTests` / `TextStreamInfoTests`). These conversions run on every opened
/// stream and every opened writer, so each field mapping is pinned here — including the millisecond
/// timestamp scaling, the optional/sentinel translations, and the enum mappings.
@Suite(.tags(.dataStream))
struct StreamInfoBridgeTests {
    // MARK: - TextStreamInfo

    private func ffiTextInfo(
        totalLength: UInt64? = 128,
        operationType: LiveKitFFI.OperationType = .create,
        replyToStreamId: String? = "replyID",
        encryptionType: LiveKitFFI.EncryptionType = .gcm,
    ) -> LiveKitFFI.TextStreamInfo {
        LiveKitFFI.TextStreamInfo(
            id: "id",
            topic: "topic",
            timestampMs: 100_000,
            totalLength: totalLength,
            attributes: ["key": "value"],
            mimeType: "text/markdown",
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
        #expect(info.mimeType == "text/markdown")
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
        (LiveKitFFI.OperationType.create, LiveKit.TextStreamInfo.OperationType.create),
        (.update, .update),
        (.delete, .delete),
        (.reaction, .reaction),
    ])
    func textInfoOperationTypeMapping(_ ffi: LiveKitFFI.OperationType, _ expected: LiveKit.TextStreamInfo.OperationType) {
        #expect(LiveKit.TextStreamInfo(ffiTextInfo(operationType: ffi), encryptionType: .none).operationType == expected)
    }

    // MARK: - ByteStreamInfo

    private func ffiByteInfo(
        totalLength: UInt64? = 128,
        name: String = "filename.bin",
    ) -> LiveKitFFI.ByteStreamInfo {
        LiveKitFFI.ByteStreamInfo(
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

    static let errorMappings: [(LiveKitFFI.DataStreamError, StreamError)] = [
        (.AbnormalEnd(reason: "why"), .abnormalEnd(reason: "why")),
        (.Utf8(reason: "invalid byte"), .invalidUTF8(reason: "invalid byte")),
        (.Decompression, .decodeFailed),
        (.LengthExceeded, .lengthExceeded),
        (.HeaderTooLarge, .headerTooLarge),
        (.PayloadTooLarge, .payloadTooLarge),
        (.Incomplete, .incomplete),
        (.EncryptionTypeMismatch(expected: .gcm, received: .none), .encryptionTypeMismatch(expected: .gcm, received: .none)),
        (.InvalidHeader, .invalidHeader),
        (.MissedChunk, .missedChunk),
        (.AlreadyClosed, .alreadyClosed),
        (.SendFailed, .sendFailed),
        (.InvalidFileName, .invalidFileName),
        (.Io(reason: "disk went away"), .io(reason: "disk went away")),
        (.Internal, .internalError),
    ]

    /// Every Rust case maps onto its own public case and keeps the message where the FFI carries
    /// one. Pinned exhaustively: a new Rust variant that lands on the wrong case is otherwise silent.
    @Test(arguments: errorMappings)
    func streamErrorMapping(_ ffi: LiveKitFFI.DataStreamError, _ expected: StreamError) {
        #expect(StreamError(ffi) == expected)
    }

    /// No two Rust cases share a public case, so a caller can tell every failure apart, for example
    /// a header too large to send from an incoming payload over the cap.
    @Test func streamErrorMappingIsOneToOne() {
        let codes = Self.errorMappings.map { StreamError($0.0).errorCode }
        #expect(Set(codes).count == Self.errorMappings.count)
    }

    /// Objective-C sees a `StreamError` as an `NSError`, whose default code depends on the order
    /// of the cases and on which carry a payload. The cases that shipped before keep their codes.
    @Test(arguments: [
        (StreamError.abnormalEnd(reason: ""), 0),
        (.encryptionTypeMismatch(expected: .none, received: .gcm), 1),
        (.alreadyOpened, 2),
        (.decodeFailed, 3),
        (.lengthExceeded, 4),
        (.incomplete, 5),
        (.terminated, 6),
        (.unknownStream, 7),
        (.handlerAlreadyRegistered, 8),
        (.notDirectory, 9),
        (.fileInfoUnavailable, 10),
    ])
    func streamErrorKeepsNSErrorCode(_ error: StreamError, _ code: Int) {
        let nsError = error as NSError
        #expect(nsError.code == code)
        #expect(nsError.domain == "LiveKit.StreamError")
    }

    /// Objective-C reads the core's detail from the `NSError`: the description includes it, the
    /// failure reason is the detail itself, and the code stays pinned.
    @Test(arguments: [
        (StreamError.invalidUTF8(reason: "invalid byte"), "invalid byte", 13),
        (.io(reason: "disk went away"), "disk went away", 19),
        (.abnormalEnd(reason: "sender gave up"), "sender gave up", 0),
    ])
    func streamErrorDetailReachesNSError(_ error: StreamError, _ detail: String, _ code: Int) {
        let nsError = error as NSError
        #expect(nsError.code == code)
        #expect(nsError.localizedFailureReason == detail)
        #expect(nsError.localizedDescription.contains(detail))
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

    // MARK: - StreamProgress

    /// The core's counts, and what the public progress should report for them.
    struct ProgressCase: Sendable {
        let processed: UInt64
        let total: UInt64?
        let bytesTotal: Int?
        let fraction: Double?
    }

    /// The total and the fraction follow the core's counts, and their Objective-C accessors mirror
    /// them: both are `nil` when the total is unknown, and an empty stream is complete.
    @Test(arguments: [
        ProgressCase(processed: 5, total: 10, bytesTotal: 10, fraction: 0.5),
        ProgressCase(processed: 5, total: nil, bytesTotal: nil, fraction: nil),
        ProgressCase(processed: 0, total: 0, bytesTotal: 0, fraction: 1),
    ])
    func progressMapsCountsAndObjCAccessors(_ progress: ProgressCase) {
        let mapped = LiveKit.StreamProgress(LiveKitFFI.StreamProgress(bytesProcessed: progress.processed, bytesTotal: progress.total))
        #expect(mapped.bytesProcessed == Int(progress.processed))
        #expect(mapped.bytesTotal == progress.bytesTotal)
        #expect(mapped.fraction == progress.fraction)
        #expect(mapped.bytesTotalNumber == progress.bytesTotal.map { NSNumber(value: $0) })
        #expect(mapped.fractionNumber == progress.fraction.map { NSNumber(value: $0) })
    }
}
