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

extension Room {
    @nonobjc func applyNativeRoomValues(_ info: NativeRoomInfo) {
        _state.mutate { $0.apply(roomInfo: info) }
    }

    @nonobjc func applyNativeSnapshot(_ snapshot: NativeRoomState, restoreDataTracks: Bool = false, restoreMedia: Bool = false) async {
        guard let native = nativeRoom.copy() else { return }
        if let info = snapshot.room { _state.mutate { $0.apply(roomInfo: info) } }
        let identities = Set(snapshot.remoteParticipants.map { Participant.Identity(from: $0.identity) })
        for identity in remoteParticipants.keys where !identities.contains(identity) {
            try? await _onParticipantDidDisconnect(identity: identity)
            guard nativeRoom.copy() === native else { return }
        }
        if let participant = snapshot.localParticipant {
            applyNativeParticipant(participant, to: localParticipant, publications: snapshot.publications)
        }
        for info in snapshot.remoteParticipants {
            let identity = Participant.Identity(from: info.identity)
            let existing = remoteParticipants[identity]
            let participant = existing ?? _state.mutate {
                $0.updateRemoteParticipant(info: info, publications: snapshot.publications, room: self)
            }
            applyNativeParticipant(info, to: participant, publications: snapshot.publications)
            if existing == nil, connectionState == .connected {
                delegates.notify { $0.room?(self, participantDidConnect: participant) }
            }
        }
        if restoreMedia { await applyNativeMedia(snapshot) }
        if restoreDataTracks { restoreNativeDataTracks(snapshot) }
        applyNativeConnection(snapshot.connection)
    }

    private func applyNativeConnection(_ connection: NativeConnectionState) {
        _state.mutate {
            switch connection {
            case .idle, .connecting: break
            case .connected: if $0.connectionState == .reconnecting { $0.connectionState = .connected }
            case .reconnecting: $0.connectionState = .reconnecting
            case .disconnected: break // Teardown is owned by the driver, before the terminal delegate.
            @unknown default:
                $0.disconnectError = LiveKitError(.invalidState, message: "Unknown native connection state")
            }
        }
    }

    private func restoreNativeDataTracks(_ snapshot: NativeRoomState) {
        // Data-track events update the live handles separately. Snapshot recovery is only needed
        // at join or cursor replacement; the native lookup never creates a second transport.
        if let session = nativeRoom.copy() {
            let sids = Set(snapshot.dataTracks.map(\.info.sid))
            for participant in remoteParticipants.values {
                for track in participant._state.dataTracks where !sids.contains(track.info.sid.stringValue) {
                    nativeDataTrackUnpublished(sid: track.info.sid.stringValue, identity: track.publisherIdentity.stringValue)
                }
            }
            for publication in snapshot.dataTracks {
                if let track = session.remoteDataTrack(sid: publication.info.sid) {
                    nativeDataTrackPublished(track, identity: publication.publisherIdentity)
                }
            }
        }
    }

    private func applyNativeParticipant(_ info: NativeParticipant, to participant: Participant, publications: [NativeTrackPublication]) {
        participant.set(info: info, publications: publications, connectionState: connectionState)
        participant._state.mutate {
            if info.isSpeaking, !$0.isSpeaking { $0.lastSpokeAt = Date() }
            $0.isSpeaking = info.isSpeaking
            $0.audioLevel = info.audioLevel
            switch info.connectionQuality {
            case .excellent: $0.connectionQuality = .excellent
            case .good: $0.connectionQuality = .good
            case .poor: $0.connectionQuality = .poor
            case .lost: $0.connectionQuality = .lost
            @unknown default: $0.connectionQuality = .unknown
            }
        }
    }

    func nativeDataTrackPublished(_ native: LiveKitFFI.RemoteDataTrack, identity: String) {
        guard let participant = remoteParticipants[Participant.Identity(from: identity)] else { return }
        let sid = native.info().sid
        guard !participant._state.dataTracks.contains(where: { $0.info.sid.stringValue == sid }) else { return }
        let track = RemoteDataTrack(native)
        guard participant.addDataTrack(track) else { return }
        participant.delegates.notify { $0.participant?(participant, didPublishDataTrack: track) }
        delegates.notify { $0.room?(self, participant: participant, didPublishDataTrack: track) }
    }

    func nativeDataTrackUnpublished(sid: String, identity: String) {
        guard let participant = remoteParticipants[Participant.Identity(from: identity)] else { return }
        let sid = DataTrack.Sid(from: sid)
        guard participant.removeDataTrack(sid: sid) != nil else { return }
        participant.delegates.notify { $0.participant?(participant, didUnpublishDataTrack: sid) }
        delegates.notify { $0.room?(self, participant: participant, didUnpublishDataTrack: sid) }
    }
}

extension Room {
    func applyNativeMedia(_ snapshot: NativeRoomState) async {
        guard let session = nativeRoom.copy() else { return }
        for info in snapshot.publications {
            guard let participant = remoteParticipants[Participant.Identity(from: info.participantIdentity)],
                  let publication = participant.trackPublications[Track.Sid(from: info.sid)] as? RemoteTrackPublication else { continue }
            var attaching: Track?
            do {
                let handle = try session.publication(identity: info.participantIdentity, sid: info.sid)
                if let audio = try handle.remoteAudioTrack() {
                    guard publication.track == nil else { continue }
                    let track = RemoteAudioTrack(name: info.name, source: publication.source, track: nil, reportStatistics: _state.roomOptions.reportRemoteTrackStatistics)
                    attaching = track
                    track.nativePublication.mutate { $0 = handle }
                    try await track.receiveNativeAudio(audio)
                    await finishNativeSubscription(track, publication: publication, participant: participant, session: session)
                } else if let video = try handle.remoteVideoTrack() {
                    guard publication.track == nil else { continue }
                    let track = RemoteVideoTrack(name: info.name, source: publication.source, track: nil, reportStatistics: _state.roomOptions.reportRemoteTrackStatistics)
                    attaching = track
                    track.nativePublication.mutate { $0 = handle }
                    try await track.receiveNativeVideo(video)
                    await finishNativeSubscription(track, publication: publication, participant: participant, session: session)
                } else if let track = publication.track {
                    try await track.stopCapture()
                    await publication.set(track: nil)
                }
            } catch {
                await discardNativeAttachment(attaching)
                log("Native publication projection failed: \(error)", .warning)
            }
        }
    }

    private func discardNativeAttachment(_ track: Track?) async {
        guard let track else { return }
        try? await track.stopCapture()
        track.nativePublication.mutate { $0 = nil }
    }

    private func finishNativeSubscription(_ track: Track, publication: RemoteTrackPublication,
                                          participant: RemoteParticipant, session: FfiRoom) async
    {
        await track.set(reportStatistics: track._state.reportStatistics)
        guard nativeRoom.copy() === session, publication.track == nil else {
            await discardNativeAttachment(track)
            return
        }
        await publication.set(track: track)
        track.set(trackState: .started)
        participant.delegates.notify { $0.participant?(participant, didSubscribeTrack: publication) }
        delegates.notify { $0.room?(self, participant: participant, didSubscribeTrack: publication) }
    }
}
