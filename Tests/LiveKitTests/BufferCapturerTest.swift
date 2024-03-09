/*
 * Copyright 2024 LiveKit
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
import XCTest

class BufferCapturerTest: XCTestCase {
    @available(iOS 15.0, *)
    func testX() async throws {
        let url = URL(string: "https://storage.unxpected.co.jp/public/sample-videos/ocean-1080p.mp4")!

        print("Downloading...")
        let (tempLocalURL, _) = try await URLSession.shared.download(from: url)

        // Move the file to a new temporary location with a more descriptive name, if desired
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
        let targetURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")

        try fileManager.moveItem(at: tempLocalURL, to: targetURL)

        print("Opening \(targetURL)...")

        let asset = AVAsset(url: targetURL)

        let assetReader = try AVAssetReader(asset: asset)

        guard let track = asset.tracks(withMediaType: .video).first else {
            return
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings) // nil for outputSettings to get samples in their original format
        assetReader.add(trackOutput)

        try await with2Rooms { room1, _ in

            let bufferTrack = LocalVideoTrack.createBufferTrack()
            let bufferCapturer = bufferTrack.capturer as! BufferCapturer

            // Start reading...
            guard assetReader.startReading() else {
                XCTFail("Could not start reading the asset.")
                return
            }

            let readBufferTask = Task.detached {
                let frameDuration = UInt64(1_000_000_000 / 30) // 30 fps
                while !Task.isCancelled, let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                    // print("sampleBuffer: \(sampleBuffer)")
                    bufferCapturer.capture(sampleBuffer)
                    // Sleep for the frame duration to regulate to ~30 fps
                    try await Task.sleep(nanoseconds: frameDuration)
                }
            }

            try await room1.localParticipant.publish(videoTrack: bufferTrack)

            // Wait until finish reading buffer...
            try await readBufferTask.value
        }
    }
}
