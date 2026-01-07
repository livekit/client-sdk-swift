/*
 * Copyright 2026 LiveKit
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

// MARK: Immutable classes

extension LKRTCDataBuffer: @unchecked Swift.Sendable {}
extension LKRTCDataChannel: @unchecked Swift.Sendable {}
extension LKRTCFrameCryptorKeyProvider: @unchecked Swift.Sendable {}
extension LKRTCIceCandidate: @unchecked Swift.Sendable {}
extension LKRTCMediaConstraints: @unchecked Swift.Sendable {}
extension LKRTCMediaStream: @unchecked Swift.Sendable {}
extension LKRTCMediaStreamTrack: @unchecked Swift.Sendable {}
extension LKRTCPeerConnection: @unchecked Swift.Sendable {}
extension LKRTCPeerConnectionFactory: @unchecked Swift.Sendable {}
extension LKRTCRtpReceiver: @unchecked Swift.Sendable {}
extension LKRTCRtpSender: @unchecked Swift.Sendable {}
extension LKRTCRtpTransceiver: @unchecked Swift.Sendable {}
extension LKRTCRtpTransceiverInit: @unchecked Swift.Sendable {}
extension LKRTCSessionDescription: @unchecked Swift.Sendable {}
extension LKRTCStatisticsReport: @unchecked Swift.Sendable {}
extension LKRTCVideoCodecInfo: @unchecked Swift.Sendable {}
extension LKRTCVideoFrame: @unchecked Swift.Sendable {}
extension LKRTCRtpCapabilities: @unchecked Swift.Sendable {}

// MARK: Mutable classes - to be validated

extension LKRTCConfiguration: @unchecked Swift.Sendable {}
extension LKRTCVideoCapturer: @unchecked Swift.Sendable {}
extension LKRTCDefaultAudioProcessingModule: @unchecked Swift.Sendable {}
extension LKRTCCallbackLogger: @unchecked Swift.Sendable {}

// MARK: Collections

#if swift(<6.2)
extension Dictionary: Swift.Sendable where Key: Sendable, Value: Sendable {}
#endif

// MARK: AV

extension AVCaptureDevice: @unchecked Swift.Sendable {}
extension AVCaptureDevice.Format: @unchecked Swift.Sendable {}
