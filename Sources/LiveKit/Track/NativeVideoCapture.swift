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
import AVFoundation

final class NativeVideoCapture: NSObject, VideoRenderer, Sendable {
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    private let continuation: AsyncStream<VideoFrame>.Continuation
    private let task: AnyTaskCancellable

    init(source: NativeLocalVideoTrack) {
        let (frames, continuation) = AsyncStream.makeStream(of: VideoFrame.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        task = Task {
            for await frame in frames {
                do {
                    _ = try await source.captureFrame(frame: Self.copy(frame))
                } catch {
                    if !Task.isCancelled { LiveKitSDK.log("Native video capture failed: \(error)", .error) }
                }
            }
        }.cancellable()
        super.init()
    }

    deinit { continuation.finish() }
    func render(frame: VideoFrame) { continuation.yield(frame) }

    private static func copy(_ frame: VideoFrame) throws -> NativeVideoFrame {
        guard let buffer = (frame.buffer as? CVPixelVideoBuffer)?.pixelBuffer else {
            throw LiveKitError(.invalidParameter, message: "Native capture needs an NV12 or BGRA pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var data = Data()
        let stride: Int
        let chromaStride: UInt32?
        let nativeFormat: NativeVideoPixelFormat
        if format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(buffer) {
            stride = CVPixelBufferGetBytesPerRow(buffer)
            chromaStride = nil
            nativeFormat = .bgra
            data.append(base.assumingMemoryBound(to: UInt8.self), count: stride * CVPixelBufferGetHeight(buffer))
        } else if [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(format),
                  let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        {
            stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            chromaStride = UInt32(uvStride)
            nativeFormat = .nv12
            data.append(y.assumingMemoryBound(to: UInt8.self), count: stride * CVPixelBufferGetHeightOfPlane(buffer, 0))
            data.append(uv.assumingMemoryBound(to: UInt8.self), count: uvStride * CVPixelBufferGetHeightOfPlane(buffer, 1))
        } else { throw LiveKitError(.invalidParameter, message: "Unsupported native capture pixel format") }
        return .init(format: nativeFormat, chromaStride: chromaStride, data: data,
                     width: UInt32(CVPixelBufferGetWidth(buffer)), height: UInt32(CVPixelBufferGetHeight(buffer)),
                     stride: UInt32(stride), timestampUs: frame.timeStampNs / 1000, rotation: UInt16(frame.rotation.rawValue))
    }
}
