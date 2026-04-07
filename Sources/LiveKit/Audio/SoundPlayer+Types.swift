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

@preconcurrency import AVFAudio
import Foundation

@globalActor
public actor SoundPlayerActor {
    public static let shared = SoundPlayerActor()

    private init() {}
}

/// Options for controlling sound playback behavior.
public struct SoundPlaybackOptions: Sendable {
    /// How to handle existing playback of the same sound.
    public enum Mode: Sendable {
        /// Play concurrently with any existing playback of the same sound.
        case concurrent
        /// Stop any existing playback of the same sound before playing.
        ///
        /// Replacement is scoped by prepared sound, not by destination. Existing
        /// local and remote playback for the same handle are both stopped before
        /// the new playback starts.
        case replace
    }

    /// Where the sound should be played.
    public enum Destination: Sendable {
        /// Play locally only (through device speakers).
        case local
        /// Play for remote participants only (through WebRTC).
        ///
        /// Remote playback is best-effort. If the WebRTC mixer input path is unavailable
        /// (for example, no active remote-routing path is connected), playback is skipped.
        case remote
        /// Play both locally and for remote participants.
        ///
        /// Remote playback is best-effort and may be skipped when the WebRTC mixer input path
        /// is unavailable.
        case localAndRemote

        var includesLocal: Bool {
            self == .local || self == .localAndRemote
        }

        var includesRemote: Bool {
            self == .remote || self == .localAndRemote
        }
    }

    public var mode: Mode
    public var loop: Bool
    public var destination: Destination

    public init(mode: Mode = .concurrent, loop: Bool = false, destination: Destination = .localAndRemote) {
        self.mode = mode
        self.loop = loop
        self.destination = destination
    }
}

/// Typed reference to a prepared sound managed by ``SoundPlayer``.
///
/// `SoundHandle` is a value type, so it is safe to store in SwiftUI state, pass through
/// view models, and copy. It does not own the underlying sound resource; call ``release()``
/// when the prepared sound is no longer needed.
///
/// Use ``SoundPlayer/prepare(fileURL:named:)`` to create a handle. If a sound was prepared
/// with a name, use ``SoundPlayer/sound(named:)`` to look up the current handle for that name.
public struct SoundHandle: Hashable, Sendable {
    let id: UUID

    /// Plays this prepared sound with the provided options.
    public func play(options: SoundPlaybackOptions = SoundPlaybackOptions()) async throws {
        try await SoundPlayer.shared.play(self, options: options)
    }

    /// Stops active local and/or remote playback for this prepared sound.
    public func stop(destination: SoundPlaybackOptions.Destination = .localAndRemote) async {
        await SoundPlayer.shared.stop(self, destination: destination)
    }

    /// Releases this prepared sound and its audio session requirement.
    ///
    /// Other copies of the same handle become invalid after release.
    public func release() async {
        await SoundPlayer.shared.release(self)
    }

    /// Returns `true` if this handle still refers to a prepared sound.
    public var isPrepared: Bool {
        get async {
            await SoundPlayer.shared.isPrepared(self)
        }
    }

    /// Returns `true` if this prepared sound has active playback for the selected destination.
    public func isPlaying(destination: SoundPlaybackOptions.Destination = .localAndRemote) async -> Bool {
        await SoundPlayer.shared.isPlaying(self, destination: destination)
    }
}

@SoundPlayerActor
class PreparedSound {
    let name: String?
    let sourceBuffer: AVAudioPCMBuffer
    let sessionRequirementHandle: SessionRequirementHandle
    var cachedLocalBuffer: AVAudioPCMBuffer?
    var cachedLocalBufferFormat: AVAudioFormat?
    var local: [SoundPlayback] = []
    var remote: [SoundPlayback] = []

    init(name: String?, sourceBuffer: AVAudioPCMBuffer, sessionRequirementHandle: SessionRequirementHandle) {
        self.name = name
        self.sourceBuffer = sourceBuffer
        self.sessionRequirementHandle = sessionRequirementHandle
    }

    func cleanUp() {
        local.removeAll { !$0.isPlaying }
        remote.removeAll { !$0.isPlaying }
    }

    func stop(destination: SoundPlaybackOptions.Destination) async {
        if destination.includesLocal {
            for playback in local { await playback.stop() }
        }
        if destination.includesRemote {
            for playback in remote { await playback.stop() }
        }
        cleanUp()
    }

    func localBuffer(for playerNodeFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if let cachedLocalBuffer, let cachedLocalBufferFormat, cachedLocalBufferFormat == playerNodeFormat {
            return cachedLocalBuffer
        }

        let localBuffer: AVAudioPCMBuffer
        if sourceBuffer.format == playerNodeFormat {
            localBuffer = sourceBuffer
        } else {
            let outputBufferCapacity = AudioConverter.frameCapacity(from: sourceBuffer.format,
                                                                    to: playerNodeFormat,
                                                                    inputFrameCount: sourceBuffer.frameLength)
            guard let converter = AudioConverter(from: sourceBuffer.format,
                                                 to: playerNodeFormat,
                                                 outputBufferCapacity: outputBufferCapacity)
            else {
                throw LiveKitError(.soundPlayer, message: "Failed to create audio converter")
            }
            localBuffer = converter.convert(from: sourceBuffer)
        }

        cachedLocalBuffer = localBuffer
        cachedLocalBufferFormat = playerNodeFormat
        return localBuffer
    }
}

struct LocalEngineState {
    var connectedOutputFormat: AVAudioFormat?
    var playerNodeFormat: AVAudioFormat?
    var needsReconnect = false

    init(connectedOutputFormat: AVAudioFormat? = nil,
         playerNodeFormat: AVAudioFormat? = nil,
         needsReconnect: Bool = false)
    {
        self.connectedOutputFormat = connectedOutputFormat
        self.playerNodeFormat = playerNodeFormat
        self.needsReconnect = needsReconnect
    }
}
