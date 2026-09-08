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

import CoreVideo
import Foundation
@testable import LiveKit
import LiveKitWebRTC
import Testing

@Suite(.tags(.media))
struct VideoEncoderFactoryTests {
    final class FakeEncoder: VideoEncoder, @unchecked Sendable {
        let implementationName = "FakeEncoder"
        private(set) var callback: VideoEncoderCallback?
        private(set) var setCallbackCount = 0
        private(set) var releaseCount = 0
        private(set) var lastFrameTypes: [EncodedVideoFrame.FrameType] = []

        func setCallback(_ callback: VideoEncoderCallback?) {
            self.callback = callback
            setCallbackCount += 1
        }

        func startEncode(with _: VideoEncoderSettings, numberOfCores _: Int) -> VideoEncoderStatus { .ok }

        func encode(_: VideoFrame, frameTypes: [EncodedVideoFrame.FrameType]) -> VideoEncoderStatus {
            lastFrameTypes = frameTypes
            return .ok
        }

        func setBitrate(_: UInt32, framerate _: UInt32) -> VideoEncoderStatus { .ok }

        func releaseEncoder() -> VideoEncoderStatus {
            releaseCount += 1
            return .ok
        }
    }

    final class FakeFactory: VideoEncoderFactory {
        let supportedCodecs: [VideoCodecInfo]
        let encoder: FakeEncoder

        init(_ codecs: [VideoCodecInfo], encoder: FakeEncoder = FakeEncoder()) {
            supportedCodecs = codecs
            self.encoder = encoder
        }

        func createEncoder(for _: VideoCodecInfo) -> (any VideoEncoder)? { encoder }
    }

    let h264 = VideoCodecInfo(name: "H264", parameters: ["packetization-mode": "1"])

    func makeEncodedFrame(packetizationMode: EncodedVideoFrame.PacketizationMode? = nil, qp: Int? = nil) -> EncodedVideoFrame {
        EncodedVideoFrame(data: Data([0, 0, 0, 1, 0x65]),
                          dimensions: Dimensions(width: 16, height: 16),
                          rtpTimestamp: 90000,
                          frameType: .key,
                          qp: qp,
                          packetizationMode: packetizationMode)
    }

