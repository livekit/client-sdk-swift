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

internal import LiveKitUniFFI

/// Asynchronously write to an open text stream.
@objcMembers
public final class TextStreamWriter: NSObject, Sendable {
    /// Information about the outgoing text stream.
    public let info: TextStreamInfo

    private let writer: LiveKitUniFFI.TextStreamWriter

    /// Whether or not the stream is still open. Reflects the FFI writer's state, so it becomes
    /// `false` once the stream is closed locally or a send fails (e.g. the room disconnected).
    public var isOpen: Bool {
        get async { await writer.isOpen() }
    }

    /// Write text to the stream.
    ///
    /// - Parameter text: Text to be sent.
    /// - Throws: Throws an error if the stream has been closed or text
    ///   cannot be sent to remote participants.
    ///
    public func write(_ text: String) async throws {
        do {
            try await writer.write(text: text)
        } catch let error as LiveKitUniFFI.DataStreamError {
            throw StreamError(error)
        }
    }

    /// Close the stream.
    ///
    /// - Parameter reason: A textual description of why the stream is being closed. Absense
    ///   of a reason indicates a normal closure.
    /// - Throws: Throws an error if the stream has already been closed or closure
    ///   cannot be communicated to remote participants.
    ///
    public func close(reason: String? = nil) async throws {
        do {
            if let reason {
                try await writer.closeWithReason(reason: reason)
            } else {
                try await writer.close()
            }
        } catch let error as LiveKitUniFFI.DataStreamError {
            throw StreamError(error)
        }
    }

    init(_ writer: LiveKitUniFFI.TextStreamWriter, encryptionType: EncryptionType) {
        self.writer = writer
        info = TextStreamInfo(writer.info(), encryptionType: encryptionType)
    }
}
