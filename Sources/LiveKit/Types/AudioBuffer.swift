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

internal import LiveKitWebRTC
import Foundation

// Wrapper for LKRTCAudioBuffer
@objcMembers
public class LKAudioBuffer: NSObject {
    private let _audioBuffer: LKRTCAudioBuffer

    public var channels: Int { _audioBuffer.channels }

    public var frames: Int { _audioBuffer.frames }

    public var framesPerBand: Int { _audioBuffer.framesPerBand }

    public var bands: Int { _audioBuffer.bands }

    @available(*, deprecated, renamed: "rawBuffer(forChannel:)")
    public func rawBuffer(for channel: Int) -> UnsafeMutablePointer<Float> {
        _audioBuffer.rawBuffer(forChannel: channel)
    }

    public func rawBuffer(forChannel channel: Int) -> UnsafeMutablePointer<Float> {
        _audioBuffer.rawBuffer(forChannel: channel)
    }

    init(audioBuffer: LKRTCAudioBuffer) {
        _audioBuffer = audioBuffer
    }
}
