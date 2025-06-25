/*
 * Copyright 2025 LiveKit
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

internal import LiveKitWebRTC

extension LKRTCPeerConnectionState {
    var isConnected: Bool {
        self == .connected
    }

    var isDisconnected: Bool {
        [.disconnected, .failed].contains(self)
    }
}

extension Room: TransportDelegate {
    func transport(_ transport: Transport, didUpdateState pcState: LKRTCPeerConnectionState) {
        log("target: \(transport.target), connectionState: \(pcState.description)")

        // primary connected
        if transport.isPrimary {
            if pcState.isConnected {
                primaryTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                primaryTransportConnectedCompleter.reset()
            }
        }

        // publisher connected
        if case .publisher = transport.target {
            if pcState.isConnected {
                publisherTransportConnectedCompleter.resume(returning: ())
            } else if pcState.isDisconnected {
                publisherTransportConnectedCompleter.reset()
            }
        }

        if _state.connectionState == .connected {
            // Attempt re-connect if primary or publisher transport failed
            if transport.isPrimary || (_state.hasPublished && transport.target == .publisher), pcState.isDisconnected {
                Task {
                    do {
                        try await startReconnect(reason: .transport)
                    } catch {
                        log("Failed calling startReconnect, error: \(error)", .error)
                    }
                }
            }
        }
    }

    func transport(_ transport: Transport, didGenerateIceCandidate iceCandidate: IceCandidate) {
        Task {
            do {
                log("sending iceCandidate")
                try await signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
            } catch {
                log("Failed to send iceCandidate, error: \(error)", .error)
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
                Task {
                    await self.engine(self, didAddTrack: track, rtpReceiver: rtpReceiver, stream: streams.first!)
                }
            }
        }
    }

    func transport(_ transport: Transport, didRemoveTrack track: LKRTCMediaStreamTrack) {
        if transport.target == .subscriber {
            Task {
                await engine(self, didRemoveTrack: track)
            }
        }
    }

    func transport(_ transport: Transport, didOpenDataChannel dataChannel: LKRTCDataChannel) {
        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        if _state.isSubscriberPrimary, transport.target == .subscriber {
            switch dataChannel.label {
            case LKRTCDataChannel.labels.reliable: subscriberDataChannel.set(reliable: dataChannel)
            case LKRTCDataChannel.labels.lossy: subscriberDataChannel.set(lossy: dataChannel)
            default: log("Unknown data channel label \(dataChannel.label)", .warning)
            }
        }
    }

    func transportShouldNegotiate(_: Transport) {}
}
