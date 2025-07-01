/*
 * Copyright 2025 LiveKit
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

/// Asynchronously write to an open byte stream.
@objc
public final class ByteStreamWriter: NSObject, Sendable {
    /// Information about the outgoing byte stream.
    @objc
    public let info: ByteStreamInfo

    private let destination: StreamWriterDestination

    /// Whether or not the stream is still open.
    public var isOpen: Bool {
        get async { await destination.isOpen }
    }

    /// Write data to the stream.
    ///
    /// - Parameter data: Data to be sent.
    /// - Throws: Throws an error if the stream has been closed or data
    ///   cannot be sent to remote participants.
    ///
    public func write(_ data: Data) async throws {
        try await destination.write(data)
    }

    /// Close the stream.
    ///
    /// - Parameter reason: A textual description of why the stream is being closed. Absense
    ///   of a reason indicates a normal closure.
    /// - Throws: Throws an error if the stream has already been closed or closure
    ///   cannot be communicated to remote participants.
    ///
    public func close(reason: String? = nil) async throws {
        try await destination.close(reason: reason)
    }

    init(info: ByteStreamInfo, destination: StreamWriterDestination) {
        self.info = info
        self.destination = destination
    }
}

extension ByteStreamWriter {
    /// Write the contents of the file located at the given URL to the stream.
    func write(contentsOf fileURL: URL) async throws {
        try await Task { [weak self] in
            guard let self else { return }
            let reader = try AsyncFileStream(readingFrom: fileURL)
            for try await chunk in reader.chunks() {
                try await write(chunk)
            }
        }.value
    }

    private static let fileReadChunkSize = 4096
}

// MARK: - Objective-C compatibility

public extension ByteStreamWriter {
    @objc
    @available(*, unavailable, message: "Use async write(_:) method instead.")
    func write(_ data: Data, completion: @Sendable @escaping (Error?) -> Void) {
        Task {
            do { try await write(data) }
            catch { completion(error) }
        }
    }

    @objc
    @available(*, unavailable, message: "Use async close(reason:) method instead.")
    func close(reason: String?, completion: @Sendable @escaping (Error?) -> Void) {
        Task {
            do { try await close(reason: reason) }
            catch { completion(error) }
        }
    }
}
