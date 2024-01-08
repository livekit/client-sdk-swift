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

/// Delegate methods for a participant.
///
/// Since ``Participant`` inherits from ``MulticastDelegate``,
/// you can call `add(delegate:)` on ``Participant`` to add as many delegates as you need.
/// All delegate methods are optional.
///
/// To ensure each participant's delegate is registered, you can look through ``Room/localParticipant`` and ``Room/remoteParticipants`` on connect
/// and register it on new participants inside ``RoomDelegate/room(_:participantDidJoin:)``
@objc
public protocol ParticipantDelegate: AnyObject {
    // MARK: - Participant

    /// A ``Participant``'s metadata has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateMetadata metadata: String?)

    /// A ``Participant``'s name has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateName name: String?)

    /// The isSpeaking status of a ``Participant`` has changed.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateIsSpeaking isSpeaking: Bool)

    /// The connection quality of a ``Participant`` has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateConnectionQuality connectionQuality: ConnectionQuality)

    @objc optional
    func participant(_ participant: Participant, didUpdatePermissions permissions: ParticipantPermissions)

    // MARK: - TrackPublication

    /// `muted` state has updated for the ``Participant``'s ``TrackPublication``.
    ///
    /// For the ``LocalParticipant``, the delegate method will be called if setMute was called on ``LocalTrackPublication``,
    /// or if the server has requested the participant to be muted.
    ///
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, track: TrackPublication, didUpdateIsMuted isMuted: Bool)

    // MARK: - LocalTrackPublication

    /// The ``LocalParticipant`` has published a ``LocalTrackPublication``.
    @objc(localParticipant:didPublishTrack:) optional
    func participant(_ participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication)

    /// The ``LocalParticipant`` has unpublished a ``LocalTrackPublication``.
    @objc(localParticipant:didUnpublishTrack:) optional
    func participant(_ participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication)

    // MARK: - RemoteTrackPublication

    /// When a new ``RemoteTrackPublication`` is published to ``Room`` after the ``LocalParticipant`` has joined.
    ///
    /// This delegate method will not be called for tracks that are already published.
    @objc(remoteParticipant:didPublishTrack:) optional
    func participant(_ participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication)

    /// The ``RemoteParticipant`` has unpublished a ``RemoteTrackPublication``.
    @objc(remoteParticipant:didUnpublishTrack:) optional
    func participant(_ participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication)

    /// The ``LocalParticipant`` has subscribed to a new ``RemoteTrackPublication``.
    ///
    /// This event will always fire as long as new tracks are ready for use.
    @objc optional
    func participant(_ participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication)

    /// Unsubscribed from a ``RemoteTrackPublication`` and  is no longer available.
    ///
    /// Clients should listen to this event and handle cleanup.
    @objc optional
    func participant(_ participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication)

    /// Could not subscribe to a track.
    ///
    /// This is an error state, the subscription can be retried.
    @objc optional
    func participant(_ participant: RemoteParticipant, didFailToSubscribeTrack trackSid: String, withError error: LiveKitError)

    /// ``TrackPublication/streamState`` has updated for the ``RemoteTrackPublication``.
    @objc optional
    func participant(_ participant: RemoteParticipant, track: RemoteTrackPublication, didUpdateStreamState streamState: StreamState)

    /// ``RemoteTrackPublication/isSubscriptionAllowed`` has updated for the ``RemoteTrackPublication``.
    @objc optional
    func participant(_ participant: RemoteParticipant, track: RemoteTrackPublication, didUpdateIsSubscriptionAllowed isSubscriptionAllowed: Bool)

    // MARK: - Data

    /// Data was received from a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: RemoteParticipant, didReceiveData data: Data, forTopic topic: String)
}
