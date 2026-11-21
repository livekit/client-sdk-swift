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

/// Owns an unbound JOIN sender until captured microphone audio takes over.
actor PreparedAudioPublication {
    struct Sender: Sendable {
        let transport: Transport
        let sender: RTCSender
        let request: Livekit_AddTrackRequest
    }

    let options: AudioPublishOptions
    private var reserved: Sender?
    private var cancelled = false

    init(options: AudioPublishOptions) {
        self.options = options
    }

    func reserve(on transport: Transport) async throws -> Livekit_AddTrackRequest {
        try checkCancellation()
        let sender = try await RTC.run {
            let configuration = LKRTCRtpTransceiverInit()
            configuration.direction = .sendOnly
            configuration.streamIds = [UUID().uuidString]
            let encoding = RTC.createRtpEncodingParameters(encoding: self.options.encoding ?? .presetMusic)
            // Native audio senders share the ADM even without a bound track. Keep RTP
            // inactive until capture permission is granted and the real track is attached.
            encoding.isActive = false
            configuration.sendEncodings = [encoding]
            return try RTCSender(transport.addTransceiver(ofType: .audio, transceiverInit: configuration).sender)
        }
        try checkCancellation()
        let request = LocalParticipant.audioPublishRequest(options: options).modifying {
            $0.cid = sender.senderId
            $0.name = options.name ?? Track.microphoneName
            $0.type = .audio
            $0.source = .microphone
            if let stream = options.streamName { $0.stream = stream }
        }
        reserved = Sender(transport: transport, sender: sender, request: request)
        return request
    }

    func discard(on transport: Transport) {
        if reserved?.transport === transport { reserved = nil }
    }

    func sender(in room: Room) async throws -> (Sender, Livekit_TrackInfo)? {
        try checkCancellation()
        guard let context = reserved else { return nil }
        guard try context.transport === (room.requirePublisher()), room.e2eeManager == nil else {
            reserved = nil
            return nil
        }
        let info = try await room.signalClient.waitForJoinTrack(cid: context.request.cid)
        try checkCancellation()
        try Task.checkCancellation()
        guard try context.transport === (room.requirePublisher()) else {
            reserved = nil
            return nil
        }
        return (context, info)
    }

    func commit() { reserved = nil }

    func cancel(in room: Room) async {
        cancelled = true
        guard let context = reserved else { return }
        reserved = nil
        guard context.transport === (try? room.requirePublisher()) else { return }
        do {
            try await context.transport.remove(track: context.sender)
            if room.connectionState == .connected { try await room.publisherShouldNegotiate() }
        } catch {
            // Connection teardown owns senders on a closed transport.
        }
    }

    private func checkCancellation() throws {
        if cancelled { throw CancellationError() }
    }
}
