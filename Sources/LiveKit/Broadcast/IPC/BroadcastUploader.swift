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

#if os(iOS)

import CoreMedia
import ReplayKit

/// Uploads broadcast samples to another process.
final class BroadcastUploader: Sendable, Loggable {
    private let channel: IPCChannel

    private let imageCodec = BroadcastImageCodec()
    private let audioCodec = BroadcastAudioCodec()

    private struct State {
        var isUploadingImage = false
        var shouldUploadAudio = false
        var messageLoopTask: AnyTaskCancellable?
    }

    private let state = StateSync(State())

    enum Error: Swift.Error {
        case unsupportedSample
        case connectionClosed
    }

    /// Creates an uploader with an open connection to another process.
    init(socketPath: SocketPath) async throws {
        let channel = try await IPCChannel(connectingTo: socketPath)
        self.channel = channel

        let messageLoopTask = channel.incomingMessages(BroadcastIPCHeader.self).subscribe(self) { observer, message in
            observer.processMessageHeader(message.0)
        } onFailure: { observer, error in
            observer.log("IPCChannel returned error: \(error)")
        }
        state.mutate { $0.messageLoopTask = messageLoopTask }
    }

    deinit {
        close()
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
    func upload(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) throws {
        guard !isClosed else {
            throw Error.connectionClosed
        }
        switch type {
        case .video:
            let canUpload = state.mutate {
                guard !$0.isUploadingImage else { return false }
                $0.isUploadingImage = true
                return true
            }
            guard canUpload else { return }

            let rotation = VideoRotation(sampleBuffer.replayKitOrientation ?? .up)
            do {
                let (metadata, imageData) = try imageCodec.encode(sampleBuffer)
                Task {
                    let header = BroadcastIPCHeader.image(metadata, rotation)
                    try await channel.send(header: header, payload: imageData)
                    state.mutate { $0.isUploadingImage = false }
                }
            } catch {
                state.mutate { $0.isUploadingImage = false }
                throw error
            }
        case .audioApp:
            guard state.shouldUploadAudio else { return }
            let (metadata, audioData) = try audioCodec.encode(sampleBuffer)
            Task {
                let header = BroadcastIPCHeader.audio(metadata)
                try await channel.send(header: header, payload: audioData)
            }
        default:
            throw Error.unsupportedSample
        }
    }

    private func processMessageHeader(_ header: BroadcastIPCHeader) {
        switch header {
        case let .wantsAudio(wantsAudio):
            state.mutate { $0.shouldUploadAudio = wantsAudio }
        default:
            log("Unhandled incoming message: \(header)", .debug)
        }
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

#endif
