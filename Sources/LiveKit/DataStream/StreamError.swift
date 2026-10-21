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

internal import LiveKitFFI

public enum StreamError: Error, Equatable {
    /// Unable to open a stream with the same ID more than once.
    ///
    /// - Note: Not thrown since data streams moved to the Rust core. Kept for source compatibility.
    case alreadyOpened

    /// The stream ended abnormally: the sender closed it with `reason`, or the connection closed
    /// while it was open.
    case abnormalEnd(reason: String)

    /// A compressed payload did not decompress. Text that is not valid UTF-8 throws
    /// ``invalidUTF8(reason:)``.
    case decodeFailed

    /// The stream carried more data than the length in its header. A header or a payload over a
    /// size limit throws ``headerTooLarge`` or ``payloadTooLarge``.
    case lengthExceeded

    /// Read length less than total length specified in stream header.
    case incomplete

    /// The stream failed for a reason that this version of the SDK does not know.
    case terminated

    /// Cannot perform operations on an unknown stream.
    ///
    /// - Note: Not thrown since data streams moved to the Rust core. Kept for source compatibility.
    case unknownStream

    /// Unable to register a stream handler more than once.
    case handlerAlreadyRegistered

    /// Given destination URL is not a directory.
    case notDirectory

    /// Unable to read information about the file to send.
    case fileInfoUnavailable

    /// Encryption type mismatch between stream header and chunk/trailer.
    case encryptionTypeMismatch(expected: EncryptionType, received: EncryptionType)

    /// The header of an outgoing stream is too large to send. The header travels in one packet, so
    /// its topic, attributes and other fields together must fit in that packet.
    case headerTooLarge

    /// An incoming stream's payload is larger than ``DataStreamOptions/maxPayloadByteLength``.
    case payloadTooLarge

    /// Incoming text is not valid UTF-8. `reason` is the decoder's description of the error.
    case invalidUTF8(reason: String)

    /// The header of an incoming stream could not be read.
    case invalidHeader

    /// A chunk of an incoming stream is missing, so the stream cannot continue.
    case missedChunk

    /// The stream is already closed.
    case alreadyClosed

    /// A packet of the stream could not be sent, for example because the room disconnected.
    case sendFailed

    /// A file name is not a single plain path component, for example one that contains `/`.
    case invalidFileName

    /// Reading or writing a file failed. `reason` describes the error.
    case io(reason: String)

    /// The SDK could not process the stream, for example because the connection the stream was
    /// opened on has ended.
    case internalError
}

// MARK: - Objective-C error codes

extension StreamError: CustomNSError {
    /// The `NSError` code. Pinned per case because the default code depends on the order and on
    /// which cases carry a payload, so a new case would change the codes of the existing ones.
    public var errorCode: Int {
        switch self {
        case .abnormalEnd: 0
        case .encryptionTypeMismatch: 1
        case .alreadyOpened: 2
        case .decodeFailed: 3
        case .lengthExceeded: 4
        case .incomplete: 5
        case .terminated: 6
        case .unknownStream: 7
        case .handlerAlreadyRegistered: 8
        case .notDirectory: 9
        case .fileInfoUnavailable: 10
        case .headerTooLarge: 11
        case .payloadTooLarge: 12
        case .invalidUTF8: 13
        case .invalidHeader: 14
        case .missedChunk: 15
        case .alreadyClosed: 16
        case .sendFailed: 17
        case .invalidFileName: 18
        case .io: 19
        case .internalError: 20
        }
    }

    /// The `NSError` user info: a description naming the case, and the detail the core reported,
    /// where there is one, as the failure reason.
    public var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "Data stream error: \(self)"]
        if let detail {
            userInfo[NSLocalizedFailureReasonErrorKey] = detail
        }
        return userInfo
    }

    private var detail: String? {
        switch self {
        case let .abnormalEnd(reason), let .invalidUTF8(reason), let .io(reason): reason
        default: nil
        }
    }
}

// MARK: - Declared length

extension StreamError {
    /// The error for a stream that ended after `receivedLength` bytes when its header declared
    /// `declaredLength`, or `nil` when the two agree or nothing was declared.
    ///
    /// ponytail: the core checks a chunked stream's length but not an inline one's, so the readers
    /// call this when a stream ends. Move the check to the core once it validates inline length.
    init?(receivedLength: Int, declaredLength: Int?) {
        guard let declaredLength, receivedLength != declaredLength else { return nil }
        self = receivedLength < declaredLength ? .incomplete : .lengthExceeded
    }
}

// MARK: - FFI bridging

extension StreamError {
    // Maps each UniFFI error onto its own public case, keeping the message where the FFI carries
    // one.
    // swiftlint:disable:next cyclomatic_complexity
    init(_ ffi: LiveKitFFI.DataStreamError) {
        self = switch ffi {
        case let .AbnormalEnd(reason): .abnormalEnd(reason: reason)
        case let .Utf8(reason): .invalidUTF8(reason: reason)
        case .Decompression: .decodeFailed
        case .LengthExceeded: .lengthExceeded
        case .HeaderTooLarge: .headerTooLarge
        case .PayloadTooLarge: .payloadTooLarge
        case .Incomplete: .incomplete
        case let .EncryptionTypeMismatch(expected, received):
            .encryptionTypeMismatch(expected: EncryptionType(expected), received: EncryptionType(received))
        case .InvalidHeader: .invalidHeader
        case .MissedChunk: .missedChunk
        case .AlreadyClosed: .alreadyClosed
        case .SendFailed: .sendFailed
        case .InvalidFileName: .invalidFileName
        case let .Io(reason): .io(reason: reason)
        case .Internal: .internalError
        @unknown default: .terminated
        }
    }
}
