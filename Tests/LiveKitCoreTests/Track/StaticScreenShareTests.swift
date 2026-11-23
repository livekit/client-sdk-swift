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

import AVFoundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// A screen share source that delivers no buffers while the screen is static, as ReplayKit does,
/// must still reach a subscriber that joins after the last buffer.
@Suite(.serialized, .tags(.media, .e2e), TestLimits.e2e)
struct StaticScreenShareTests {
    enum Source: CaseIterable {
        case buffer
        #if os(iOS)
        /// The broadcast path without ReplayKit: uploader -> IPC socket -> `BroadcastScreenCapturer`.
        case broadcast
        #endif
    }

    @Test(arguments: Source.allCases)
    func lateSubscriberReceivesStaticShare(source: Source) async throws {
        let roomName = UUID().uuidString
        let publisher = RoomTestingOptions(roomName: roomName, identity: "publisher", isE2eeEnabled: false, canPublish: true)
        let viewer = RoomTestingOptions(roomName: roomName, identity: "viewer", isE2eeEnabled: false, canSubscribe: true)
        let lateViewer = RoomTestingOptions(roomName: roomName, identity: "late-viewer", isE2eeEnabled: false, canSubscribe: true)

        try await TestEnvironment.withRooms([publisher, viewer]) { rooms in
            let isScreenChanging = StateSync(true)
            let (track, screen) = try await makeShare(source, isScreenChanging: isScreenChanging)
            try await rooms[0].localParticipant.publish(videoTrack: track, options: VideoPublishOptions(simulcast: false))
            try await waitForFirstFrame(in: rooms[1], timeout: 20, of: "live share")

            isScreenChanging.mutate { $0 = false }
            try await Task.sleep(nanoseconds: 2_000_000_000)

            try await TestEnvironment.withRooms([lateViewer]) { late in
                try await waitForFirstFrame(in: late[0], timeout: 10, of: "static share")
            }
            screen.cancel()
        }
    }
}

/// A screen share track and the task that feeds it at 15 fps while `isScreenChanging` is `true`.
private func makeShare(_ source: StaticScreenShareTests.Source,
                       isScreenChanging: StateSync<Bool>) async throws -> (LocalVideoTrack, AnyTaskCancellable)
{
    let pixelBuffer = try makePixelBuffer(width: 1280, height: 720)

    switch source {
    case .buffer:
        let track = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: .h720_169))
        let capturer = try #require(track.capturer as? BufferCapturer)
        let screen = Task {
            while !Task.isCancelled {
                if isScreenChanging.copy() { capturer.capture(pixelBuffer) }
                try await Task.sleep(nanoseconds: 66_000_000)
            }
        }.cancellable()
        return (track, screen)
    #if os(iOS)
    case .broadcast:
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.temporaryDirectory.path)
        let socketPath = try #require(SocketPath(UUID().uuidString + ".sock"))
        let (track, capturer) = await RTC.run {
            let videoSource = RTC.createVideoSource(forScreenShare: true)
            let capturer = BroadcastScreenCapturer(delegate: videoSource, options: ScreenShareCaptureOptions(), socketPath: socketPath)
            return (LocalVideoTrack(name: Track.screenShareVideoName, source: .screenShareVideo, capturer: capturer,
                                    videoSource: videoSource, reportStatistics: false), capturer)
        }
        let sampleBuffer = try makeSampleBuffer(pixelBuffer)
        // The task keeps the uploader connected after the screen goes static, like an idle extension.
        let screen = Task {
            try await poll(timeout: 20, interval: 0.05, for: "capture start") { capturer.captureState == .started }
            try await Task.sleep(nanoseconds: 300_000_000)
            let uploader = try await BroadcastUploader(socketPath: socketPath)
            while !Task.isCancelled {
                if isScreenChanging.copy() { try uploader.upload(sampleBuffer, with: .video) }
                try await Task.sleep(nanoseconds: 66_000_000)
            }
        }.cancellable()
        return (track, screen)
    #endif
    }
}

private func waitForFirstFrame(in room: Room, timeout: TimeInterval, of description: String) async throws {
    let watcher = VideoTrackWatcher(id: "static-share")
    let isAttached = StateSync(false)
    try await poll(timeout: timeout, interval: 0.02, for: "first frame of a \(description)") {
        if !isAttached.copy(),
           let track = room.remoteParticipants.values.compactMap({ $0.videoTracks.first?.track as? RemoteVideoTrack }).first
        {
            track.add(videoRenderer: watcher)
            isAttached.mutate { $0 = true }
        }
        return watcher.didRenderFirstFrame
    }
}

#if os(iOS)
private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    try CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: #require(format), sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
    return try #require(sampleBuffer)
}
#endif

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
    let pixelBuffer = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(base, 0x80, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
    }
    return pixelBuffer
}
