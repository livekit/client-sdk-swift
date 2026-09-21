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

#if (os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))) && canImport(ScreenCaptureKit)

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

internal import LiveKitWebRTC

/// Shared engine for ScreenCaptureKit-backed capturers across platforms.
///
/// Owns the `SCStream` lifecycle, sample-buffer delivery (``ScreenCaptureKit/SCStreamOutput``),
/// the stream delegate, frame capture, and the static-screen resend timer. Subclasses supply the
/// `SCContentFilter` and `SCStreamConfiguration` for their platform — see ``MacOSScreenCapturer``
/// (enumerated sources) and ``IOSScreenCapturer`` (system picker, iOS 27+).
@available(macOS 12.3, iOS 27.0, *)
public class SCStreamVideoCapturer: VideoCapturer, @unchecked Sendable {
    let capturer = RTC.createVideoCapturer()

    /// The ``ScreenShareCaptureOptions`` used for this capturer.
    public let options: ScreenShareCaptureOptions

    struct State {
        var scStream: SCStream?
        // Cached frame for resending to maintain a minimum of 1 fps
        var lastFrame: LKRTCVideoFrame?
        var resendTimer: AnyTaskCancellable?
        var startTask: AnyTaskCancellable?
    }

    let _screenCapturerState = StateSync(State())

    /// The active `SCStream` while capturing, otherwise `nil`.
    var scStream: SCStream? { _screenCapturerState.read { $0.scStream } }

    init(delegate: LKRTCVideoCapturerDelegate, options: ScreenShareCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    /// Creates the `SCStream` for `filter`/`configuration`, registers outputs, and stores it.
    ///
    /// Call `SCStream.startCapture()` on the returned stream to begin sample delivery.
    func makeStream(filter: SCContentFilter, configuration: SCStreamConfiguration) throws -> SCStream {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        if options.appAudio, #available(macOS 13.0, *) {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
        }
        _screenCapturerState.mutate { $0.scStream = stream }
        return stream
    }

    /// Stops and releases the active stream, if any.
    func teardownStream() async throws {
        guard let stream = _screenCapturerState.read({ $0.scStream }) else { return }

        // Stop resending paused frames
        _screenCapturerState.mutate {
            $0.resendTimer = nil
            $0.startTask = nil
        }

        try await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
        if options.appAudio, #available(macOS 13.0, *) {
            try? stream.removeStreamOutput(self, type: .audio)
        }

        _screenCapturerState.mutate { $0.scStream = nil }
    }

    // Common capture func
    private func capture(_ sampleBuffer: CMSampleBuffer, contentRect: CGRect, scaleFactor: CGFloat = 1.0) {
        // Get the pixel buffer that contains the image data.
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        let sourceDimensions = Dimensions(width: Int32((contentRect.width * scaleFactor).rounded(.down)),
                                          height: Int32((contentRect.height * scaleFactor).rounded(.down)))

        let targetDimensions = sourceDimensions
            .aspectFit(size: options.dimensions.max)
            .toEncodeSafeDimensions()

        let rtcPixelBuffer = LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer,
                                                adaptedWidth: targetDimensions.width,
                                                adaptedHeight: targetDimensions.height,
                                                cropWidth: sourceDimensions.width,
                                                cropHeight: sourceDimensions.height,
                                                cropX: Int32(contentRect.origin.x * scaleFactor),
                                                cropY: Int32(contentRect.origin.y * scaleFactor))

        let rtcFrame = LKRTCVideoFrame(buffer: rtcPixelBuffer,
                                       rotation: ._0,
                                       timeStampNs: timeStampNs)

        // Cache last frame
        _screenCapturerState.mutate {
            $0.lastFrame = rtcFrame
        }

        capture(frame: rtcFrame, capturer: capturer, options: options)
    }

    private func capturePreviousFrame() async throws {
        // Must be .started
        guard case .started = captureState else {
            log("CaptureState is not .started, resend timer should not trigger.", .warning)
            return
        }

        guard let frame = _screenCapturerState.read({ $0.lastFrame }) else { return }

        // create a new frame with new time stamp
        let newFrame = LKRTCVideoFrame(buffer: frame.buffer,
                                       rotation: frame.rotation,
                                       timeStampNs: Self.createTimeStampNs())

        // Feed frame to WebRTC
        capture(frame: newFrame, capturer: capturer, options: options)
    }

    // MARK: - SCStreamOutput

    // swiftlint:disable:next cyclomatic_complexity
    func handle(sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard case .started = captureState else {
            log("Skipping capture since captureState is not .started")
            return
        }

        // Return early if the sample buffer is invalid.
        guard sampleBuffer.isValid else { return }

        if case .audio = outputType {
            guard let pcm = sampleBuffer.toAVAudioPCMBuffer() else { return }
            AudioManager.shared.mixer.capture(appAudio: pcm)
        } else if case .screen = outputType {
            // Retrieve the array of metadata attachments from the sample buffer.
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                                 createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                let attachments = attachmentsArray.first else { return }

            // Validate the status of the frame. If it isn't `.complete`, return nil.
            guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else { return }

            // Retrieve the content rectangle, scale, and scale factor.
            guard let contentRectDict = attachments[.contentRect],
                  let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary), // swiftlint:disable:this force_cast
                  // let contentScale = attachments[.contentScale] as? CGFloat,
                  let scaleFactor = attachments[.scaleFactor] as? CGFloat else { return }

            // Schedule resend timer
            let newTimer = Task.detached(priority: .utility) { [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: UInt64(1 * 1_000_000_000))
                    if Task.isCancelled { break }
                    guard let self else { break }
                    try await capturePreviousFrame()
                }
            }.cancellable()

            _screenCapturerState.mutate {
                $0.resendTimer = newTimer
            }

            capture(sampleBuffer, contentRect: contentRect, scaleFactor: scaleFactor)
        }
    }
}

// MARK: - SCStreamDelegate

@available(macOS 12.3, iOS 27.0, *)
extension SCStreamVideoCapturer: SCStreamDelegate {
    public func stream(_: SCStream, didStopWithError error: any Error) {
        log("Stream stopped with error: \(error)", .error)
        Task.discarding { [weak self] in
            try await self?.stopCapture()
        }
    }
}

// MARK: - SCStreamOutput

@available(macOS 12.3, iOS 27.0, *)
extension SCStreamVideoCapturer: SCStreamOutput {
    public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of outputType: SCStreamOutputType)
    {
        handle(sampleBuffer: sampleBuffer, of: outputType)
    }
}

#endif
