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

/// Asynchronously write to an open text stream.
@objcMembers
public final class TextStreamWriter: NSObject, Sendable {
    /// Information about the outgoing text stream.
    public let info: TextStreamInfo

    private let destination: StreamWriterDestination

    /// Whether or not the stream is still open.
    public var isOpen: Bool {
        get async { await destination.isOpen }
    }

    /// Write text to the stream.
    ///
    /// - Parameter text: Text to be sent.
    /// - Throws: ``LiveKitError`` (`.dataStream`) wrapping the underlying `StreamError`
    ///   if the stream has been closed or text cannot be sent to remote participants.
    @nonobjc
    public func write(_ text: String) async throws(LiveKitError) {
        do {
            try await destination.write(text)
        } catch {
            throw LiveKitError(from: error)
        }
    }

    /// Close the stream.
    ///
    /// - Parameter reason: A textual description of why the stream is being closed. Absense
    ///   of a reason indicates a normal closure.
    /// - Throws: ``LiveKitError`` (`.dataStream`) wrapping the underlying `StreamError`
    ///   if the stream has already been closed or closure cannot be communicated to remote participants.
    @nonobjc
    public func close(reason: String? = nil) async throws(LiveKitError) {
        do {
            try await destination.close(reason: reason)
        } catch {
            throw LiveKitError(from: error)
        }
    }

    // MARK: - Obj-C bridges

    @available(swift, obsoleted: 1.0, message: "Use write(_:)")
    @objc(write:completionHandler:)
    public func _objc_write(_ text: String) async throws {
        try await write(text)
    }

    @available(swift, obsoleted: 1.0, message: "Use close(reason:)")
    @objc(closeWithReason:completionHandler:)
    public func _objc_close(reason: String? = nil) async throws {
        try await close(reason: reason)
    }

    init(info: TextStreamInfo, destination: StreamWriterDestination) {
        self.info = info
        self.destination = destination
    }
}
