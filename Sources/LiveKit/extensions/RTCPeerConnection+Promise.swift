//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/04.
//

import WebRTC
import Promises

// TODO: Currently uses .main queue, use own queue
// Promise version

extension RTCPeerConnection {

    func promiseCreateOffer(for constraints: RTCMediaConstraints) -> Promise<RTCSessionDescription> {

        return Promise<RTCSessionDescription> { complete, fail in

            self.offer(for: constraints) { sd, error in

                guard error == nil else {
                    fail(LiveKitError.webRTC("failed to create offer", error))
                    return
                }

                guard let sd = sd else {
                    fail(LiveKitError.webRTC("session description is null"))
                    return
                }

                complete(sd)
            }
        }
    }

    func promiseCreateAnswer(for constraints: RTCMediaConstraints) -> Promise<RTCSessionDescription> {

        return Promise<RTCSessionDescription> { complete, fail in

            self.answer(for: constraints) { sd, error in

                guard error == nil else {
                    fail(LiveKitError.webRTC("failed to create offer", error))
                    return
                }

                guard let sd = sd else {
                    fail(LiveKitError.webRTC("session description is null"))
                    return
                }

                complete(sd)
            }
        }
    }

    func promiseSetLocalDescription(sdp: RTCSessionDescription) -> Promise<Void> {

        return Promise<Void> { complete, fail in

            self.setLocalDescription(sdp) { error in

                guard error == nil else {
                    fail(LiveKitError.webRTC("failed to set local description", error))
                    return
                }

                complete(())
            }
        }
    }


    func promiseSetRemoteDescription(_ sdp: RTCSessionDescription) -> Promise<Void> {

        return Promise<Void> { complete, fail in

            self.setRemoteDescription(sdp) { error in

                guard error == nil else {
                    fail(LiveKitError.webRTC("failed to set remote description", error))
                    return
                }

                complete(())
            }
        }
    }

    @discardableResult
    func promiseAddIceCandidate(_ candidate: RTCIceCandidate) -> Promise<Void> {

        return Promise<Void> { complete, fail in

            self.add(candidate) { error in

                guard error == nil else {
                    fail(LiveKitError.webRTC("failed to add ice candidate", error))
                    return
                }

                complete(())
            }
        }
    }
}
