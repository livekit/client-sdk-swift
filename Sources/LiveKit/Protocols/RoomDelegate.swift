import Foundation

/// ``RoomDelegate`` receives room events as well as ``Participant`` events.
public protocol RoomDelegate {
    /// Successfully connected to the room.
    func room(_ room: Room, didConnect isReconnect: Bool)

    /// Could not connect to the room.
    func room(_ room: Room, didFailToConnect error: Error)

    /// Client disconnected from the room unexpectedly.
    func room(_ room: Room, didDisconnect error: Error?)

    /// When a network change has been detected and LiveKit attempts to reconnect to the room.
    /// When reconnect attempts succeed, the room state will be kept, including tracks that are subscribed/published.
    func room(_ room: Room, didUpdate connectionState: ConnectionState)

    /// When a ``RemoteParticipant`` joins after the ``LocalParticipant``.
    /// It will not emit events for participants that are already in the room.
    func room(_ room: Room, participantDidJoin participant: RemoteParticipant)

    /// When a ``RemoteParticipant`` leaves after the ``LocalParticipant`` has joined.
    func room(_ room: Room, participantDidLeave participant: RemoteParticipant)

    /// Active speakers changed.
    ///
    /// List of speakers are ordered by their ``Participant/audioLevel``, loudest speakers first.
    /// This will include the ``LocalParticipant`` too.
    func room(_ room: Room, didUpdate speakers: [Participant])

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:)-46iut``.
    func room(_ room: Room, participant: Participant, didUpdate metadata: String?)

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:)-7zxk1``.
    func room(_ room: Room, participant: Participant, didUpdate connectionQuality: ConnectionQuality)

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:)-84m89``.
    func room(_ room: Room, participant: Participant, didUpdate publication: TrackPublication, muted: Bool)

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:streamState:)-1lu8t``.
    func room(_ room: Room, participant: Participant, didUpdate publication: TrackPublication, streamState: TrackPublication.StreamState)

    /// Same with ``ParticipantDelegate/participant(_:didPublish:)-60en3``.
    func room(_ room: Room, participant: RemoteParticipant, didPublish publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUnpublish:)-3bkga``.
    func room(_ room: Room, participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didSubscribe:track:)-7mngl``.
    func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track)

    /// Same with ``ParticipantDelegate/participant(_:didFailToSubscribe:error:)-10pn4``.
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error)

    /// Same with ``ParticipantDelegate/participant(_:didUnsubscribe:track:)-3ksvp``.
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didReceive:)-2t55a``
    func room(_ room: Room, participant: RemoteParticipant, didReceive data: Data)

    /// Same with ``ParticipantDelegate/localParticipant(_:didPublish:)-90j2m``.
    func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUnpublish:)-3bkga``.
    func room(_ room: Room, localParticipant: LocalParticipant, didUnpublish publication: LocalTrackPublication)
}

/// Default implementation for ``RoomDelegate``
public extension RoomDelegate {
    func room(_ room: Room, didConnect isReconnect: Bool) {}
    func room(_ room: Room, didFailToConnect error: Error) {}
    func room(_ room: Room, didDisconnect error: Error?) {}
    func room(_ room: Room, didUpdate connectionState: ConnectionState) {}
    func room(_ room: Room, participantDidJoin participant: RemoteParticipant) {}
    func room(_ room: Room, participantDidLeave participant: RemoteParticipant) {}
    func room(_ room: Room, didUpdate speakers: [Participant]) {}
    func room(_ room: Room, participant: Participant, didUpdate metadata: String?) {}
    func room(_ room: Room, participant: Participant, didUpdate publication: TrackPublication, muted: Bool) {}
    func room(_ room: Room, participant: Participant, didUpdate publication: TrackPublication, streamState: TrackPublication.StreamState) {}
    func room(_ room: Room, participant: Participant, didUpdate connectionQuality: ConnectionQuality) {}
    func room(_ room: Room, participant: RemoteParticipant, didPublish publication: RemoteTrackPublication) {}
    func room(_ room: Room, participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication) {}
    func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track) {}
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error) {}
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication) {}
    func room(_ room: Room, participant: RemoteParticipant, didReceive data: Data) {}
    func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication) {}
    func room(_ room: Room, localParticipant: LocalParticipant, didUnpublish publication: LocalTrackPublication) {}
}
