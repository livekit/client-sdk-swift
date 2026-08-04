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

import AVFAudio
import Foundation

/// A buffer that captures audio before connecting to the server.
///
/// The captured audio is sent automatically to the first active agent participant
/// once the microphone track is published and its server-assigned id is known.
@objcMembers
public final class PreConnectAudioBuffer: NSObject, Sendable, Loggable {
    public typealias OnError = @Sendable (Error) -> Void

    public enum Constants {
        public static let maxSize = 10 * 1024 * 1024 // 10MB
        public static let sampleRate = 24000
        public static let timeout: TimeInterval = 10
    }

    /// The default data topic used to send the audio buffer.
    public static let dataTopic = "lk.agent.pre-connect-audio-buffer"

    /// The room instance to send the audio buffer to.
    public var room: Room? { state.room }

    /// The audio recorder instance.
    public var recorder: LocalAudioTrackRecorder? { state.recorder }

    private let state = StateSync<State>(State())
    private struct State {
        weak var room: Room?
        var recorder: LocalAudioTrackRecorder?
        var audioStream: LocalAudioTrackRecorder.Stream?
        var timeoutTask: AnyTaskCancellable?
        var onError: OnError?
    }

    /// Resolves with the first agent participant that becomes active.
    private let agentCompleter = AsyncCompleter<Participant.Identity>(label: "PreConnectAudioBuffer.agent", defaultTimeout: Constants.timeout)

    /// Initialize the audio buffer with a room instance.
    /// - Parameters:
    ///   - room: The room instance to send the audio buffer to.
    ///   - onError: The error handler to call when an error occurs while sending the audio buffer.
    public init(room: Room?, onError: OnError? = nil) {
        state.mutate {
            $0.room = room
            $0.onError = onError
        }
        super.init()
    }

    deinit {
        stopRecording()
    }

    public func setErrorHandler(_ onError: OnError?) {
        state.mutate { $0.onError = onError }
    }

