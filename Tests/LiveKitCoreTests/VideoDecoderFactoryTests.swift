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
struct VideoDecoderFactoryTests {
    final class FakeDecoder: VideoDecoder, Sendable {
        struct State {
            var callback: VideoDecoderCallback?
            var frame: EncodedVideoFrame?
            var missingFrames = false
            var renderTimeMs: Int64 = 0
            var numberOfCores = 0
            var releaseCount = 0
        }

        let implementationName = "FakeDecoder"
        let state = StateSync(State())
        let status: VideoDecoderStatus

        init(status: VideoDecoderStatus = .ok) {
            self.status = status
        }

        func setCallback(_ callback: VideoDecoderCallback?) {
            state.mutate { $0.callback = callback }
        }

        func startDecode(numberOfCores: Int) -> VideoDecoderStatus {
            state.mutate { $0.numberOfCores = numberOfCores }
            return status
        }

        func decode(_ frame: EncodedVideoFrame, missingFrames: Bool, renderTimeMs: Int64) -> VideoDecoderStatus {
            state.mutate {
                $0.frame = frame
                $0.missingFrames = missingFrames
                $0.renderTimeMs = renderTimeMs
            }
            return status
        }

        func releaseDecoder() -> VideoDecoderStatus {
            state.mutate { $0.releaseCount += 1 }
            return status
        }
    }

    struct FakeFactory: VideoDecoderFactory {
        let supportedCodecs: [VideoCodecInfo]
        var decoder: FakeDecoder?
        func createDecoder(for _: VideoCodecInfo) -> (any VideoDecoder)? { decoder }
    }

    // Immutable native objects, only used synchronously in each test.
    final class NativeFactory: NSObject, LKRTCVideoDecoderFactory {
        let codec: LKRTCVideoCodecInfo
        let decoder: any LKRTCVideoDecoder

        init(codec: LKRTCVideoCodecInfo, decoder: any LKRTCVideoDecoder) {
            self.codec = codec
            self.decoder = decoder
        }

        func supportedCodecs() -> [LKRTCVideoCodecInfo] { [codec] }
        func createDecoder(_: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? { decoder }
    }

    func makeImage() -> LKRTCEncodedImage {
        let image = LKRTCEncodedImage()
        image.buffer = Data(repeating: 0x65, count: 64)
        image.encodedWidth = 16
        image.encodedHeight = 16
        image.timeStamp = 0xFEDC_BA98
        image.captureTimeMs = 123
        image.ntpTimeMs = 456
        image.rotation = ._90
        image.frameType = .videoFrameKey
        image.qp = 24
        return image
    }

    func makeFrame(timestamp: UInt32) throws -> VideoFrame {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer)
        return try VideoFrame(dimensions: Dimensions(width: 16, height: 16),
                              rotation: ._90,
                              timeStampNs: 123_000_000,
                              rtpTimestamp: timestamp,
                              buffer: CVPixelVideoBuffer(pixelBuffer: #require(pixelBuffer)))
    }

    @Test(arguments: ["VP8", "VP9", "AV1", "H264"])
    func fallbackReturnsNativeObject(name: String) throws {
        let codec = VideoCodecInfo(name: name).toRTCType()
        let native = try #require(LKRTCDefaultVideoDecoderFactory().createDecoder(codec))
        let adapter = VideoDecoderFactoryAdapter(factory: FakeFactory(supportedCodecs: []),
                                                 supportedCodecs: [],
                                                 fallback: NativeFactory(codec: codec, decoder: native))
        let returned = try #require(adapter.createDecoder(codec))
        #expect(returned === native)
    }

    @Test func customFactoryTakesPriorityAndNativeCodecsRemainAdvertised() {
        let native = LKRTCDefaultVideoDecoderFactory()
        let codec = VideoCodecInfo(name: "VP8")
        let factory = FakeFactory(supportedCodecs: [], decoder: FakeDecoder())
        let adapter = VideoDecoderFactoryAdapter(factory: factory, supportedCodecs: [codec], fallback: native)
        #expect(adapter.createDecoder(codec.toRTCType()) is VideoDecoderAdapter)
        let advertised = adapter.supportedCodecs().map { VideoCodecInfo(fromRTCType: $0) }
        #expect(advertised.first == codec)
        for info in native.supportedCodecs() {
            #expect(advertised.contains(VideoCodecInfo(fromRTCType: info)))
        }
        #expect(advertised.filter { $0 == codec }.count == 1)
    }

    @Test func receivesOwnedBytesAndMetadata() throws {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 1)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0x65, count: 64)
        let image = makeImage()
        image.buffer = NSData(bytesNoCopy: bytes, length: 64, freeWhenDone: false) as Data
        let decoder = FakeDecoder()
        let adapter = VideoDecoderAdapter(decoder: decoder)
        #expect(adapter.decode(image, missingFrames: true, codecSpecificInfo: nil, renderTimeMs: 789) == 0)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        #expect(image.buffer == Data(repeating: 0, count: 64))
        let frame = try #require(decoder.state.frame)
        #expect(frame.data == Data(repeating: 0x65, count: 64))
        #expect(frame.dimensions == Dimensions(width: 16, height: 16))
        #expect(frame.rtpTimestamp == 0xFEDC_BA98)
        #expect(frame.captureTimeMs == 123)
        #expect(frame.ntpTimeMs == 456)
        #expect(frame.rotation == ._90)
        #expect(frame.frameType == .key)
        #expect(frame.qp == 24)
        #expect(decoder.state.missingFrames)
        #expect(decoder.state.renderTimeMs == 789)
    }

