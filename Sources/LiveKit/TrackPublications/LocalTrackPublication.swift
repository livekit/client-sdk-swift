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

import Foundation

@objc
public class LocalTrackPublication: TrackPublication {
    // indicates whether the track was suspended(muted) by the SDK
    var _suspended: Bool = false

    // keep reference to cancel later
    private weak var debounceWorkItem: DispatchWorkItem?

    // stream state is always active for local tracks
    override public var streamState: StreamState { .active }

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

    override func set(track newValue: Track?) -> Track? {
        let oldValue = super.set(track: newValue)

        // listen for VideoCapturerDelegate
        if let oldLocalVideoTrack = oldValue as? LocalVideoTrack {
            oldLocalVideoTrack.capturer.remove(delegate: self)
        }

        if let newLocalVideoTrack = newValue as? LocalVideoTrack {
            newLocalVideoTrack.capturer.add(delegate: self)
        }

        return oldValue
    }

    deinit {
        log()
        debounceWorkItem?.cancel()
    }

    // create debounce func
    lazy var shouldRecomputeSenderParameters = Utils.createDebounceFunc(on: queue,
                                                                        wait: 0.1,
                                                                        onCreateWorkItem: { [weak self] workItem in
                                                                            self?.debounceWorkItem = workItem
                                                                        }, fnc: { [weak self] in
                                                                            self?.recomputeSenderParameters()
                                                                        })
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
        shouldRecomputeSenderParameters()
    }
}

extension LocalTrackPublication {
    func recomputeSenderParameters() {
        guard let track = track as? LocalVideoTrack,
              let sender = track.rtpSender else { return }

        guard let dimensions = track.capturer.dimensions else {
            log("Cannot re-compute sender parameters without dimensions", .warning)
            return
        }

        log("Re-computing sender parameters, dimensions: \(String(describing: track.capturer.dimensions))")

        // get current parameters
        let parameters = sender.parameters

        guard let participant else { return }
        let publishOptions = (track.publishOptions as? VideoPublishOptions) ?? participant.room._state.options.defaultVideoPublishOptions

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

        Task {
            let participant = try await requireParticipant()
            try await participant.room.engine.signalClient.sendUpdateVideoLayers(trackSid: track.sid!, layers: layers)
        }
    }
}
