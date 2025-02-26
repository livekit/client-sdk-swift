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
    
    let source: StreamReader<Data>

    init(info: ByteStreamInfo, source: StreamReaderSource) {
        self.info = info
        self.source = StreamReader(source: source)
    }
    
    public func makeAsyncIterator() -> StreamReader<Data>.Iterator {
        source.makeAsyncIterator()
    }
    
    /// Reads incoming chunks from the byte stream, concatenating them into a single data object which is returned
    /// once the stream closes normally.
    ///
    /// - Returns: The data consisting of all concatenated chunks.
    /// - Throws: ``StreamError`` if an error occurs while reading the stream.
    ///
    public func readAll() async throws -> Data {
        try await source.readAll()
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
    /// - Throws: ``StreamError`` if an error occurs while reading the stream.
    ///
    public func readToFile(
        in directory: URL = FileManager.default.temporaryDirectory,
        name nameOverride: String? = nil
    ) async throws -> URL {
        guard directory.hasDirectoryPath else {
            throw StreamError.notDirectory
        }
        let fileName = resolveFileName(override: nameOverride)
        let fileURL = directory.appendingPathComponent(fileName)
        
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        
        try await Task {
            for try await chunk in self {
                guard #available(macOS 10.15.4, iOS 13.4, *) else {
                    handle.write(chunk)
                    return
                }
                try handle.write(contentsOf: chunk)
            }
        }.value
        
        try handle.close()
        return fileURL
    }
    
    private func resolveFileName(override: String?) -> String {
        Self.resolveFileName(
            setName: override ?? info.name,
            fallbackName: info.id,
            mimeType: info.mimeType,
            fallbackExtension: "bin"
        )
    }
    
    /// Resolves the filename used when writing the stream to disk.
    ///
    /// - Parameters:
    ///   - setName: The name set by the user or taken from stream metadata.
    ///   - fallbackName: Name to fallback on when `setName` is `nil`.
    ///   - mimeType: MIME type used for determining file extension.
    ///   - fallbackExtension: File extension to fallback on when MIME type cannot be resolved.
    /// - Returns: The resolved file name.
    ///
    static func resolveFileName(
        setName: String?,
        fallbackName: String,
        mimeType: String,
        fallbackExtension: String
    ) -> String {
        var resolvedExtension: String {
            FileInfo.preferredExtension(for: mimeType) ?? fallbackExtension
        }
        guard let setName else {
            return "\(fallbackName).\(resolvedExtension)"
        }
        guard setName.pathExtension != nil else {
            return "\(setName).\(resolvedExtension)"
        }
        return setName
    }
}

// MARK: - Objective-C compatibility

public extension ByteStreamReader {
    @objc
    @available(*, unavailable, message: "Use async readAll() method instead.")
    func readAll(onCompletion: @escaping (Data) -> Void, onError: ((Error?) -> Void)?) {
        source.readAll(onCompletion: onCompletion, onError: onError)
    }
    
    @objc
    @available(*, unavailable, message: "Use for/await on ByteStreamReader reader instead.")
    func readChunks(onChunk: @escaping (Data) -> Void, onCompletion: ((Error?) -> Void)?) {
        source.readChunks(onChunk: onChunk, onCompletion: onCompletion)
    }
    
    @objc
    @available(*, unavailable, message: "Use async readToFile(in:name:) method instead.")
    internal func readToFile(
        in directory: URL,
        name nameOverride: String?,
        onCompletion: @escaping (URL) -> Void,
        onError: ((Error) -> Void)?
    ) {
        Task {
            do { try onCompletion(await self.readToFile(in: directory, name: nameOverride)) }
            catch { onError?(error) }
        }
    }
}
