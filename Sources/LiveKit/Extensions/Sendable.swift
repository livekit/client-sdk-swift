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
extension LKRTCMediaConstraints: @unchecked @retroactive Sendable {}
extension LKRTCSessionDescription: @unchecked @retroactive Sendable {}
extension LKRTCVideoFrame: @unchecked @retroactive Sendable {}
extension LKRTCStatisticsReport: @unchecked @retroactive Sendable {}
extension LKRTCIceCandidate: @unchecked @retroactive Sendable {}
extension LKRTCVideoCodecInfo: @unchecked @retroactive Sendable {}
extension LKRTCFrameCryptorKeyProvider: @unchecked @retroactive Sendable {}
extension LKRTCRtpTransceiver: @unchecked @retroactive Sendable {}
extension LKRTCRtpTransceiverInit: @unchecked @retroactive Sendable {}
extension LKRTCPeerConnectionFactory: @unchecked @retroactive Sendable {}
