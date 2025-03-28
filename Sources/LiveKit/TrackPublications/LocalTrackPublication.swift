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

import Combine
import Foundation

@objc
public class LocalTrackPublication: TrackPublication, @unchecked Sendable {
    // indicates whether the track was suspended(muted) by the SDK
    var _suspended: Bool = false

    // stream state is always active for local tracks
    override public var streamState: StreamState { .active }

    // MARK: - Private

    private var _cancellable: AnyCancellable?

    override init(info: Livekit_TrackInfo, participant: Participant) {
        super.init(info: info, participant: participant)

        // Watch audio manager processor changes.
        _cancellable = AudioManager.shared.capturePostProcessingDelegateSubject.sink { [weak self] _ in
            self?.sendAudioTrackFeatures()
        }
    }

    // MARK: - Private

    private let _debounce = Debounce(delay: 0.1)

    public func mute() async throws {
        guard let track = track as? LocalTrack else {
            throw LiveKitError(.invalidState, message: "track is nil or not a LocalTrack")
        }

        try await track._mute()
    }

    public func unmute() async throws {
        guard let track = track as? LocalTrack else {
            throw LiveKitError(.invalidState, message: "track is nil or not a LocalTrack")
        }

        try await track._unmute()
    }

    @discardableResult
    override func set(track newValue: Track?) async -> Track? {
        let oldValue = await super.set(track: newValue)

        // listen for VideoCapturerDelegate
        if let oldLocalVideoTrack = oldValue as? LocalVideoTrack {
            oldLocalVideoTrack.capturer.remove(delegate: self)
        }

        if let newLocalVideoTrack = newValue as? LocalVideoTrack {
            newLocalVideoTrack.capturer.add(delegate: self)
        }

        sendAudioTrackFeatures()

        return oldValue
    }

    deinit {
        log(nil, .trace)
    }
}

extension LocalTrackPublication {
    func suspend() async throws {
        // Do nothing if already muted
        guard !isMuted else { return }
        try await mute()
        _suspended = true
    }

    func resume() async throws {
        // Do nothing if was not suspended
        guard _suspended else { return }
        try await unmute()
        _suspended = false
    }
}

extension LocalTrackPublication: VideoCapturerDelegate {
    public func capturer(_: VideoCapturer, didUpdate _: Dimensions?) {
        Task.detached {
            await self._debounce.schedule {
                self.recomputeSenderParameters()
            }
        }
    }

    public func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.CapturerState) {
        // Broadcasts can always be stopped from system UI that bypasses our normal disable & unpublish methods.
        // This check ensures that when this happens the track gets unpublished as well.
        #if os(iOS)
        if state == .stopped, capturer is BroadcastScreenCapturer {
            Task {
                guard let participant = try await self.requireParticipant() as? LocalParticipant else {
                    return
                }

                try await participant.unpublish(publication: self)
            }
        }
        #endif
    }
}

extension LocalTrackPublication {
    func sendAudioTrackFeatures() {
        // Only proceed if audio track.
        guard let audioTrack = track as? LocalAudioTrack else { return }

        var newFeatures = audioTrack.captureOptions.toFeatures()

        if let audioPublishOptions = audioTrack.publishOptions as? AudioPublishOptions {
            // Combine features from publish options.
            newFeatures.formUnion(audioPublishOptions.toFeatures())
        }

        // Check if Krisp is enabled.
        if let processingDelegate = AudioManager.shared.capturePostProcessingDelegate,
           processingDelegate.audioProcessingName == kLiveKitKrispAudioProcessorName
        {
            newFeatures.insert(.tfEnhancedNoiseCancellation)
        }

        let didUpdateFeatures = _state.mutate {
            let oldFeatures = $0.audioTrackFeatures
            $0.audioTrackFeatures = newFeatures
            return oldFeatures != newFeatures
        }

        if didUpdateFeatures {
            log("Sending audio track features: \(newFeatures)")
            // Send if features updated.
            Task.detached { [newFeatures] in
                let participant = try await self.requireParticipant()
                let room = try participant.requireRoom()
                try await room.signalClient.sendUpdateLocalAudioTrack(trackSid: self.sid,
                                                                      features: newFeatures)
            }
        }
    }

    func recomputeSenderParameters() {
        guard let track = track as? LocalVideoTrack,
              let sender = track._state.rtpSender else { return }

        guard let dimensions = track.capturer.dimensions else {
            log("Cannot re-compute sender parameters without dimensions", .warning)
            return
        }

        log("Re-computing sender parameters, dimensions: \(String(describing: track.capturer.dimensions))")

        // get current parameters
        let parameters = sender.parameters

        guard let participant, let room = participant._room else { return }
        let publishOptions = (track.publishOptions as? VideoPublishOptions) ?? room._state.roomOptions.defaultVideoPublishOptions

        // re-compute encodings
        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: publishOptions,
                                                    isScreenShare: track.source == .screenShareVideo)

        log("Computed encodings: \(encodings)")

        for current in parameters.encodings {
            //
            if let updated = encodings.first(where: { $0.rid == current.rid }) {
                // update parameters for matching rid
                current.isActive = updated.isActive
                current.scaleResolutionDownBy = updated.scaleResolutionDownBy
                current.maxBitrateBps = updated.maxBitrateBps
                current.maxFramerate = updated.maxFramerate
            } else {
                current.isActive = false
                current.scaleResolutionDownBy = nil
                current.maxBitrateBps = nil
                current.maxBitrateBps = nil
            }
        }

        // set the updated parameters
        sender.parameters = parameters

        log("Using encodings: \(sender.parameters.encodings), degradationPreference: \(String(describing: sender.parameters.degradationPreference))")

        // Report updated encodings to server

        let layers = dimensions.videoLayers(for: encodings)

        log("Using encodings layers: \(layers.map { String(describing: $0) }.joined(separator: ", "))")

        Task.detached {
            let participant = try await self.requireParticipant()
            let room = try participant.requireRoom()
            try await room.signalClient.sendUpdateVideoLayers(trackSid: track.sid!, layers: layers)
        }
    }
}
