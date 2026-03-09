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

@preconcurrency import AVFoundation
@testable import LiveKit

public extension LKTestCase {
    // Static variable to store the downloaded sample video URL
    #if swift(>=6.0)
    nonisolated(unsafe) static var cachedSampleVideoURL: URL?
    #else
    static var cachedSampleVideoURL: URL?
    #endif

    // Creates a LocalVideoTrack with BufferCapturer, generates frames for approx 30 seconds
    func createSampleVideoTrack(targetFps: Int = 30, _ onCapture: @Sendable @escaping (CMSampleBuffer) -> Void) async throws -> (Task<Void, any Error>) {
        // Sample video
        let url = URL(string: "https://storage.unxpected.co.jp/public/sample-videos/ocean-1080p.mp4")!
        let tempLocalUrl: URL

        // Check if we already have the file downloaded
        if let cachedURL = LKTestCase.cachedSampleVideoURL, FileManager.default.fileExists(atPath: cachedURL.path) {
            print("Using cached sample video at \(cachedURL)...")
            tempLocalUrl = cachedURL
        } else {
            // Download if not available
            print("Downloading sample video from \(url)...")
            let (downloadedLocalUrl, _) = try await URLSession.shared.downloadBackport(from: url)

            // Move the file to a new temporary location with a more descriptive name
            tempLocalUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sample-video-cached").appendingPathExtension("mp4")

            // Remove existing file if present
            if FileManager.default.fileExists(atPath: tempLocalUrl.path) {
                try FileManager.default.removeItem(at: tempLocalUrl)
            }

            try FileManager.default.moveItem(at: downloadedLocalUrl, to: tempLocalUrl)

            // Cache the URL for future use
            LKTestCase.cachedSampleVideoURL = tempLocalUrl
            print("Cached sample video at \(tempLocalUrl)")
        }

        print("Opening \(tempLocalUrl) with asset reader...")
        let asset = AVAsset(url: tempLocalUrl)
        let assetReader = try AVAssetReader(asset: asset)

        let tracks = try await {
            #if os(visionOS)
            return try await asset.loadTracks(withMediaType: .video)
            #else
            if #available(iOS 15.0, macOS 12.0, *) {
                return try await asset.loadTracks(withMediaType: .video)
            } else {
                return asset.tracks(withMediaType: .video)
            }
            #endif
        }()

        guard let track = tracks.first else {
            XCTFail("No video track found in sample video file")
            fatalError()
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        assetReader.add(trackOutput)

        // Start reading...
        guard assetReader.startReading() else {
            XCTFail("Could not start reading the asset.")
            fatalError()
        }

        return Task.detached {
            let frameDuration = UInt64(1_000_000_000 / targetFps)
            while !Task.isCancelled, assetReader.status == .reading, let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                onCapture(sampleBuffer)
                // Sleep for the frame duration to regulate to ~30 fps
                try await Task.sleep(nanoseconds: frameDuration)
            }
        }
    }
}

public typealias OnDidRenderFirstFrame = (_ id: String) -> Void

public class VideoTrackWatcher: TrackDelegate, VideoRenderer, @unchecked Sendable {
    // MARK: - Public

    public var didRenderFirstFrame: Bool { _state.didRenderFirstFrame }
    public var detectedCodecs: Set<String> { _state.detectedCodecs }

    private struct State {
        var didRenderFirstFrame: Bool = false
        var expectationsForDimensions: [Dimensions: XCTestExpectation] = [:]
        var expectationsForCodecs: [VideoCodec: XCTestExpectation] = [:]
        var detectedCodecs: Set<String> = []
    }

    public let id: String
    private let _state = StateSync(State())
    private let onDidRenderFirstFrame: OnDidRenderFirstFrame?

    public init(id: String, onDidRenderFirstFrame: OnDidRenderFirstFrame? = nil) {
        self.id = id
        self.onDidRenderFirstFrame = onDidRenderFirstFrame
    }

    public func reset() {
        _state.mutate {
            $0.didRenderFirstFrame = false
            $0.detectedCodecs.removeAll()
        }
    }

    public func expect(dimensions: Dimensions) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Did render dimension \(dimensions)")
        expectation.assertForOverFulfill = false

        return _state.mutate {
            $0.expectationsForDimensions[dimensions] = expectation
            return expectation
        }
    }

    public func expect(codec: VideoCodec) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Did receive codec \(codec.name)")
        expectation.assertForOverFulfill = false

        return _state.mutate {
            $0.expectationsForCodecs[codec] = expectation
            return expectation
        }
    }

    public func isCodecDetected(codec: VideoCodec) -> Bool {
        _state.read { $0.detectedCodecs.contains(codec.name) }
    }

    // MARK: - VideoRenderer

    public var isAdaptiveStreamEnabled: Bool { true }

    public var adaptiveStreamSize: CGSize { .init(width: 1920, height: 1080) }

    public func set(size: CGSize) {
        print("\(type(of: self)) set(size: \(size))")
    }

    public func render(frame: LiveKit.VideoFrame) {
        _state.mutate {
            if !$0.didRenderFirstFrame {
                $0.didRenderFirstFrame = true
                onDidRenderFirstFrame?(id)
            }

            for (key, value) in $0.expectationsForDimensions where frame.dimensions.area >= key.area {
                value.fulfill()
            }
        }
    }

    // MARK: - TrackDelegate

    public func track(_: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        guard let stream = statistics.inboundRtpStream.first else { return }
        var segments: [String] = []

        let codecsString = statistics.codec.compactMap(\.mimeType).map { "'\($0)'" }.joined(separator: ", ")
        print("statistics codecs: \(codecsString), count: \(statistics.codec.count)")

        if let codec = statistics.codec.first(where: { $0.id == stream.codecId }), let mimeType = codec.mimeType {
            segments.append("codec: \(mimeType.lowercased())")

            // Extract codec id from mimeType (e.g., "video/vp8" -> "vp8")
            if let codecName = mimeType.split(separator: "/").last?.lowercased() {
                _state.mutate {
                    // Add to detected codecs
                    $0.detectedCodecs.insert(codecName)

                    // Check if any codec expectations match
                    for (expectedCodec, expectation) in $0.expectationsForCodecs where expectedCodec.name.lowercased() == codecName {
                        expectation.fulfill()
                    }
                }
            }
        }

        if let width = stream.frameWidth, let height = stream.frameHeight {
            segments.append("dimensions: \(width)x\(height)")
        }

        if let fps = stream.framesPerSecond {
            segments.append("fps: \(fps)")
        }

        print("\(type(of: self)) didUpdateStatistics (\(segments.joined(separator: ", ")))")
    }
}

public class AudioTrackWatcher: AudioRenderer, @unchecked Sendable {
    public let id: String
    public var didRenderFirstFrame: Bool { _state.didRenderFirstFrame }

    // MARK: - Private

    private let onDidRenderFirstFrame: OnDidRenderFirstFrame?

    private struct State {
        var didRenderFirstFrame: Bool = false
    }

    private let _state = StateSync(State())

    public init(id: String, onDidRenderFirstFrame: OnDidRenderFirstFrame? = nil) {
        self.id = id
        self.onDidRenderFirstFrame = onDidRenderFirstFrame
    }

    public func reset() {
        _state.mutate {
            $0.didRenderFirstFrame = false
        }
    }

    public func render(pcmBuffer: AVAudioPCMBuffer) {
        _state.mutate {
            if !$0.didRenderFirstFrame {
                print("did receive first audio frame: \(String(describing: pcmBuffer))")
                $0.didRenderFirstFrame = true
                onDidRenderFirstFrame?(id)
            }
        }
    }
}
