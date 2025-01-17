/*
 * Copyright 2025 LiveKit
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

import AVFAudio

public class AudioMixerSource {
    public let identifier: String
    public let playerNode = AVAudioPlayerNode()
    var scheduledFrames: UInt32 = 0

    required init(identifier: String) {
        self.identifier = identifier
    }
}

public class AudioMixingRenderer {
    public let processingFormat: AVAudioFormat
    public let maximumFrameCount: AVAudioFrameCount

    private let engine = AVAudioEngine()
    public var sources = [String: AudioMixerSource]()
    private let renderBuffer: AVAudioPCMBuffer

    // MARK: - Public

    public required init(processingFormat: AVAudioFormat, maximumFrameCount: AVAudioFrameCount) {
        self.processingFormat = processingFormat
        self.maximumFrameCount = maximumFrameCount
        renderBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: maximumFrameCount)!
    }

    public func attach(identifier: String) -> Bool {
        guard sources[identifier] == nil else { return false }

        let source = AudioMixerSource(identifier: identifier)
        engine.attach(source.playerNode)
        sources[identifier] = source

        return true
    }

    public func detach(identifier: String) -> Bool {
        guard let source = sources[identifier] else { return false }
        engine.detach(source.playerNode)
        sources.removeValue(forKey: identifier)

        return true
    }

    public func start() throws {
        for source in sources.values {
            engine.connect(source.playerNode, to: engine.mainMixerNode, format: processingFormat)
        }

        try engine.enableManualRenderingMode(.offline, format: processingFormat, maximumFrameCount: maximumFrameCount)
        try engine.start()

        for source in sources.values {
            source.playerNode.play()
        }
    }

    public func stop() {
        for source in sources.values {
            source.playerNode.stop()
        }
        engine.stop()
    }

    public func appendBuffer(identifier: String, pcmBuffer: AVAudioPCMBuffer) {
        if let source = sources[identifier] {
            source.playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
            source.scheduledFrames += pcmBuffer.frameLength
        }
    }

    public func render() throws -> AVAudioEngineManualRenderingStatus {
        // Get minimum number of scheduled frames across all sources
        guard !sources.isEmpty else {
            return .insufficientDataFromInputNode
        }
        
        let minScheduledFrames = sources.values.map { $0.scheduledFrames }.min() ?? 0
        guard minScheduledFrames > 0 else {
            return .insufficientDataFromInputNode
        }
        
        // Use the minimum available frames, but don't exceed maximum
        let framesToRender = min(AVAudioFrameCount(minScheduledFrames), engine.manualRenderingMaximumFrameCount)
        let status = try engine.renderOffline(framesToRender, to: renderBuffer)

        switch status {
        case .success:
            // Update all sources' scheduled frames count
            for source in sources.values {
                source.scheduledFrames -= UInt32(framesToRender)
            }
            return .success
        case .insufficientDataFromInputNode: return .insufficientDataFromInputNode
        case .cannotDoInCurrentContext: return .cannotDoInCurrentContext
        case .error: return .error
        @unknown default: return .error
        }
    }
}
