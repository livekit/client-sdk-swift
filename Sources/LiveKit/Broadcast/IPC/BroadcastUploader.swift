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

#if os(iOS)

import CoreMedia
import ReplayKit

/// Uploads broadcast samples to another process.
final class BroadcastUploader: Sendable {
    private let channel: IPCChannel
    private let imageCodec = BroadcastImageCodec()

    @Atomic private var isUploading = false

    enum Error: Swift.Error {
        case unsupportedSample
    }

    /// Creates an uploader with an open connection to another process.
    init(socketPath: SocketPath) async throws {
        channel = try await IPCChannel(connectingTo: socketPath)
    }

    /// Whether or not the connection to the receiver has been closed.
    var isClosed: Bool {
        channel.isClosed
    }

    /// Close the connection to the receiver.
    func close() {
        channel.close()
    }

    /// Upload a sample from ReplayKit.
    func upload(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) async throws {
        guard type == .video else { throw Error.unsupportedSample }
        guard !isUploading else { return }
        try await asyncDefer {
            isUploading = true
            try await sendImage(sampleBuffer)
        } defer: {
            isUploading = false
        }
    }

    private func sendImage(_ sampleBuffer: CMSampleBuffer) async throws {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw Error.unsupportedSample
        }
        let rotation = VideoRotation(sampleBuffer.replayKitOrientation ?? .up)

        let (metadata, imageData) = try imageCodec.encode(imageBuffer)
        let header = BroadcastIPCHeader.image(metadata, rotation)

        try await channel.send(header: header, payload: imageData)
    }
}

private extension CMSampleBuffer {
    /// Gets the video orientation attached by ReplayKit.
    var replayKitOrientation: CGImagePropertyOrientation? {
        guard let rawOrientation = CMGetAttachment(
            self,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        )?.uint32Value else { return nil }
        return CGImagePropertyOrientation(rawValue: rawOrientation)
    }
}

private extension VideoRotation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .left: self = ._90
        case .down: self = ._180
        case .right: self = ._270
        default: self = ._0
        }
    }
}

private func asyncDefer<T>(
    _ task: () async throws -> T,
    defer cleanUp: () -> Void
) async rethrows -> T {
    do {
        let result = try await task()
        cleanUp()
        return result
    } catch {
        cleanUp()
        throw error
    }
}

#endif