    func makeRTCFrame() throws -> LKRTCVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer)
        let buffer = try LKRTCCVPixelBuffer(pixelBuffer: #require(pixelBuffer))
        let frame = LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 1_000_000)
        frame.timeStamp = 90000
        return frame
    }

    // MARK: - set(videoEncoderFactory:) validation

    @Test func rejectsEmptyCodecList() {
        let error = #expect(throws: LiveKitError.self) {
            try LiveKitSDK.set(videoEncoderFactory: FakeFactory([]))
        }
        #expect(error?.type == .invalidParameter)
    }

    @Test(arguments: ["VP8", "VP9", "AV1"])
    func rejectsUnbridgeableCodec(name: String) {
        let error = #expect(throws: LiveKitError.self) {
            try LiveKitSDK.set(videoEncoderFactory: FakeFactory([VideoCodecInfo(name: name)]))
        }
        #expect(error?.type == .invalidParameter)
    }

    // MARK: - Codec normalization

    @Test func h264WithoutPacketizationModeAdvertisesModeOne() {
        let normalized = VideoCodecInfo(name: "H264").normalizedForAdvertising()
        #expect(normalized.parameters["packetization-mode"] == "1")
    }

    @Test func explicitPacketizationModeIsKept() {
        let codec = VideoCodecInfo(name: "H264", parameters: ["packetization-mode": "0"])
        #expect(codec.normalizedForAdvertising().parameters["packetization-mode"] == "0")
        #expect(codec.negotiatedPacketizationMode == .singleNalUnit)
        #expect(h264.negotiatedPacketizationMode == .nonInterleaved)
    }

    @Test func h265IsNotNormalized() {
        let codec = VideoCodecInfo(name: "H265")
        #expect(codec.normalizedForAdvertising().parameters.isEmpty)
    }

    // MARK: - Factory adapter

    @Test func adapterDeclinesCodecsItDidNotAdvertise() {
        let adapter = VideoEncoderFactoryAdapter(factory: FakeFactory([h264]), supportedCodecs: [h264])
        #expect(adapter.supportedCodecs().map(\.name) == ["H264"])
        #expect(adapter.createEncoder(h264.toRTCType()) != nil)
        #expect(adapter.createEncoder(VideoCodecInfo(name: "VP8").toRTCType()) == nil)
        #expect(adapter.createEncoder(VideoCodecInfo(name: "H265").toRTCType()) == nil)
    }

    @Test func adapterUsesSnapshotNotFactoryList() {
        // The factory claims H264 and VP8, but only the validated snapshot counts.
        let factory = FakeFactory([h264, VideoCodecInfo(name: "VP8")])
        let adapter = VideoEncoderFactoryAdapter(factory: factory, supportedCodecs: [h264])
        #expect(adapter.supportedCodecs().map(\.name) == ["H264"])
        #expect(adapter.createEncoder(VideoCodecInfo(name: "VP8").toRTCType()) == nil)
    }

    // MARK: - Encoder adapter

    @Test func frameTypesKeepArityAndMapUnknownToDelta() throws {
        let factory = FakeFactory([h264])
        let encoder = try #require(VideoEncoderFactoryAdapter(factory: factory, supportedCodecs: [h264]).createEncoder(h264.toRTCType()))
        // Key, an audio frame type WebRTC never sends for video, delta.
        let status = try encoder.encode(makeRTCFrame(), codecSpecificInfo: nil, frameTypes: [3, 1, 4])
        #expect(status == VideoEncoderStatus.ok.rawValue)
        #expect(factory.encoder.lastFrameTypes == [.key, .delta, .delta])
    }

    @Test func callbackIsAttachedOnceAndDroppedAfterRelease() throws {
        let factory = FakeFactory([h264])
        let encoder = try #require(VideoEncoderFactoryAdapter(factory: factory, supportedCodecs: [h264]).createEncoder(h264.toRTCType()))
        let delivered = StateSync(0)

        encoder.setCallback { _, _ in delivered.mutate { $0 += 1 }; return true }
        encoder.setCallback { _, _ in delivered.mutate { $0 += 1 }; return true }
        // Consecutive registrations reuse the closure handed to the encoder.
        #expect(factory.encoder.setCallbackCount == 1)

        let frame = makeEncodedFrame()
        #expect(factory.encoder.callback?(frame) == true)
        #expect(delivered.read { $0 } == 1)

        // Release clears the box: a stale delivery is dropped without reaching WebRTC.
        _ = encoder.release()
        #expect(factory.encoder.callback?(frame) == false)
        #expect(delivered.read { $0 } == 1)

        // Registering again after release attaches a fresh closure.
        encoder.setCallback { _, _ in true }
        #expect(factory.encoder.setCallbackCount == 2)
        #expect(factory.encoder.callback?(frame) == true)

        // Clearing forwards nil to the encoder.
        encoder.setCallback(nil)
        #expect(factory.encoder.callback == nil)
    }

    // MARK: - Encoded frame conversion

    @Test func codecInfoFollowsEncoderCodec() {
        let (image, info) = makeEncodedFrame().toRTCType(codec: h264)
        #expect(image.timeStamp == 90000)
        #expect(image.frameType == .videoFrameKey)
        #expect(image.qp.intValue == -1)
        let h264Info = info as? LKRTCCodecSpecificInfoH264
        #expect(h264Info?.packetizationMode == .nonInterleaved)
    }

    @Test func packetizationModeFollowsNegotiatedParameterThenFrame() {
        let modeZero = VideoCodecInfo(name: "H264", parameters: ["packetization-mode": "0"])
        let (_, negotiated) = makeEncodedFrame().toRTCType(codec: modeZero)
        #expect((negotiated as? LKRTCCodecSpecificInfoH264)?.packetizationMode == .singleNalUnit)

        let (_, explicit) = makeEncodedFrame(packetizationMode: .singleNalUnit).toRTCType(codec: h264)
        #expect((explicit as? LKRTCCodecSpecificInfoH264)?.packetizationMode == .singleNalUnit)
    }

    @Test func h265GetsH265Info() {
        let (image, info) = makeEncodedFrame(qp: 30).toRTCType(codec: VideoCodecInfo(name: "H265"))
        #expect(info is LKRTCCodecSpecificInfoH265)
        #expect(image.qp.intValue == 30)
    }
}
