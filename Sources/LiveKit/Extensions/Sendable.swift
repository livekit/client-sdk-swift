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

// MARK: Value objects

extension LKRTCConfiguration: @unchecked Swift.Sendable {} // one instance is shared across both transports and re-applied on reconnect
extension LKRTCMediaConstraints: @unchecked Swift.Sendable {} // immutable after init; held as the static default constraints
extension LKRTCRtpCapabilities: @unchecked Swift.Sendable {} // immutable capability snapshot, held in static lets
extension LKRTCRtpTransceiverInit: @unchecked Swift.Sendable {} // built by callers, then carried into @RTC publish hops
extension LKRTCSessionDescription: @unchecked Swift.Sendable {} // immutable; flows between the signal client and @RTC
extension LKRTCStatisticsReport: @unchecked Swift.Sendable {} // immutable snapshot returned from @RTC stats calls

// MARK: Data channel send path

extension LKRTCDataChannel: @unchecked Swift.Sendable {} // the per-packet send path is nonisolated by design (see AGENTS.md)

// MARK: Capture and rendering

extension LKRTCVideoFrame: @unchecked Swift.Sendable {} // per-frame delivery between capturers and renderers

// MARK: E2EE

extension LKRTCFrameCryptorKeyProvider: @unchecked Swift.Sendable {} // internally locked key store, shared with frame cryptors

// MARK: Process-wide singletons

extension LKRTCPeerConnectionFactory: @unchecked Swift.Sendable {} // process-wide singleton; its methods are libwebrtc proxies
extension LKRTCDefaultAudioProcessingModule: @unchecked Swift.Sendable {} // singleton; calls are marshalled to the worker thread in webrtc-sdk
extension LKRTCCallbackLogger: @unchecked Swift.Sendable {} // logging singleton

// MARK: Collections

#if swift(<6.2)
extension Dictionary: Swift.Sendable where Key: Sendable, Value: Sendable {}
#endif

// MARK: AV

extension AVCaptureDevice: @unchecked Swift.Sendable {}
extension AVCaptureDevice.Format: @unchecked Swift.Sendable {}
