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

/// An asynchronous sequence of chunks read from a byte data stream.
@objc
public final class ByteStreamReader: NSObject, AsyncSequence, Sendable {
    /// Information about the incoming byte stream.
    @objc
    public let info: ByteStreamInfo

    let source: StreamReaderSource

    init(info: ByteStreamInfo, source: StreamReaderSource) {
        self.info = info
        self.source = source
    }

    /// Reads incoming chunks from the byte stream, concatenating them into a single data object which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The data consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream.
    ///
    @objc
    public func readAll() async throws -> Data {
        try await source.collect()
    }

    /// An asynchronous iterator of incoming chunks.
    public struct AsyncChunks: AsyncIteratorProtocol {
        fileprivate var source: StreamReaderSource.Iterator

        public mutating func next() async throws -> Data? {
            try await source.next()
        }
    }

    public func makeAsyncIterator() -> AsyncChunks {
        AsyncChunks(source: source.makeAsyncIterator())
    }

    #if swift(<5.11)
    public typealias Element = Data
    public typealias AsyncIterator = AsyncChunks
    #endif
}

extension ByteStreamReader {
    /// Reads incoming chunks from the byte stream, writing them to a file as they are received.
    ///
    /// - Parameters:
    ///   - directory: The directory to write the file in. The system temporary directory is used if not specified.
    ///   - nameOverride: The name to use for the written file. If not specified, file name and extension will be automatically
    ///                   inferred from the stream information.
    /// - Returns: The URL of the written file on disk.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream.
    ///
    @objc
    public func writeToFile(
        in directory: URL = FileManager.default.temporaryDirectory,
        name nameOverride: String? = nil
    ) async throws -> URL {
        guard directory.hasDirectoryPath else {
            throw StreamError.notDirectory
        }
        let fileName = Self.resolveFileName(
            preferredName: nameOverride ?? info.name,
            fallbackName: info.id,
            mimeType: info.mimeType
        )
        let fileURL = directory.appendingPathComponent(fileName)

        try await Task {
            let writer = try AsyncFileStream(writingTo: fileURL)
            defer { writer.close() }

            for try await chunk in self {
                try await writer.write(chunk)
            }
        }.value

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
        mimeType: String
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
