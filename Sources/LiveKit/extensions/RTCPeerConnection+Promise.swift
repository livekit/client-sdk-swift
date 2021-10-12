import WebRTC
import Promises

// TODO: Currently uses .main queue, use own queue
// Promise version

extension RTCPeerConnection {

    func createOfferPromise(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                   optionalConstraints: nil)

        return Promise<RTCSessionDescription> { complete, fail in
            self.offer(for: mediaConstraints) { sd, error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to create offer", error))
                    return
                }
                guard let sd = sd else {
                    fail(EngineError.webRTC("session description is null"))
                    return
                }
                complete(sd)
            }
        }
    }

    func createAnswerPromise(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                   optionalConstraints: nil)

        return Promise<RTCSessionDescription> { complete, fail in
            self.answer(for: mediaConstraints) { sd, error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to create offer", error))
                    return
                }
                guard let sd = sd else {
                    fail(EngineError.webRTC("session description is null"))
                    return
                }
                complete(sd)
            }
        }
    }

    func setLocalDescriptionPromise(_ sd: RTCSessionDescription) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription> { complete, fail in
            self.setLocalDescription(sd) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to set local description", error))
                    return
                }
                complete(sd)
            }
        }
    }


    func setRemoteDescriptionPromise(_ sd: RTCSessionDescription) -> Promise<RTCSessionDescription> {

        Promise<RTCSessionDescription> { complete, fail in
            self.setRemoteDescription(sd) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to set remote description", error))
                    return
                }
                complete(sd)
            }
        }
    }

    func addIceCandidatePromise(_ candidate: RTCIceCandidate) -> Promise<Void> {

        Promise<Void> { complete, fail in
            self.add(candidate) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to add ice candidate", error))
                    return
                }
                complete(())
            }
        }
    }
}
