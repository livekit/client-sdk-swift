import Foundation

/// Delegate methods for a participant.
///
/// Since ``Participant`` inherits from ``MulticastDelegate``,
/// you can call `add(delegate:)` on ``Participant`` to add as many delegates as you need.
/// All delegate methods are optional.
///
/// To ensure each participant's delegate is registered, you can look through ``Room/localParticipant`` and ``Room/remoteParticipants`` on connect
/// and register it on new participants inside ``RoomDelegate/room(_:participantDidJoin:)-9bkm4``
public protocol ParticipantDelegate: AnyObject {

    /// A ``Participant``'s metadata has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    func participant(_ participant: Participant, didUpdate metadata: String?)

    /// The isSpeaking status of a ``Participant`` has changed.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    func participant(_ participant: Participant, didUpdate speaking: Bool)

    /// The connection quality of a ``Participant`` has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    func participant(_ participant: Participant, didUpdate connectionQuality: ConnectionQuality)

    /// `muted` state has updated for the ``Participant``'s ``TrackPublication``.
    ///
    /// For the ``LocalParticipant``, the delegate method will be called if setMute was called on ``LocalTrackPublication``,
    /// or if the server has requested the participant to be muted.
    ///
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    func participant(_ participant: Participant, didUpdate publication: TrackPublication, muted: Bool)

    /// ``RemoteTrackPublication/streamState`` has updated for the ``RemoteParticipant``.
    func participant(_ participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, streamState: StreamState)

    /// ``RemoteTrackPublication/subscriptionAllowed`` has updated for the ``RemoteParticipant``.
    func participant(_ participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, permission allowed: Bool)

    /// When a new ``RemoteTrackPublication`` is published to ``Room`` after the ``LocalParticipant`` has joined.
    ///
    /// This delegate method will not be called for tracks that are already published.
    func participant(_ participant: RemoteParticipant, didPublish publication: RemoteTrackPublication)

    /// The ``RemoteParticipant`` has unpublished a ``RemoteTrackPublication``.
    func participant(_ participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication)

    /// The ``LocalParticipant`` has published a ``LocalTrackPublication``.
    func localParticipant(_ participant: LocalParticipant, didPublish publication: LocalTrackPublication)

    /// The ``LocalParticipant`` has unpublished a ``LocalTrackPublication``.
    func localParticipant(_ participant: LocalParticipant, didUnpublish publication: LocalTrackPublication)

    /// The ``LocalParticipant`` has subscribed to a new ``RemoteTrackPublication``.
    ///
    /// This event will always fire as long as new tracks are ready for use.
    func participant(_ participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track)

    /// Could not subscribe to a track.
    ///
    /// This is an error state, the subscription can be retried.
    func participant(_ participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error)

    /// Unsubscribed from a ``RemoteTrackPublication`` and  is no longer available.
    ///
    /// Clients should listen to this event and handle cleanup.
    func participant(_ participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track)

    /// Data was received from a ``RemoteParticipant``.
    func participant(_ participant: RemoteParticipant, didReceive data: Data)
}

/// Default implementation for ``ParticipantDelegate``
public extension ParticipantDelegate {
    func participant(_ participant: Participant, didUpdate metadata: String?) {}
    func participant(_ participant: Participant, didUpdate speaking: Bool) {}
    func participant(_ participant: Participant, didUpdate connectionQuality: ConnectionQuality) {}
    func participant(_ participant: Participant, didUpdate publication: TrackPublication, muted: Bool) {}
    func participant(_ participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, streamState: StreamState) {}
    func participant(_ participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, permission allowed: Bool) {}
    func participant(_ participant: RemoteParticipant, didPublish publication: RemoteTrackPublication) {}
    func participant(_ participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication) {}
    func participant(_ participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track) {}
    func participant(_ participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error) {}
    func participant(_ participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track) {}
    func participant(_ participant: RemoteParticipant, didReceive data: Data) {}
    func localParticipant(_ participant: LocalParticipant, didPublish publication: LocalTrackPublication) {}
    func localParticipant(_ participant: LocalParticipant, didUnpublish publication: LocalTrackPublication) {}
}
