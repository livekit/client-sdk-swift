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

/// Perform asynchronous file I/O.
struct AsyncFileStream<Mode>: Loggable {
    // Adapted from implementation by Andy Finnell:
    // https://losingfight.com/blog/2024/04/22/reading-and-writing-files-in-swift-asyncawait/

    enum Error: Swift.Error {
        case notFileURL
        case closed
        case openFailed(Int32)
        case readFailed(Int32)
        case writeFailed(Int32)
    }

    private let queue: DispatchQueue
    private let fileDescriptor: Int32
    private let io: DispatchIO
    private var isClosed = false

    private init(url: URL, mode: Int32) throws {
        guard url.isFileURL else {
            throw Error.notFileURL
        }
        let queue = DispatchQueue(label: "AsyncFileStream")
        let fileDescriptor = open(url.absoluteURL.path, mode, 0o666)

        guard fileDescriptor != -1 else {
            throw Error.openFailed(errno)
        }

        self.queue = queue
        self.fileDescriptor = fileDescriptor
        io = DispatchIO(
            type: .stream,
            fileDescriptor: fileDescriptor,
            queue: queue,
            cleanupHandler: { [fileDescriptor] _ in
                Darwin.close(fileDescriptor)
            }
        )
    }

    func close() {
        guard !isClosed else { return }
        io.close()
    }
}

enum ReadMode {}
enum WriteMode {}

extension AsyncFileStream where Mode == ReadMode {
    private static let mode = O_RDONLY

    init(readingFrom url: URL) throws {
        self = try Self(url: url, mode: Self.mode)
    }

    func read(maxLength: Int) async throws -> Data {
        guard !isClosed else { throw Error.closed }
        return try await withCheckedThrowingContinuation { continuation in
            var buffer = DispatchData.empty
            io.read(offset: 0, length: maxLength, queue: queue) { done, data, error in
                if let data { buffer.append(data) }
                guard done else { return }

                guard error == 0 else {
                    continuation.resume(throwing: Error.readFailed(error))
                    return
                }
                continuation.resume(returning: Data(buffer))
            }
        }
    }

    struct AsyncChunks: AsyncSequence, AsyncIteratorProtocol {
        fileprivate let chunkSize: Int
        fileprivate let stream: AsyncFileStream

        mutating func next() async throws -> Data? {
            let chunk = try await stream.read(maxLength: chunkSize)
            guard !chunk.isEmpty else {
                stream.close()
                return nil
            }
            return chunk
        }

        func makeAsyncIterator() -> Self { self }

        #if swift(<5.11)
        typealias AsyncIterator = Self
        typealias Element = Data
        #endif
    }

    func chunks(ofSize chunkSize: Int = 4096) -> AsyncChunks {
        AsyncChunks(chunkSize: chunkSize, stream: self)
    }
}

extension AsyncFileStream where Mode == WriteMode {
    private static let mode = O_WRONLY | O_TRUNC | O_CREAT

    init(writingTo url: URL) throws {
        self = try Self(url: url, mode: Self.mode)
    }

    func write(_ data: Data) async throws {
        guard !isClosed else { throw Error.closed }
        return try await withCheckedThrowingContinuation { continuation in
            io.write(offset: 0, data: DispatchData(data), queue: queue) { done, _, error in
                guard done else { return }

                guard error == 0 else {
                    continuation.resume(throwing: Error.writeFailed(error))
                    return
                }
                continuation.resume()
            }
        }
    }
}

private extension DispatchData {
    init(_ data: Data) {
        self = data.withUnsafeBytes { DispatchData(bytes: $0) }
    }
}
