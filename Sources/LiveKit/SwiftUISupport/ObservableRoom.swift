import SwiftUI
import WebRTC
import OrderedCollections
import Promises

open class ObservableRoom: ObservableObject, RoomDelegate {

    public let room: Room

    @Published public var participants = OrderedDictionary<Sid, ObservableParticipant>()

    public var allParticipants: OrderedDictionary<Sid, ObservableParticipant> {
        var result = participants
        if let localParticipant = room.localParticipant {
            result.updateValue(ObservableParticipant(localParticipant),
                               forKey: localParticipant.sid,
                               insertingAt: 0)
        }
        return result
    }

    @Published public var localScreen: LocalTrackPublication?

    @Published public var cameraTrackState: TrackPublishState = .notPublished()
    @Published public var microphoneTrackState: TrackPublishState = .notPublished()

    public init(_ room: Room) {
        self.room = room
        room.add(delegate: self)

        if room.remoteParticipants.isEmpty {
            self.participants = [:]
        } else {
            // create initial participants
            for element in room.remoteParticipants {
                self.participants[element.key] = ObservableParticipant(element.value)
            }
        }
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
            print("Track or CameraCapturer doesn't exist")
            return Promise(TrackError.invalidTrackState("Track or a CameraCapturer doesn't exist"))
        }

        return cameraCapturer.switchCameraPosition()
    }

    public func toggleCameraEnabled() {

        guard let localParticipant = room.localParticipant else {
            // LocalParticipant should exist if alreadey connected to the room
            print("LocalParticipant doesn't exist")
            return
        }

        let enabled = localParticipant.isCameraEnabled()

        DispatchQueue.main.async {
            self.cameraTrackState = .busy(isPublishing: !enabled)
        }

        localParticipant.setCamera(enabled: !enabled).then { publication in
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

    public func toggleMicrophoneEnabled() {

        guard let localParticipant = room.localParticipant else {
            // LocalParticipant should exist if alreadey connected to the room
            print("LocalParticipant doesn't exist")
            return
        }

        let enabled = localParticipant.isMicrophoneEnabled()

        DispatchQueue.main.async {
            self.microphoneTrackState = .busy(isPublishing: !enabled)
        }

        localParticipant.setMicrophone(enabled: !enabled).then { publication in
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
        DispatchQueue.main.async {
            self.participants[participant.sid] = ObservableParticipant(participant)
        }
    }

    open func room(_ room: Room,
                   participantDidLeave participant: RemoteParticipant) {
        DispatchQueue.main.async {
            self.participants.removeValue(forKey: participant.sid)
        }
    }

    open func room(_ room: Room, participant: RemoteParticipant?, didReceive data: Data) {
        //
    }
}
