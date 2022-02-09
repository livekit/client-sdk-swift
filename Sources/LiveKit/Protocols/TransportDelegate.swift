import Foundation
import WebRTC

internal protocol TransportDelegate {
    func transport(_ transport: Transport, didUpdate state: RTCPeerConnectionState)
    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate)
    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel)
    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func transport(_ transport: Transport, didRemove track: RTCMediaStreamTrack)
    func transportShouldNegotiate(_ transport: Transport)
}

class TransportDelegateClosures: NSObject, TransportDelegate {

    typealias OnDidUpdateState = (_ transport: Transport, _ state: RTCPeerConnectionState) -> Void
    let onDidUpdateState: OnDidUpdateState?

    init(onDidUpdateState: OnDidUpdateState? = nil) {
        self.onDidUpdateState = onDidUpdateState
    }

    func transport(_ transport: Transport, didUpdate state: RTCPeerConnectionState) {
        onDidUpdateState?(transport, state)
    }

    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {}
    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {}
    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {}
    func transport(_ transport: Transport, didRemove track: RTCMediaStreamTrack) {}
    func transportShouldNegotiate(_ transport: Transport) {}
}
