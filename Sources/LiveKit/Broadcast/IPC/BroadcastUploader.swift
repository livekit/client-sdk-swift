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

    private struct PendingFrame {
        let header: BroadcastIPCHeader
        let payload: Data
    }

    private struct State {
        var isSending = false
        var pendingFrame: PendingFrame?
        var shouldUploadAudio = false
        var messageLoopTask: AnyTaskCancellable?

        // Frame drop diagnostics
        var totalVideoFrames: Int = 0
        var droppedVideoFrames: Int = 0
        var totalEncodeTime: Double = 0
        var totalEncodedBytes: Int = 0
        var encodedFrameCount: Int = 0
        var lastLogTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
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
            state.mutate { $0.totalVideoFrames += 1 }

            let rotation = VideoRotation(sampleBuffer.replayKitOrientation ?? .up)
            let encodeStart = CFAbsoluteTimeGetCurrent()
            let (metadata, imageData) = try imageCodec.encode(sampleBuffer)
            let encodeTime = CFAbsoluteTimeGetCurrent() - encodeStart

            state.mutate {
                $0.totalEncodeTime += encodeTime
                $0.totalEncodedBytes += imageData.count
                $0.encodedFrameCount += 1
            }

            let frame = PendingFrame(
                header: .image(metadata, rotation),
                payload: imageData
            )

            let shouldSend = state.mutate {
                guard !$0.isSending else {
                    if $0.pendingFrame != nil { $0.droppedVideoFrames += 1 }
                    $0.pendingFrame = frame
                    return false
                }
                $0.isSending = true
                return true
            }

            if shouldSend {
                sendFrame(frame)
            }
            logPeriodicSummary()
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

    private func sendFrame(_ frame: PendingFrame) {
        Task {
            try await channel.send(header: frame.header, payload: frame.payload)
            let next = state.mutate { s -> PendingFrame? in
                if let pending = s.pendingFrame {
                    s.pendingFrame = nil
                    return pending
                }
                s.isSending = false
                return nil
            }
            if let next { sendFrame(next) }
        }
    }

    private func logPeriodicSummary() {
        let now = CFAbsoluteTimeGetCurrent()
        let snapshot = state.mutate { s -> (Int, Int, Double, Int, Int, Bool) in
            let elapsed = now - s.lastLogTime
            guard elapsed >= 5.0 else { return (0, 0, 0, 0, 0, false) }
            let result = (s.totalVideoFrames, s.droppedVideoFrames, s.totalEncodeTime, s.totalEncodedBytes, s.encodedFrameCount, true)
            s.totalVideoFrames = 0
            s.droppedVideoFrames = 0
            s.totalEncodeTime = 0
            s.totalEncodedBytes = 0
            s.encodedFrameCount = 0
            s.lastLogTime = now
            return result
        }
        guard snapshot.5 else { return }
        let (total, dropped, encodeTime, encodedBytes, encodedCount, _) = snapshot
        let dropPct = total > 0 ? Double(dropped) / Double(total) * 100 : 0
        let avgEncodeMs = encodedCount > 0 ? (encodeTime / Double(encodedCount)) * 1000 : 0
        let avgSizeKB = encodedCount > 0 ? encodedBytes / encodedCount / 1024 : 0
        log("[broadcast] frames: \(total), dropped: \(dropped) (\(String(format: "%.1f", dropPct))%), avgEncode: \(String(format: "%.1f", avgEncodeMs))ms, avgSize: \(avgSizeKB)KB", .info)
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
