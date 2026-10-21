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

internal import LiveKitFFI

public enum StreamError: Error, Equatable {
    /// Unable to open a stream with the same ID more than once.
    ///
    /// - Note: Not thrown since data streams moved to the Rust core. Kept for source compatibility.
    case alreadyOpened

    /// The stream ended abnormally: the sender closed it with `reason`, the connection closed while
    /// it was open, or a file operation failed.
    case abnormalEnd(reason: String)

    /// Incoming data could not be decoded: text that is not valid UTF-8, or a compressed payload
    /// that does not decompress.
    case decodeFailed

    /// The stream exceeded the length in its header, the cap set by
    /// ``DataStreamOptions/maxPayloadByteLength``, or the size a header or packet can carry.
    case lengthExceeded

    /// Read length less than total length specified in stream header.
    case incomplete

    /// The stream failed for a reason that no other case covers: it is already closed, a chunk
    /// was missing or malformed, a send could not be delivered, or the file name was invalid.
    case terminated

    /// Cannot perform operations on an unknown stream.
    ///
    /// - Note: Not thrown since data streams moved to the Rust core. Kept for source compatibility.
    case unknownStream

    /// Unable to register a stream handler more than once.
    case handlerAlreadyRegistered

    /// Given destination URL is not a directory.
    case notDirectory

    /// Unable to read information about the file to send, or the name of a file to write is not a
    /// single plain path component.
    case fileInfoUnavailable

    /// Encryption type mismatch between stream header and chunk/trailer.
    case encryptionTypeMismatch(expected: EncryptionType, received: EncryptionType)
}

// MARK: - FFI bridging

extension StreamError {
    /// Best-effort mapping from the UniFFI error onto the public case set. The public enum predates
    /// the FFI core and doesn't cover every Rust case, so several map onto the closest public case
    /// (message-carrying cases preserve the underlying message via `abnormalEnd`).
    init(_ ffi: LiveKitFFI.DataStreamError) {
        switch ffi {
        case let .AbnormalEnd(message): self = .abnormalEnd(reason: message)
        case let .Io(message): self = .abnormalEnd(reason: message)
        case .Utf8, .Decompression: self = .decodeFailed
        case .LengthExceeded, .HeaderTooLarge, .PayloadTooLarge: self = .lengthExceeded
        case .Incomplete: self = .incomplete
        case let .EncryptionTypeMismatch(expected, received):
            self = .encryptionTypeMismatch(expected: EncryptionType(expected), received: EncryptionType(received))
        case .AlreadyClosed, .InvalidHeader, .MissedChunk, .SendFailed, .Internal, .InvalidFileName:
            self = .terminated
        @unknown default:
            self = .terminated
        }
    }
}
