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

#if LK_XCFRAMEWORK
package import CLiveKitProto
#elseif !COCOAPODS
import CLiveKitProto
import LiveKitNanopb
#endif
import AVFoundation
import Foundation

internal import LiveKitWebRTC

// Messages are all one generic type, so there is a single conformance and a
// single witness. Per-message detail is reached through `NanopbStorage`'s
// `_describe` hook rather than a member on a constrained extension: the latter
// would only bind where the concrete type is known statically, and logging
// goes through dynamic dispatch.
extension NanopbMsg: CustomStringConvertible {
    package var description: String { S._describe(self) }
}

extension TrackSettings: CustomStringConvertible {
    public var description: String {
        "TrackSettings(enabled: \(isEnabled), dimensions: \(dimensions), videoQuality: \(videoQuality))"
    }
}

package extension livekit_VideoLayer {
    static func _describe(_ message: NanopbMsg<livekit_VideoLayer>) -> String {
        "VideoLayer(quality: \(message.quality), dimensions: \(message.width)x\(message.height), bitrate: \(message.bitrate))"
    }
}

public extension TrackPublication {
    override var description: String {
        "\(String(describing: type(of: self)))(sid: \(sid), kind: \(kind), source: \(source))"
    }
}

package extension livekit_AddTrackRequest {
    static func _describe(_ message: NanopbMsg<livekit_AddTrackRequest>) -> String {
        "AddTrackRequest(cid: \(message.cid), name: \(message.name), type: \(message.type), source: \(message.source), width: \(message.width), height: \(message.height), muted: \(message.muted))"
    }
}

package extension livekit_TrackInfo {
    static func _describe(_ message: NanopbMsg<livekit_TrackInfo>) -> String {
        "TrackInfo(sid: \(message.sid), " +
            "name: \(message.name), " +
            "type: \(message.type), " +
            "source: \(message.source), " +
            "width: \(message.width), " +
            "height: \(message.height), " +
            "isMuted: \(message.muted), " +
            "simulcast: \(message.simulcast), " +
            "codecs: \(message.codecs.map { String(describing: $0) }), " +
            "layers: \(message.layers.map { String(describing: $0) }))"
    }
}

package extension livekit_SubscribedQuality {
    static func _describe(_ message: NanopbMsg<livekit_SubscribedQuality>) -> String {
        "SubscribedQuality(quality: \(message.quality), enabled: \(message.enabled))"
    }
}

package extension livekit_SubscribedCodec {
    static func _describe(_ message: NanopbMsg<livekit_SubscribedCodec>) -> String {
        "SubscribedCodec(codec: \(message.codec), qualities: \(message.qualities.map { String(describing: $0) }.joined(separator: ", "))"
    }
}

package extension livekit_ServerInfo {
    static func _describe(_ message: NanopbMsg<livekit_ServerInfo>) -> String {
        "ServerInfo(edition: \(message.edition), " +
            "version: \(message.version), " +
            "protocol: \(message.protocol), " +
            "region: \(message.region), " +
            "nodeID: \(message.nodeID), " +
            "debugInfo: \(message.debugInfo))"
    }
}

// MARK: - NSObject

public extension Room {
    override var description: String {
        "Room(sid: \(String(describing: sid)), name: \(name ?? "nil"), serverVersion: \(serverVersion ?? "nil"), serverRegion: \(serverRegion ?? "nil"))"
    }
}

public extension Participant {
    override var description: String {
        "\(String(describing: type(of: self)))(sid: \(String(describing: sid)))"
    }
}

public extension Track {
    override var description: String {
        "\(String(describing: type(of: self)))(sid: \(String(describing: sid)), name: \(name), source: \(source))"
    }
}

extension Track.Source: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown: "unknown"
        case .camera: "camera"
        case .microphone: "microphone"
        case .screenShareVideo: "screenShareVideo"
        case .screenShareAudio: "screenShareAudio"
        }
    }
}

extension LKRTCPeerConnectionState {
    var description: String {
        switch self {
        case .new: return ".new"
        case .connecting: return ".connecting"
        case .connected: return ".connected"
        case .disconnected: return ".disconnected"
        case .failed: return ".failed"
        case .closed: return ".closed"
        @unknown default: return "unknown"
        }
    }
}

extension ConnectionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disconnected: ".disconnected"
        case .connecting: ".connecting"
        case .reconnecting: ".reconnecting"
        case .connected: ".connected"
        case .disconnecting: ".disconnecting"
        }
    }
}

extension ReconnectMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .quick: ".quick"
        case .full: ".full"
        }
    }
}

extension Livekit_SignalResponse {
    var description: String {
        "Livekit_SignalResponse(\(String(describing: message)))"
    }
}

// MARK: - NativeView

public extension VideoView {
    override var description: String {
        "VideoView(track: \(String(describing: track)))"
    }
}

extension VideoView.RenderMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .auto: ".auto"
        case .metal: ".metal"
        case .sampleBuffer: ".sampleBuffer"
        }
    }
}

extension SampleBufferVideoRenderer {
    override var description: String {
        "SampleBufferVideoRenderer"
    }
}

extension TextView {
    override var description: String {
        "TextView"
    }
}

// MARK: - LKRTC

extension LKRTCRtpEncodingParameters {
    func toDebugString() -> String {
        "RTCRtpEncodingParameters(" +
            "rid: \(String(describing: rid)), " +
            "isActive: \(String(describing: isActive)), " +
            "minBitrateBps: \(String(describing: minBitrateBps)), " +
            "maxBitrateBps: \(String(describing: maxBitrateBps)), " +
            "maxFramerate: \(String(describing: maxFramerate)), " +
            "scaleResolutionDownBy: \(String(describing: scaleResolutionDownBy)), " +
            "bitratePriority: \(bitratePriority), " +
            "networkPriority: \(networkPriority)" +
            ")"
    }
}

extension AVCaptureDevice.Format {
    func toDebugString() -> String {
        var values: [String] = []
        values.append("fps: \(fpsRange())")
        #if os(iOS)
        values.append("isMultiCamSupported: \(isMultiCamSupported)")
        #endif
        return "Format(\(values.joined(separator: ", ")))"
    }
}

extension LKRTCAudioProcessingConfig {
    func toDebugString() -> String {
        "RTCAudioProcessingConfig(" +
            "isEchoCancellationEnabled: \(isEchoCancellationEnabled), " +
            "isNoiseSuppressionEnabled: \(isNoiseSuppressionEnabled), " +
            "isAutoGainControl1Enabled: \(isAutoGainControl1Enabled), " +
            "isHighpassFilterEnabled: \(isHighpassFilterEnabled)" +
            ")"
    }
}
