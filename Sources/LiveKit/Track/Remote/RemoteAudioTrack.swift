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

import AVFoundation
import CoreMedia

internal import LiveKitWebRTC

@objc
public class RemoteAudioTrack: Track, RemoteTrack, AudioTrack, @unchecked Sendable {
    /// Volume with range 0.0 - 1.0
    public var volume: Double {
        get {
            guard let audioTrack = mediaTrack as? LKRTCAudioTrack else { return 0 }
            return audioTrack.source.volume / 10
        }
        set {
            guard let audioTrack = mediaTrack as? LKRTCAudioTrack else { return }
            audioTrack.source.volume = newValue * 10
        }
    }

    private lazy var _adapter = AudioRendererAdapter()

    init(name: String,
         source: Track.Source,
         track: LKRTCMediaStreamTrack,
         reportStatistics: Bool)
    {
        super.init(name: name,
                   kind: .audio,
                   source: source,
                   track: track,
                   reportStatistics: reportStatistics)

        if let audioTrack = mediaTrack as? LKRTCAudioTrack {
            audioTrack.add(_adapter)
        }
    }

    deinit {
        if let audioTrack = mediaTrack as? LKRTCAudioTrack {
            audioTrack.remove(_adapter)
        }
    }

    public func add(audioRenderer: AudioRenderer) {
        _adapter.add(delegate: audioRenderer)
    }

    public func remove(audioRenderer: AudioRenderer) {
        _adapter.remove(delegate: audioRenderer)
    }
}
