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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Immutable classes.
extension LKRTCMediaConstraints: @unchecked Swift.Sendable {}
extension LKRTCSessionDescription: @unchecked Swift.Sendable {}
extension LKRTCVideoFrame: @unchecked Swift.Sendable {}
extension LKRTCStatisticsReport: @unchecked Swift.Sendable {}
extension LKRTCIceCandidate: @unchecked Swift.Sendable {}
extension LKRTCVideoCodecInfo: @unchecked Swift.Sendable {}
extension LKRTCFrameCryptorKeyProvider: @unchecked Swift.Sendable {}
extension LKRTCRtpTransceiver: @unchecked Swift.Sendable {}
extension LKRTCRtpTransceiverInit: @unchecked Swift.Sendable {}
extension LKRTCPeerConnectionFactory: @unchecked Swift.Sendable {}
