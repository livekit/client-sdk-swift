import Foundation
import WebRTC

internal protocol TransportDelegate {
    func transport(_ transport: Transport, didUpdate iceState: RTCIceConnectionState)
    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate)
    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel)
    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func transportShouldNegotiate(_ transport: Transport)
}

// optional
extension TransportDelegate {
    func transport(_ transport: Transport, didUpdate iceState: RTCIceConnectionState) {}
    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {}
    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {}
    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {}
    func transportShouldNegotiate(_ transport: Transport) {}
}

class TransportDelegateClosures: NSObject, TransportDelegate {

    typealias OnIceStateUpdated = (_ transport: Transport, _ iceState: RTCIceConnectionState) -> Void
    let onIceStateUpdated: OnIceStateUpdated?

    init(onIceStateUpdated: OnIceStateUpdated? = nil) {
        self.onIceStateUpdated = onIceStateUpdated
    }

    func transport(_ transport: Transport, didUpdate iceState: RTCIceConnectionState) {
        onIceStateUpdated?(transport, iceState)
    }

    // ...
}
