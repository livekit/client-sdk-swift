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
    public var sources = [AudioMixerSource]()
    private let renderBuffer: AVAudioPCMBuffer

    // MARK: - Internal

    func indexOfSource(identifier: String) -> Int? {
        let index = sources.firstIndex { (source: AudioMixerSource) -> Bool in
            return source.identifier == identifier
        }

        return index
    }

    func containsOfSource(identifier: String) -> Bool {
        let isExist = (indexOfSource(identifier: identifier) != nil) ? true : false

        return isExist
    }

    // MARK: - Public

    public required init(processingFormat: AVAudioFormat, maximumFrameCount: AVAudioFrameCount) {
        self.processingFormat = processingFormat
        self.maximumFrameCount = maximumFrameCount
        renderBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: maximumFrameCount)!
    }

    public func attach(identifier: String) -> Bool {
        guard containsOfSource(identifier: identifier) == false else { return false }

        let source = AudioMixerSource(identifier: identifier)
        engine.attach(source.playerNode)
        sources.append(source)

        return true
    }

    public func detach(identifier: String) -> Bool {
        guard let index = indexOfSource(identifier: identifier) else { return false }
        let source = sources[index]
        engine.detach(source.playerNode)
        sources.remove(at: index)

        return true
    }

    public func start() throws {
        for source in sources {
            engine.connect(source.playerNode, to: engine.mainMixerNode, format: processingFormat)
        }

        try engine.enableManualRenderingMode(.offline, format: processingFormat, maximumFrameCount: maximumFrameCount)
        try engine.start()

        for source in sources {
            source.playerNode.play()
        }
    }

    public func stop() {
        for source in sources {
            source.playerNode.stop()
        }
        engine.stop()
    }

    public func appendBuffer(identifier: String, pcmBuffer: AVAudioPCMBuffer) {
        if let index = indexOfSource(identifier: identifier) {
            let source = sources[index]

            source.playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
            source.scheduledFrames += pcmBuffer.frameLength
        }
    }

    public func render() throws -> AVAudioEngineManualRenderingStatus {
        let renderSources = sources.filter { source -> Bool in
            return source.scheduledFrames >= self.engine.manualRenderingMaximumFrameCount
        }

        guard !renderSources.isEmpty else {
            return .insufficientDataFromInputNode
        }

        let status = try engine.renderOffline(engine.manualRenderingMaximumFrameCount, to: renderBuffer)

        switch status {
        case .success:
            for (_, source) in renderSources.enumerated() {
                source.scheduledFrames -= engine.manualRenderingMaximumFrameCount
            }
            return .success
        case .insufficientDataFromInputNode: return .insufficientDataFromInputNode
        case .cannotDoInCurrentContext: return .cannotDoInCurrentContext
        case .error: return .error
        @unknown default: return .error
        }
    }
}