    @Test func outputPreservesTimestampAndStopsAfterRelease() async throws {
        let decoder = FakeDecoder()
        let adapter = VideoDecoderAdapter(decoder: decoder)
        let timestamps = StateSync<[UInt32]>([])
        adapter.setCallback { frame in
            timestamps.mutate { $0.append(UInt32(bitPattern: frame.timeStamp)) }
            #expect(frame.width == 16)
            #expect(frame.rotation == ._90)
            #expect(frame.timeStampNs == 123_000_000)
        }
        let callback = try #require(decoder.state.callback)
        #expect(adapter.decode(makeImage(), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: -1) == 0)
        let encoded = try #require(decoder.state.frame)
        let output = try makeFrame(timestamp: encoded.rtpTimestamp)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { callback(output) }
        }
        try callback(makeFrame(timestamp: 0))
        #expect(timestamps.read { $0 } == [0xFEDC_BA98, 0])
        #expect(adapter.release() == 0)
        try callback(makeFrame(timestamp: 42))
        #expect(timestamps.read { $0.count } == 2)
        #expect(decoder.state.releaseCount == 1)
    }

    @Test func callbackReplacement() throws {
        let decoder = FakeDecoder()
        let adapter = VideoDecoderAdapter(decoder: decoder)
        let deliveries = StateSync(0)
        adapter.setCallback { _ in Issue.record("Replaced callback invoked") }
        let callback = try #require(decoder.state.callback)
        adapter.setCallback { _ in deliveries.mutate { $0 += 1 } }
        try callback(makeFrame(timestamp: 1))
        #expect(deliveries.read { $0 } == 1)
    }

    @Test func unsupportedBufferIsDropped() throws {
        struct UnsupportedBuffer: VideoBuffer {}
        let decoder = FakeDecoder()
        let adapter = VideoDecoderAdapter(decoder: decoder)
        adapter.setCallback { _ in Issue.record("Unsupported buffer delivered") }
        let callback = try #require(decoder.state.callback)
        callback(VideoFrame(dimensions: Dimensions(width: 16, height: 16), rotation: ._0,
                            timeStampNs: 0, buffer: UnsupportedBuffer()))
    }

    @Test func releaseClearsDecoderCallback() {
        let decoder = FakeDecoder()
        let adapter = VideoDecoderAdapter(decoder: decoder)
        adapter.setCallback { _ in }
        #expect(decoder.state.callback != nil)
        #expect(adapter.release() == 0)
        #expect(decoder.state.callback == nil)
    }

    @Test(arguments: [
        (VideoDecoderStatus.ok, 0), (.noOutput, 1), (.okRequestKeyframe, 4),
        (.error, -1), (.memory, -3), (.invalidParameter, -4),
        (.timeout, -6), (.uninitialized, -7), (.init(rawValue: -99), -99),
    ])
    func statusMapping(status: VideoDecoderStatus, rawValue: Int) {
        #expect(status.rawValue == rawValue)
        let decoder = FakeDecoder(status: status)
        let adapter = VideoDecoderAdapter(decoder: decoder)
        #expect(adapter.startDecode(withNumberOfCores: 4) == rawValue)
        #expect(decoder.state.numberOfCores == 4)
        #expect(adapter.decode(makeImage(), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: -1) == rawValue)
        #expect(adapter.release() == rawValue)
        #expect(adapter.implementationName() == "FakeDecoder")
    }

    @Test(arguments: [false, true])
    func registrationGuardsAreIndependent(peerConnectionInitialized: Bool) {
        var state = RTC.PeerConnectionFactoryState()
        state.isInitialized = peerConnectionInitialized
        state.isDecoderFactoryInitialized = !peerConnectionInitialized
        let error = #expect(throws: LiveKitError.self) {
            try state.set(videoDecoderFactory: nil, codecs: [])
        }
        #expect(error?.type == .invalidState)
    }

    @Test func codecDeduplicationPreservesPacketizationModes() {
        let custom = VideoCodecInfo(name: "H264", parameters: ["packetization-mode": "1"])
        let native = LKRTCDefaultVideoDecoderFactory()
        let adapter = VideoDecoderFactoryAdapter(factory: FakeFactory(supportedCodecs: [custom]),
                                                 supportedCodecs: [custom], fallback: native)
        let advertised = adapter.supportedCodecs().map { VideoCodecInfo(fromRTCType: $0) }
        #expect(advertised.filter { $0.isSameCodec(as: custom) }.count == 1)
        let modeZero = VideoCodecInfo(name: "H264")
        let modeZeroAdapter = VideoDecoderFactoryAdapter(factory: FakeFactory(supportedCodecs: [modeZero]),
                                                         supportedCodecs: [modeZero], fallback: native)
        #expect(modeZeroAdapter.supportedCodecs().first?.parameters["packetization-mode"] == nil)
        #expect(modeZeroAdapter.supportedCodecs().contains { VideoCodecInfo(fromRTCType: $0).isSameCodec(as: custom) })
    }

    @Test func registrationAfterInitializationThrows() async {
        // Registration is process-global. A successful registration would affect other tests.
        _ = RTC.decoderFactory
        let error = #expect(throws: LiveKitError.self) {
            try LiveKitSDK.set(videoDecoderFactory: FakeFactory(supportedCodecs: []))
        }
        #expect(error?.type == .invalidState)
        await RTC.run { _ = RTC.peerConnectionFactory }
        let resetError = #expect(throws: LiveKitError.self) {
            try LiveKitSDK.set(videoDecoderFactory: nil)
        }
        #expect(resetError?.type == .invalidState)
    }
}
