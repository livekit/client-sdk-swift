/*
 * Copyright 2024 LiveKit
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

@_implementationOnly import WebRTC

extension Engine: TransportDelegate {
    func transport(_ transport: Transport, didUpdateState pcState: RTCPeerConnectionState) {
        log("target: \(transport.target), state: \(pcState)")

        // primary connected
        if transport.isPrimary, case .connected = pcState {
            primaryTransportConnectedCompleter.resume(returning: ())
        }

        // publisher connected
        if case .publisher = transport.target, case .connected = pcState {
            publisherTransportConnectedCompleter.resume(returning: ())
        }

        if _state.connectionState == .connected {
            // Attempt re-connect if primary or publisher transport failed
            if transport.isPrimary || (_state.hasPublished && transport.target == .publisher), [.disconnected, .failed].contains(pcState) {
                Task {
                    try await startReconnect(reason: .transport)
                }
            }
        }
    }

    func transport(_ transport: Transport, didGenerateIceCandidate iceCandidate: LKRTCIceCandidate) {
        Task {
            do {
                log("sending iceCandidate")
                try await signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
            } catch {
                log("Failed to send iceCandidate", .error)
            }
        }
    }

    func transport(_ transport: Transport, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard !streams.isEmpty else {
            log("Received onTrack with no streams!", .warning)
            return
        }

        if transport.target == .subscriber {
            // execute block when connected
            execute(when: { state, _ in state.connectionState == .connected },
                    // always remove this block when disconnected
                    removeWhen: { state, _ in state.connectionState == .disconnected })
            { [weak self] in
                guard let self else { return }
                self.notify { $0.engine(self, didAddTrack: track, rtpReceiver: rtpReceiver, stream: streams.first!) }
            }
        }
    }

    func transport(_ transport: Transport, didRemoveTrack track: LKRTCMediaStreamTrack) {
        if transport.target == .subscriber {
            notify { $0.engine(self, didRemoveTrack: track) }
        }
    }

    func transport(_ transport: Transport, didOpenDataChannel dataChannel: LKRTCDataChannel) {
        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        Task {
            if subscriberPrimary, transport.target == .subscriber {
                switch dataChannel.label {
                case LKRTCDataChannel.labels.reliable: await subscriberDataChannel.set(reliable: dataChannel)
                case LKRTCDataChannel.labels.lossy: await subscriberDataChannel.set(lossy: dataChannel)
                default: log("Unknown data channel label \(dataChannel.label)", .warning)
                }
            }
        }
    }

    func transportShouldNegotiate(_: Transport) {}
}
