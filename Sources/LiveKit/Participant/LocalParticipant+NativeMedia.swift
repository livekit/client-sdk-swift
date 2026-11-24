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

internal import LiveKitFFI
import Foundation

extension LocalParticipant {
    func publishNative(track: LocalTrack, options: TrackPublishOptions?) async throws -> LocalTrackPublication {
        let room = try requireRoom()
        let session = try room.requireNativeSession(forMedia: true)
        if let owner = track._state.nativeSession, owner !== session {
            throw LiveKitError(.invalidState, message: "Native source belongs to a different room session")
        }
        guard track.nativePublication.copy() == nil else { throw LiveKitError(.invalidState, message: "Track already published") }
        if let video = track as? LocalVideoTrack { return try await publishNativeVideo(video, options: options as? VideoPublishOptions) }
        guard let audio = track as? LocalAudioTrack else {
            throw LiveKitError(.invalidState, message: "Native video capture integration is pending")
        }
        let options = (options as? AudioPublishOptions) ?? room._state.roomOptions.defaultAudioPublishOptions
        guard options.encoding == nil, !options.preConnect, audio.captureOptions == AudioCaptureOptions() else {
            throw LiveKitError(.invalidParameter, message: "Native audio encoding and processing option mapping is pending")
        }
        let source: NativeLocalAudioTrack
        if let existing = audio.nativeAudio.copy(), (try? existing.info()) != nil {
            source = existing
        } else {
            try await LiveKitSDK.ensureMicrophoneAccessForRecording()
            source = try await session.createMicrophoneTrack(name: options.name ?? audio.name, deviceId: nil)
            audio.nativeAudio.mutate { $0 = source }
        }
        do {
            let native = try await source.publish(options: .init(source: .microphone, dtx: options.dtx, red: options.red, stream: options.streamName ?? ""))
            audio.nativePublication.mutate { $0 = native }
            try Task.checkCancellation()
            guard room.nativeSession.copy() === session else { throw CancellationError() }
            let info = try native.info()
            let publication = LocalTrackPublication(info: info, participant: self)
            audio._state.mutate {
                $0.nativeSession = session
                $0.sid = Track.Sid(from: info.sid)
                $0.trackState = .started
                $0.publishState = .published
                $0.lastPublishOptions = options
            }
            await publication.set(track: audio)
            guard room.nativeSession.copy() === session else { throw CancellationError() }
            await audio.set(reportStatistics: audio._state.reportStatistics)
            add(publication: publication)
            delegates.notify { $0.participant?(self, didPublishTrack: publication) }
            room.delegates.notify { $0.room?(room, participant: self, didPublishTrack: publication) }
            return publication
        } catch {
            try? await audio.nativePublication.copy()?.unpublish()
            try? await source.release()
            await audio.detachNativeSource()
            throw LiveKitError.mappingNative(error)
        }
    }
}

extension LocalParticipant {
    private func publishNativeVideo(_ track: LocalVideoTrack, options: VideoPublishOptions?) async throws -> LocalTrackPublication {
        let room = try requireRoom()
        let session = try room.requireNativeSession(forMedia: true)
        let options = options ?? room._state.roomOptions.defaultVideoPublishOptions
        guard options.encoding == nil, options.screenShareEncoding == nil,
              options.simulcastLayers.isEmpty, options.screenShareSimulcastLayers.isEmpty,
              options.preferredCodec == nil || options.preferredCodec == .vp8,
              options.preferredBackupCodec == nil, options.degradationPreference == .auto
        else {
            throw LiveKitError(.invalidParameter, message: "Native custom video encoding options are not exported")
        }
        try await track.start()
        do {
            let dimensions = try await track.capturer.dimensionsCompleter.wait()
            let source: NativeLocalVideoTrack = if let existing = track.nativeVideo.copy(), (try? existing.info()) != nil {
                existing
            } else {
                try await session.createVideoTrack(name: options.name ?? track.name, width: UInt32(dimensions.width), height: UInt32(dimensions.height), screencast: track.source == .screenShareVideo)
            }
            track.nativeVideo.mutate { $0 = source }
            do {
                let bridge = NativeVideoCapture(source: source)
                track.nativeCapture.mutate { $0 = bridge }
                track.add(videoRenderer: bridge)
                let native = try await source.publish(options: .init(source: track.source == .screenShareVideo ? .screenshare : .camera, simulcast: options.simulcast, stream: options.streamName ?? ""))
                track.nativePublication.mutate { $0 = native }
                try Task.checkCancellation()
                guard room.nativeSession.copy() === session else { throw CancellationError() }
                let info = try native.info()
                let publication = LocalTrackPublication(info: info, participant: self)
                track._state.mutate { $0.nativeSession = session; $0.sid = Track.Sid(from: info.sid); $0.publishState = .published; $0.lastPublishOptions = options; $0.dimensions = dimensions }
                await publication.set(track: track)
                guard room.nativeSession.copy() === session else { throw CancellationError() }
                await track.set(reportStatistics: track._state.reportStatistics)
                add(publication: publication)
                delegates.notify { $0.participant?(self, didPublishTrack: publication) }
                room.delegates.notify { $0.room?(room, participant: self, didPublishTrack: publication) }
                return publication
            } catch {
                try? await track.nativePublication.copy()?.unpublish()
                try? await source.release()
                await track.detachNativeSource()
                throw LiveKitError.mappingNative(error)
            }
        } catch {
            try? await track.stop()
            throw LiveKitError.mappingNative(error)
        }
    }
}