    /// Start capturing audio.
    /// - Parameters:
    ///   - timeout: The timeout for the remote participant to subscribe to the audio track.
    /// The room connection needs to be established and the remote participant needs to subscribe to the audio track
    /// before the timeout is reached. Otherwise, the audio stream will be flushed without sending.
    ///   - recorder: Optional custom recorder instance. If not provided, a new one will be created.
    public func startRecording(timeout: TimeInterval = Constants.timeout, recorder: LocalAudioTrackRecorder? = nil) async throws {
        let timeout = timeout.isFinite ? min(max(timeout, 0), 86400) : Constants.timeout
        let roomOptions = room?._state.roomOptions
        let newRecorder = recorder ?? LocalAudioTrackRecorder(
            track: LocalAudioTrack.createTrack(options: roomOptions?.defaultAudioCaptureOptions,
                                               reportStatistics: roomOptions?.reportRemoteTrackStatistics ?? false),
            format: .pcmFormatInt16,
            sampleRate: Constants.sampleRate,
            maxSize: Constants.maxSize,
        )

        let stream = try await newRecorder.start()
        log("Started capturing audio", .info)

        agentCompleter.reset()
        agentCompleter.set(defaultTimeout: timeout)

        state.mutate { state in
            state.recorder = newRecorder
            state.audioStream = stream
            state.timeoutTask = Task { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * TimeInterval(NSEC_PER_SEC)))
                try Task.checkCancellation()
                self?.stopRecording(flush: true)
            }.cancellable()
        }

        room?.add(delegate: self)
    }

    /// Stop capturing audio.
    /// - Parameters:
    ///   - flush: If `true`, the audio stream will be flushed immediately without sending.
    public func stopRecording(flush: Bool = false) {
        guard let recorder, recorder.isRecording else { return }

        recorder.stop()
        log("Stopped capturing audio", .info)

        if flush {
            // Take ownership of the stream so it cannot race with an in-flight send
            let stream = state.mutate { $0.audioStream.take() }
            if let stream {
                log("Flushing audio stream", .info)
                Task {
                    for await _ in stream {}
                }
            }
            agentCompleter.reset()
            room?.remove(delegate: self)
        }
    }

    /// Send the audio data to the room.
    /// - Parameters:
    ///   - room: The room instance to send the audio data.
    ///   - agents: The agents to send the audio data to.
    ///   - topic: The topic to send the audio data.
    public func sendAudioData(to room: Room, agents: [Participant.Identity], on topic: String = dataTopic) async throws {
        guard !agents.isEmpty, state.audioStream != nil else { return }
        guard let trackSid = state.recorder?.track.sid else {
            throw LiveKitError(.invalidState, message: "Track is not published")
        }
        try await sendAudioData(to: room, trackSid: trackSid, agents: agents, on: topic)
    }

    /// Send the audio data to the given agents, or to the first active agent if none are given.
    /// - Parameters:
    ///   - room: The room instance to send the audio data.
    ///   - trackSid: The server-assigned id of the published microphone track the agent binds the buffer to.
    ///   - agents: The agents to send the audio data to. If `nil`, waits for the first active agent.
    ///   - topic: The topic to send the audio data.
    func sendAudioData(to room: Room, trackSid: Track.Sid, agents: [Participant.Identity]? = nil, on topic: String = dataTopic) async throws {
        if let agents, agents.isEmpty {
            return
        }

        // Take ownership of the stream; it can be consumed only once.
        // A nil stream means it was already sent or flushed — expected teardown, not an error
        let claim = try state.mutate { state -> (recorder: LocalAudioTrackRecorder, audioStream: LocalAudioTrackRecorder.Stream)? in
            guard let recorder = state.recorder else {
                throw LiveKitError(.invalidState, message: "Recorder is nil")
            }
            guard let audioStream = state.audioStream.take() else { return nil }
            return (recorder, audioStream)
        }
        guard let (recorder, audioStream) = claim else {
            log("Audio stream already consumed or flushed, nothing to send")
            return
        }

        let destinations: [Participant.Identity]
        if let agents {
            destinations = agents
        } else if let activeAgent = room.agentParticipants.values.first(where: { $0.state == .active })?.identity {
            destinations = [activeAgent]
        } else {
            log("Waiting for an active agent to send audio to", .info)
            destinations = try await [agentCompleter.wait()]
        }

        let streamOptions = StreamByteOptions(
            topic: topic,
            attributes: [
                "sampleRate": "\(recorder.sampleRate)",
                "channels": "\(recorder.channels)",
                "trackId": trackSid.stringValue,
            ],
            destinationIdentities: destinations,
        )
        let writer = try await room.localParticipant.streamBytes(options: streamOptions)

        var sentSize = 0
        for await chunk in audioStream {
            do {
                try await writer.write(chunk)
            } catch {
                try await writer.close(reason: error.localizedDescription)
                throw error
            }
            sentSize += chunk.count
        }
        try await writer.close()

        log("Sent \(recorder.duration(sentSize))s = \(sentSize / 1024)KB of audio data to \(destinations.count) agent(s) \(destinations)", .info)
    }
}

extension PreConnectAudioBuffer: RoomDelegate {
    public func room(_ room: Room, participant _: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        // Only the first publish of the recorded track sends the buffer; a republish
        // (e.g. after a full reconnect) finds the stream already consumed
        guard publication.track === state.recorder?.track, state.audioStream != nil else { return }
        log("Microphone track published, sending audio to the first active agent", .info)

        Task {
            do {
                try await sendAudioData(to: room, trackSid: publication.sid)
                room.remove(delegate: self)
            } catch let error as LiveKitError where error.type == .cancelled || error.type == .timedOut {
                // Recording was flushed or no agent became active in time; nothing to send
                log("Preconnect audio not sent: \(error)")
            } catch {
                log("Unable to send preconnect audio: \(error)", .error)
                state.onError?(error)
            }
        }
    }

    public func room(_: Room, participant _: LocalParticipant, remoteDidSubscribeTrack _: LocalTrackPublication) {
        log("Subscribed by remote participant, stopping audio", .info)
        stopRecording()
    }

    public func room(_: Room, participant: Participant, didUpdateState state: ParticipantState) {
        guard participant.kind == .agent,
              participant._state.agentAttributes?.lkPublishOnBehalf == nil, // exclude avatar workers
              state == .active, let agent = participant.identity else { return }
        log("Detected active agent participant: \(agent)", .info)
        agentCompleter.resume(returning: agent)
    }
}
