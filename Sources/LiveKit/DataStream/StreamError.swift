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

internal import LiveKitUniFFI

public enum StreamError: Error, Equatable {
    /// Unable to open a stream with the same ID more than once.
    case alreadyOpened

    /// Stream closed abnormally by remote participant.
    case abnormalEnd(reason: String)

    /// Incoming chunk data could not be decoded.
    case decodeFailed

    /// Read length exceeded total length specified in stream header.
    case lengthExceeded

    /// Read length less than total length specified in stream header.
    case incomplete

    /// Stream terminated before completion.
    case terminated

    /// Cannot perform operations on an unknown stream.
    case unknownStream

    /// Unable to register a stream handler more than once.
    case handlerAlreadyRegistered

    /// Given destination URL is not a directory.
    case notDirectory

    /// Unable to read information about the file to send.
    case fileInfoUnavailable

    /// Encryption type mismatch between stream header and chunk/trailer.
    case encryptionTypeMismatch(expected: EncryptionType, received: EncryptionType)
}

// MARK: - FFI bridging

extension StreamError {
    /// Best-effort mapping from the UniFFI error onto the public case set. The public enum predates
    /// the FFI core and doesn't cover every Rust case, so several map onto the closest public case
    /// (message-carrying cases preserve the underlying message via `abnormalEnd`).
    init(_ ffi: LiveKitUniFFI.DataStreamError) {
        switch ffi {
        case let .AbnormalEnd(message): self = .abnormalEnd(reason: message)
        case let .Io(message): self = .abnormalEnd(reason: message)
        case .Utf8, .Decompression: self = .decodeFailed
        case .LengthExceeded, .HeaderTooLarge, .PayloadTooLarge: self = .lengthExceeded
        case .Incomplete: self = .incomplete
        case .EncryptionTypeMismatch: self = .encryptionTypeMismatch(expected: .none, received: .none)
        case .AlreadyClosed, .InvalidHeader, .MissedChunk, .SendFailed, .Internal, .InvalidFileName:
            self = .terminated
        }
    }
}
