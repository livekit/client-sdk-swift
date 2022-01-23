import SwiftUI
import WebRTC
import OrderedCollections
import Promises

open class ObservableRoom: ObservableObject, RoomDelegate, Loggable {

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
            log("Track or CameraCapturer doesn't exist", .notice)
            return Promise(TrackError.state(message: "Track or a CameraCapturer doesn't exist"))
        }

        return cameraCapturer.switchCameraPosition()
    }

    public func toggleCameraEnabled() {

        guard let localParticipant = room.localParticipant else {
            log("LocalParticipant doesn't exist", .notice)
            return
        }

        guard !cameraTrackState.isBusy else {
            log("cameraTrack is .busy", .notice)
            return
        }

        DispatchQueue.main.async {
            self.cameraTrackState = .busy(isPublishing: !self.cameraTrackState.isPublished)
        }

        localParticipant.setCamera(enabled: !cameraTrackState.isPublished).then(on: .sdk) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else {
                    self.cameraTrackState = .notPublished()
                    return
                }

                self.cameraTrackState = .published(publication)
            }
        }.catch(on: .sdk) { error in
            DispatchQueue.main.async {
                self.cameraTrackState = .notPublished(error: error)
            }
        }
    }

    public func toggleScreenShareEnabled() {

        guard let localParticipant = room.localParticipant else {
            log("LocalParticipant doesn't exist", .notice)
            return
        }

        guard !screenShareTrackState.isBusy else {
            log("screenShareTrack is .busy", .notice)
            return
        }

        DispatchQueue.main.async {
            self.screenShareTrackState = .busy(isPublishing: !self.screenShareTrackState.isPublished)
        }

        localParticipant.setScreenShare(enabled: !screenShareTrackState.isPublished).then(on: .sdk) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else {
                    self.screenShareTrackState = .notPublished()
                    return
                }

                self.screenShareTrackState = .published(publication)
            }
        }.catch(on: .sdk) { error in
            DispatchQueue.main.async {
                self.screenShareTrackState = .notPublished(error: error)
            }
        }
    }

    public func toggleMicrophoneEnabled() {

        guard let localParticipant = room.localParticipant else {
            log("LocalParticipant doesn't exist", .notice)
            return
        }

        guard !microphoneTrackState.isBusy else {
            log("microphoneTrack is .busy", .notice)
            return
        }

        DispatchQueue.main.async {
            self.microphoneTrackState = .busy(isPublishing: !self.microphoneTrackState.isPublished)
        }

        localParticipant.setMicrophone(enabled: !microphoneTrackState.isPublished).then(on: .sdk) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else {
                    self.microphoneTrackState = .notPublished()
                    return
                }

                self.microphoneTrackState = .published(publication)
            }
        }.catch(on: .sdk) { error in
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
