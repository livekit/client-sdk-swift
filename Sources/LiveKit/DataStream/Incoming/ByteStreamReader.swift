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
@objcMembers
public final class ByteStreamReader: NSObject, AsyncSequence, Sendable {
    /// Information about the incoming byte stream.
    public let info: ByteStreamInfo

    /// The core's reader, by its protocol so a test can stand in for it.
    private let reader: any LiveKitFFI.ByteStreamReaderProtocol

    /// Bytes the core has handed over so far, through any iterator, `readAll()`, or a read that a
    /// cancel abandoned. One count per stream, so the length check at its end holds however the
    /// stream was read.
    private let receivedLength = StateSync(0)

    /// Runs each read of the core's reader together with its count and end check, one at a time.
    /// A read that a cancel abandoned keeps running here, so a later read waits until it has
    /// counted its chunk.
    private let reads = SerialRunnerActor<Data?>()

    init(_ reader: any LiveKitFFI.ByteStreamReaderProtocol, info: ByteStreamInfo) {
        self.reader = reader
        self.info = info
    }

    /// Reads incoming chunks from the byte stream, concatenating them into a single data object which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The data consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream, or
    ///   `CancellationError` at once if the calling task is cancelled. The chunk in flight at the
    ///   cancel is dropped, so a later read of the stream misses it.
    ///
    public func readAll() async throws -> Data {
        // ponytail: chunk by chunk, so a cancel stops the collection after at most one chunk, but
        // the core keeps buffering the rest of the stream until it ends. Releasing it early needs
        // a per-reader close in the FFI.
        var result = Data()
        for try await chunk in self {
            result.append(chunk)
        }
        return result
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
        do {
            // Counted inside the operation, so a chunk that an abandoned read takes still counts.
            return try await abandoningOnCancel { [reader, reads, receivedLength, declaredLength = info.totalLength] in
                try await reads.run {
                    guard let chunk = try await reader.next() else {
                        if let error = StreamError(receivedLength: receivedLength.copy(), declaredLength: declaredLength) { throw error }
                        return nil
                    }
                    receivedLength.mutate { $0 += chunk.count }
                    return chunk
                }
            }
        } catch let error as LiveKitFFI.DataStreamError {
            throw StreamError(error)
        }
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
}
