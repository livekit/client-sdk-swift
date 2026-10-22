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

/// An asynchronous sequence of chunks read from a byte data stream.
///
/// Cancelling a task that reads the stream ends the stream: the read throws `CancellationError`,
/// and a later read throws ``StreamError/alreadyClosed``.
@objcMembers
public final class ByteStreamReader: NSObject, AsyncSequence, Sendable {
    /// Information about the incoming byte stream.
    ///
    /// Once the stream has ended, ``StreamInfo/attributes`` also holds the attributes the sender
    /// set when it closed the stream. They replace header attributes with the same key.
    public var info: ByteStreamInfo {
        let info = reader.info()
        return ByteStreamInfo(info, encryptionType: EncryptionType(info.encryptionType))
    }

    /// The core's reader, by its protocol so a test can stand in for it.
    private let reader: any LiveKitFFI.ByteStreamReaderProtocol

    init(_ reader: any LiveKitFFI.ByteStreamReaderProtocol) {
        self.reader = reader
    }

    /// Reads incoming chunks from the byte stream, concatenating them into a single data object which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The data consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream, or
    ///   `CancellationError` at once if the calling task is cancelled. The cancel ends the stream,
    ///   so a later read throws ``StreamError/alreadyClosed``.
    ///
    public func readAll() async throws -> Data {
        try await StreamError.reading(closingOnCancel: reader.close) { try await reader.readAll() }
    }

    /// The progress of the stream as its bytes arrive, until the stream ends.
    ///
    /// Progress counts the bytes received from the sender, after decompression, not the bytes read
    /// so far. ``StreamProgress/bytesTotal`` is the size the sender declared, or `nil` if it
    /// declared none. Updates that arrive between two iterations merge into the latest one, and the
    /// last update is the stream's final progress. Iterate it from one task at a time.
    ///
    /// ```swift
    /// Task {
    ///     for await progress in reader.progress {
    ///         print("Received \(progress.bytesProcessed) bytes")
    ///     }
    /// }
    /// let data = try await reader.readAll()
    /// ```
    public var progress: AsyncStream<StreamProgress> {
        // ponytail: a cancel abandons the core's wait, which keeps the reader's progress until its
        // next update or the end of the stream, so an iteration started after it waits for that.
        AsyncStream(unfolding: { [reader] in
            try? await abandoningOnCancel { await reader.nextProgress().map(StreamProgress.init) }
        })
    }

    /// An asynchronous iterator of incoming chunks.
    public struct AsyncChunks: AsyncIteratorProtocol {
        fileprivate let stream: ByteStreamReader

        public mutating func next() async throws -> Data? {
            try await stream.nextChunk()
        }
    }

    public func makeAsyncIterator() -> AsyncChunks {
        AsyncChunks(stream: self)
    }

    private func nextChunk() async throws -> Data? {
        try await StreamError.reading(closingOnCancel: reader.close) { try await reader.next() }
    }
}

extension ByteStreamReader {
    /// Reads incoming chunks from the byte stream, writing them to a file as they are received.
    ///
    /// - Parameters:
    ///   - directory: The directory to write the file in. The system temporary directory is used if not specified.
    ///   - nameOverride: The name to use for the written file. If not specified, file name and extension will be automatically
    ///                   inferred from the stream information.
    /// - Returns: The URL of the written file on disk.
    /// - Throws: ``StreamError/notDirectory`` if `directory` is not a directory.
    ///   ``StreamError/invalidFileName`` if the file name is not a single plain path component,
    ///   for example one that contains `/`, `\` or NUL, or is `..`. The sender chooses the name in
    ///   the stream information, so this check keeps the file inside `directory`. Another
    ///   ``StreamError`` if reading the stream fails. `CancellationError` at once if the calling task
    ///   is cancelled; the file then holds what was written so far.
    ///
    public func writeToFile(
        in directory: URL = FileManager.default.temporaryDirectory,
        name nameOverride: String? = nil,
    ) async throws -> URL {
        guard directory.hasDirectoryPath else {
            throw StreamError.notDirectory
        }
        let preferredName = nameOverride ?? info.name
        let fileName = Self.resolveFileName(
            preferredName: preferredName,
            fallbackName: info.id,
            mimeType: info.mimeType,
        )
        guard Self.isPlainFileName(preferredName ?? info.id), Self.isPlainFileName(fileName) else {
            throw StreamError.invalidFileName
        }
        let fileURL = directory.appendingPathComponent(fileName)

        let writer = try AsyncFileStream(writingTo: fileURL)
        defer { writer.close() }
        for try await chunk in self {
            try await writer.write(chunk)
        }
        return fileURL
    }

    /// Resolves the filename used when writing the stream to disk.
    ///
    /// - Parameters:
    ///   - preferredName: The name set by the user or taken from stream metadata.
    ///   - fallbackName: Name to fallback on when `setName` is `nil`.
    ///   - mimeType: MIME type used for determining file extension when unavailable.
    /// - Returns: The resolved file name.
    ///
    static func resolveFileName(
        preferredName: String?,
        fallbackName: String,
        mimeType: String,
    ) -> String {
        var resolvedExtension: String {
            FileInfo.preferredExtension(for: mimeType) ?? Self.defaultFileExtension
        }
        guard let preferredName else {
            return "\(fallbackName).\(resolvedExtension)"
        }
        guard preferredName.pathExtension != nil else {
            return "\(preferredName).\(resolvedExtension)"
        }
        return preferredName
    }

    /// Whether `name` names a file directly inside the directory it is appended to, on any
    /// platform: no path separator (`/` or `\`) and no NUL, which file APIs treat as the end.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains { "/\\\u{0}".utf8.contains($0) }
    }

    private static let defaultFileExtension = "bin"
}

// MARK: - Objective-C compatibility

public extension ByteStreamReader {
    @objc
    @available(*, deprecated, message: "Use for/await on ByteStreamReader reader instead.")
    func readChunks(onChunk: @Sendable @escaping (Data) -> Void, onCompletion: (@Sendable (Error?) -> Void)?) {
        Task {
            do {
                for try await chunk in self {
                    onChunk(chunk)
                }
                onCompletion?(nil)
            } catch {
                onCompletion?(error)
            }
        }
    }

    /// Calls `onProgress` with each update of ``progress``, for Objective-C callers.
    @objc
    @available(*, deprecated, message: "Use for/await on ByteStreamReader progress instead.")
    func readProgress(onProgress: @Sendable @escaping (StreamProgress) -> Void) {
        Task {
            for await progress in self.progress {
                onProgress(progress)
            }
        }
    }
}
