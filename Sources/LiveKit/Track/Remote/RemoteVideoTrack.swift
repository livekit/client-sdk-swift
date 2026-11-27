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
internal import LiveKitWebRTC
import AVFoundation

@objcMembers
public class RemoteVideoTrack: Track, RemoteTrackProtocol, @unchecked Sendable {
    private let nativeFrames = StateSync<AnyTaskCancellable?>(nil)

    override func stopCapture() async throws {
        cancelStatisticsTimer()
        nativeFrames.mutate { $0 = nil }
    }

    init(name: String,
         source: Track.Source,
         track: RTCMediaTrack?,
         reportStatistics: Bool)
    {
        super.init(name: name,
                   kind: .video,
                   source: source,
                   track: track,
                   reportStatistics: reportStatistics)
    }
}

// MARK: - VideoTrack Protocol

extension RemoteVideoTrack: VideoTrackProtocol {
    /// - Note: Attaching a renderer blocks the calling thread until WebRTC's worker thread accepts
    ///   the sink; prefer letting ``VideoView`` manage the attach, which hops off the caller.
    public func add(videoRenderer: VideoRenderer) {
        let adapter = VideoRendererAdapter(renderer: videoRenderer)

        _state.mutate {
            $0.videoRendererAdapters.setObject(adapter, forKey: videoRenderer)
        }

        mediaTrack?.blocking {
            guard let rtcVideoTrack = $0 as? LKRTCVideoTrack else {
                log("mediaTrack is not a RTCVideoTrack", .error)
                return
            }
            rtcVideoTrack.add(adapter)
        }
    }

    /// - Note: Detaching a renderer blocks the calling thread until WebRTC's worker thread drops
    ///   the sink.
    public func remove(videoRenderer: VideoRenderer) {
        let adapter = _state.mutate {
            let adapter = $0.videoRendererAdapters.object(forKey: videoRenderer)
            $0.videoRendererAdapters.removeObject(forKey: videoRenderer)
            return adapter
        }

        guard let adapter else {
            log("No adapter found for videoRenderer", .warning)
            return
        }

        mediaTrack?.blocking {
            guard let rtcVideoTrack = $0 as? LKRTCVideoTrack else {
                log("mediaTrack is not a RTCVideoTrack", .error)
                return
            }
            rtcVideoTrack.remove(adapter)
        }
    }
}

extension RemoteVideoTrack {
    func receiveNativeVideo(_ native: NativeRemoteVideoTrack) async throws {
        let frames = try await native.frames(capacity: 2)
        nativeFrames.mutate {
            $0 = Task { [weak self] in
                do {
                    try await withTaskCancellationHandler {
                        while !Task.isCancelled, let frame = try await frames.next() {
                            guard let self else { return }
                            try self.renderNative(frame)
                        }
                    } onCancel: {
                        Task.detached { frames.cancel() }
                    }
                } catch { if !Task.isCancelled { self?.log("Native video sink ended: \(error)", .warning) } }
            }.cancellable()
        }
    }

    private func renderNative(_ frame: NativeVideoFrame) throws {
        guard frame.format == .bgra else { throw LiveKitError(.invalidParameter, message: "Native decoded video must be BGRA") }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(frame.width), Int(frame.height), kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { throw LiveKitError(.invalidState, message: "Pixel buffer allocation failed") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            frame.data.withUnsafeBytes { bytes in
                if let input = bytes.baseAddress {
                    for row in 0 ..< Int(frame.height) {
                        base.advanced(by: row * CVPixelBufferGetBytesPerRow(pixelBuffer)).copyMemory(from: input.advanced(by: row * Int(frame.stride)), byteCount: Int(frame.width) * 4)
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let dimensions = Dimensions(width: Int32(frame.width), height: Int32(frame.height))
        let video = VideoFrame(dimensions: dimensions, rotation: VideoRotation(rawValue: Int(frame.rotation)) ?? ._0,
                               timeStampNs: frame.timestampUs * 1000, buffer: CVPixelVideoBuffer(pixelBuffer: pixelBuffer))
        set(dimensions: dimensions)
        set(videoFrame: video)
        let renderers = _state.read { $0.videoRendererAdapters.objectEnumerator()?.allObjects.compactMap { ($0 as? VideoRendererAdapter)?.renderer } ?? [] }
        for renderer in renderers {
            renderer.set?(size: CGSize(width: Int(frame.width), height: Int(frame.height)))
            renderer.render?(frame: video)
            renderer.render?(frame: video, captureDevice: nil, captureOptions: nil)
        }
    }
}
