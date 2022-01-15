import SwiftUI
import WebRTC
import OrderedCollections
import Promises

open class ObservableRoom: ObservableObject, RoomDelegate {

    public let room: Room

    public var remoteParticipants: OrderedDictionary<Sid, ObservableParticipant> {
        OrderedDictionary(uniqueKeysWithValues: room.remoteParticipants.map { (sid, participant) in (sid, ObservableParticipant(participant)) })
    }

    public var allParticipants: OrderedDictionary<Sid, ObservableParticipant> {
        var result = remoteParticipants
        if let localParticipant = room.localParticipant {
            result.updateValue(ObservableParticipant(localParticipant),
                               forKey: localParticipant.sid,
                               insertingAt: 0)
        }
        return result
    }

    @Published public var screenShareTrackState: TrackPublishState = .notPublished()
    @Published public var cameraTrackState: TrackPublishState = .notPublished()
    @Published public var microphoneTrackState: TrackPublishState = .notPublished()

    public init(_ room: Room) {
        self.room = room
        room.add(delegate: self)
    }

    deinit {
        // cameraTrack?.stop()
        room.remove(delegate: self)
    }

    @discardableResult
    public func switchCameraPosition() -> Promise<Void> {

        guard case .published(let publication) = self.cameraTrackState,
              let track = publication.track as? LocalVideoTrack,
              let cameraCapturer = track.capturer as? CameraCapturer else {
            logger.notice("Track or CameraCapturer doesn't exist")
            return Promise(TrackError.state(message: "Track or a CameraCapturer doesn't exist"))
        }

        return cameraCapturer.switchCameraPosition()
    }

    public func toggleCameraEnabled() {

        guard let localParticipant = room.localParticipant else {
            logger.notice("LocalParticipant doesn't exist")
            return
        }

        guard !cameraTrackState.isBusy else {
            logger.notice("cameraTrack is .busy")
            return
        }

        var enabled = false
        if case .published = cameraTrackState { enabled = true }

        DispatchQueue.main.async {
            self.cameraTrackState = .busy(isPublishing: !enabled)
        }

        localParticipant.setCamera(enabled: !enabled).then(on: .sdk) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else {
                    self.cameraTrackState = .notPublished()
                    return
                }

                self.cameraTrackState = .published(publication)
            }
        }.catch { error in
            DispatchQueue.main.async {
                self.cameraTrackState = .notPublished(error: error)
            }
        }
    }

    public func toggleScreenShareEnabled() {

        guard let localParticipant = room.localParticipant else {
            logger.notice("LocalParticipant doesn't exist")
            return
        }

        guard !screenShareTrackState.isBusy else {
            logger.notice("screenShareTrack is .busy")
            return
        }

        var enabled = false
        if case .published = screenShareTrackState { enabled = true }

        DispatchQueue.main.async {
            self.screenShareTrackState = .busy(isPublishing: !enabled)
        }

        localParticipant.setScreenShare(enabled: !enabled).then(on: .sdk) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else {
                    self.screenShareTrackState = .notPublished()
                    return
                }

                self.screenShareTrackState = .published(publication)
            }
        }.catch { error in
            DispatchQueue.main.async {
                self.screenShareTrackState = .notPublished(error: error)
            }
        }
    }

    public func toggleMicrophoneEnabled() {

        guard let localParticipant = room.localParticipant else {
            logger.notice("LocalParticipant doesn't exist")
            return
        }

        guard !microphoneTrackState.isBusy else {
            logger.notice("microphoneTrack is .busy")
            return
        }

        var enabled = false
        if case .published = microphoneTrackState { enabled = true }

        DispatchQueue.main.async {
            self.microphoneTrackState = .busy(isPublishing: !enabled)
        }

        localParticipant.setMicrophone(enabled: !enabled).then(on: .sdk) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else {
                    self.microphoneTrackState = .notPublished()
                    return
                }

                self.microphoneTrackState = .published(publication)
            }
        }.catch { error in
            DispatchQueue.main.async {
                self.microphoneTrackState = .notPublished(error: error)
            }
        }
    }

    open func room(_ room: Room,
                   participantDidJoin participant: RemoteParticipant) {
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    open func room(_ room: Room,
                   participantDidLeave participant: RemoteParticipant) {
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    open func room(_ room: Room, participant: RemoteParticipant?, didReceive data: Data) {
        //
    }
}
