/*
 * Copyright 2022 LiveKit
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

/// Delegate methods for a participant.
///
/// Since ``Participant`` inherits from ``MulticastDelegate``,
/// you can call `add(delegate:)` on ``Participant`` to add as many delegates as you need.
/// All delegate methods are optional.
///
/// To ensure each participant's delegate is registered, you can look through ``Room/localParticipant`` and ``Room/remoteParticipants`` on connect
/// and register it on new participants inside ``RoomDelegate/room(_:participantDidJoin:)-9bkm4``
@objc
public protocol ParticipantDelegate: AnyObject {

    /// A ``Participant``'s metadata has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc(participant:didUpdateMetadata:) optional
    func participant(_ participant: Participant, didUpdate metadata: String?)

    /// The isSpeaking status of a ``Participant`` has changed.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc(participant:didUpdateSpeaking:) optional
    func participant(_ participant: Participant, didUpdate speaking: Bool)

    /// The connection quality of a ``Participant`` has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc(participant:didUpdateConnectionQuality:) optional
    func participant(_ participant: Participant, didUpdate connectionQuality: ConnectionQuality)

    /// `muted` state has updated for the ``Participant``'s ``TrackPublication``.
    ///
    /// For the ``LocalParticipant``, the delegate method will be called if setMute was called on ``LocalTrackPublication``,
    /// or if the server has requested the participant to be muted.
    ///
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc(participant:publication:didUpdateMuted:) optional
    func participant(_ participant: Participant, didUpdate publication: TrackPublication, muted: Bool)

    @objc(participant:didUpdatePermissions:) optional
    func participant(_ participant: Participant, didUpdate permissions: ParticipantPermissions)

    /// ``RemoteTrackPublication/streamState`` has updated for the ``RemoteParticipant``.
    @objc(participant:publication:didUpdateStreamState:) optional
    func participant(_ participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, streamState: StreamState)

    /// ``RemoteTrackPublication/subscriptionAllowed`` has updated for the ``RemoteParticipant``.
    @objc(participant:publication:didUpdateCanSubscribe:) optional
    func participant(_ participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, permission allowed: Bool)

    /// When a new ``RemoteTrackPublication`` is published to ``Room`` after the ``LocalParticipant`` has joined.
    ///
    /// This delegate method will not be called for tracks that are already published.
    @objc(remoteParticipant:didPublish:) optional
    func participant(_ participant: RemoteParticipant, didPublish publication: RemoteTrackPublication)

    /// The ``RemoteParticipant`` has unpublished a ``RemoteTrackPublication``.
    @objc(remoteParticipant:didUnpublish:) optional
    func participant(_ participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication)

    /// The ``LocalParticipant`` has published a ``LocalTrackPublication``.
    @objc(localParticipant:didPublish:) optional
    func localParticipant(_ participant: LocalParticipant, didPublish publication: LocalTrackPublication)

    /// The ``LocalParticipant`` has unpublished a ``LocalTrackPublication``.
    @objc(localParticipant:didUnpublish:) optional
    func localParticipant(_ participant: LocalParticipant, didUnpublish publication: LocalTrackPublication)

    /// The ``LocalParticipant`` has subscribed to a new ``RemoteTrackPublication``.
    ///
    /// This event will always fire as long as new tracks are ready for use.
    @objc(participant:didSubscribe:track:) optional
    func participant(_ participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track)

    /// Could not subscribe to a track.
    ///
    /// This is an error state, the subscription can be retried.
    @objc(participant:didFailToSubscribeTrackWithSid:error:) optional
    func participant(_ participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error)

    /// Unsubscribed from a ``RemoteTrackPublication`` and  is no longer available.
    ///
    /// Clients should listen to this event and handle cleanup.
    @objc(participant:didUnsubscribePublication:track:) optional
    func participant(_ participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track)

    /// Data was received from a ``RemoteParticipant``.
    @objc(participant:didReceiveData:) optional
    func participant(_ participant: RemoteParticipant, didReceive data: Data)
}
