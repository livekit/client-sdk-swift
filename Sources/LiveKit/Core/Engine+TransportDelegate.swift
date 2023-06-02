/*
 * Copyright 2023 LiveKit
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
import WebRTC
import Promises

extension Engine: TransportDelegate {

    func transport(_ transport: Transport, didGenerate stats: [TrackStats], target: Livekit_SignalTarget) {
        // relay to Room
        notify { $0.engine(self, didGenerate: stats, target: target) }
    }

    func transport(_ transport: Transport, didUpdate pcState: RTCPeerConnectionState) {
        log("target: \(transport.target), state: \(pcState)")

        // primary connected
        if transport.primary {
            _state.mutate { $0.primaryTransportConnectedCompleter.set(value: .connected == pcState ? true : nil) }
        }

        // publisher connected
        if case .publisher = transport.target {
            _state.mutate { $0.publisherTransportConnectedCompleter.set(value: .connected == pcState ? true : nil) }
        }

        if _state.connectionState.isConnected {
            // Attempt re-connect if primary or publisher transport failed
            if (transport.primary || (_state.hasPublished && transport.target == .publisher)) && [.disconnected, .failed].contains(pcState) {
                log("[reconnect] starting, reason: transport disconnected or failed")
                startReconnect()
            }
        }
    }

    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {
        log("didGenerate iceCandidate")
        signalClient.sendCandidate(candidate: iceCandidate,
                                   target: transport.target).catch(on: queue) { error in
                                    self.log("Failed to send candidate, error: \(error)", .error)
                                   }
    }

    func transport(_ transport: Transport, didAddTrack track: RTCMediaStreamTrack, rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        log("did add track")
        if transport.target == .subscriber {

            // execute block when connected
            execute(when: { state, _ in state.connectionState == .connected },
                    // always remove this block when disconnected
                    removeWhen: { state, _ in state.connectionState == .disconnected() }) { [weak self] in
                guard let self = self else { return }
                self.notify { $0.engine(self, didAddTrack: track, rtpReceiver: rtpReceiver, streams: streams) }
            }
        }
    }

    func transport(_ transport: Transport, didRemove track: RTCMediaStreamTrack) {
        if transport.target == .subscriber {
            notify { $0.engine(self, didRemove: track) }
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {

        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        if subscriberPrimary, transport.target == .subscriber {

            switch dataChannel.label {
            case RTCDataChannel.labels.reliable: subscriberDC.set(reliable: dataChannel)
            case RTCDataChannel.labels.lossy: subscriberDC.set(lossy: dataChannel)
            default: log("Unknown data channel label \(dataChannel.label)", .warning)
            }
        }
    }

    func transportShouldNegotiate(_ transport: Transport) {}
}
