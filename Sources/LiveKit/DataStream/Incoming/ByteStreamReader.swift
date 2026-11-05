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
import Foundation

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
    private let progressTask = StateSync<AnyTaskCancellable?>(nil)

    init(_ reader: any LiveKitFFI.ByteStreamReaderProtocol) {
        self.reader = reader
    }

    deinit {
        progressTask.copy()?.cancel()
        // The core ends the stream when it releases its reader, which it cannot do while a
        // cancelled `progress` wait still holds it. Closing ends that wait too.
        reader.close()
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
    /// The sequence keeps the reader, and so the stream, alive until it finishes or its iteration
    /// is cancelled, also after you release the reader. Cancelling the iteration does not end the
    /// stream. An update that the iteration was waiting for is released when the stream ends or the
    /// reader is released.
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
        // next update, the end of the stream or the reader's release, so an iteration started
        // after it waits for that.
        // The producer holds the reader until the sequence finishes or is cancelled. Each wait holds
        // only the core reader, so a cancelled one cannot keep the reader from closing it.
        AsyncStream(unfolding: { [self] in
            try? await abandoningOnCancel { [reader] in await reader.nextProgress().map(StreamProgress.init) }
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
    /// The destination is created exclusively: if anything already exists at that path the write
    /// fails and the existing file is left untouched, rather than being replaced. A symlink at the
    /// path is not followed. The sender chooses the name, so replacing whatever happens to sit
    /// there is not a safe default; pass `nameOverride`, or a directory you control, to write to a
    /// specific destination.
    ///
    /// A transfer that fails or is cancelled part-way leaves the partial file behind. Because the
    /// destination is created exclusively, retrying with the same name then fails with
    /// ``StreamError/io(reason:)`` — remove the partial file, or retry under a different name.
    ///
    /// - Returns: The URL of the written file on disk.
    /// - Throws: ``StreamError/notDirectory`` if `directory` is not a directory. Note this checks
    ///   the URL's shape, not that the directory exists.
    ///   ``StreamError/invalidFileName`` if the file name is not a single plain path component,
    ///   for example one that contains `/`, `\` or NUL, or is `..`. The sender chooses the name in
    ///   the stream information, so this check keeps the file inside `directory`.
    ///   ``StreamError/io(reason:)`` if the destination cannot be created — because something is
    ///   already there, or because `directory` does not exist, or for any other `open` failure.
    ///   Another ``StreamError`` if reading the stream fails. `CancellationError` if the calling
    ///   task is cancelled while reading. Cancelling the read closes the stream, so a later read
    ///   throws ``StreamError/alreadyClosed``. The file holds what was written so far.
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

        // Created exclusively: the sender chooses the name, so an existing file must not be
        // truncated and a symlink at that path must not be followed out of `directory`.
        let writer: AsyncFileStream<WriteMode>
        do {
            writer = try AsyncFileStream(creatingNewAt: fileURL)
        } catch let AsyncFileStream<WriteMode>.Error.openFailed(code) {
            // Every open failure becomes `.io`, not just `EEXIST`. `AsyncFileStream.Error` is
            // internal, so letting it out of this public API hands the caller an error they
            // cannot name or match — `directory` only has to *look* like a directory to reach
            // here, so a path that does not exist arrives as `ENOENT`.
            throw StreamError.io(reason: Self.openFailureReason(code, at: fileURL))
        }
        defer { writer.close() }
        for try await chunk in self {
            try await writer.write(chunk)
        }
        return fileURL
    }

    /// Describes a failed `open` for ``StreamError/io(reason:)``.
    private static func openFailureReason(_ code: Int32, at url: URL) -> String {
        if code == EEXIST {
            return "A file already exists at \(url.path)"
        }
        return "Could not open \(url.path): \(String(cString: strerror(code)))"
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

@available(*, deprecated, message: "Use for/await on ByteStreamReader reader instead.")
public extension ByteStreamReader {
    @objc
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
    ///
    /// The observation ends when the stream ends, the reader is released, or
    /// ``stopReadingProgress()`` is called. Calling this again replaces the previous observation.
    /// Keep the reader alive while observing; the callback should not retain it.
    @objc
    @available(*, deprecated, message: "Use for/await on ByteStreamReader progress instead.")
    func readProgress(onProgress: @Sendable @escaping (StreamProgress) -> Void) {
        progressTask.mutate { task in
            task?.cancel()
            task = Task { [reader] in
                while !Task.isCancelled,
                      let progress = try? await abandoningOnCancel({ [reader] in await reader.nextProgress() })
                {
                    guard !Task.isCancelled else { return }
                    onProgress(StreamProgress(progress))
                }
            }.cancellable()
        }
    }

    /// Cancels the observation started by ``readProgress(onProgress:)`` without closing the stream.
    ///
    /// The callback and observation are released even if the core's progress wait is still pending.
    /// A callback already in flight may finish. The core wait may remain until another update or
    /// stream closure, and a later observation may wait behind it. Releasing the reader closes
    /// the stream and pending wait. Ordinary Swift ``progress`` iteration is unaffected.
    @objc
    func stopReadingProgress() {
        progressTask.mutate {
            $0?.cancel()
            $0 = nil
        }
    }
}
