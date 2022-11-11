/*
 * Copyright 2022 LiveKit
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

// MARK: - Objective-C Support

@objc(ConnectionState)
public enum ConnectionStateObjC: Int {
    case disconnected
    case connecting
    case reconnecting
    case connected
}

extension ConnectionState {

    func toObjCType() -> ConnectionStateObjC {
        switch self {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .reconnecting: return .reconnecting
        case .connected: return .connected
        }
    }
}

extension Room {

    @objc(connectWithURL:token:connectOptions:roomOptions:)
    @discardableResult
    public func connect(url: String,
                        token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) -> Promise<Room>.ObjCPromise<Room> {

        connect(url,
                token,
                connectOptions: connectOptions,
                roomOptions: roomOptions).asObjCPromise()
    }

    @objc(disconnect)
    @discardableResult
    public func disconnectObjC() -> Promise<Void>.ObjCPromise<NSNull> {

        disconnect().asObjCPromise()
    }
}

extension LocalParticipant {

    @objc(setCameraEnabled:)
    @discardableResult
    public func setCameraObjC(enabled: Bool) -> Promise<LocalTrackPublication?>.ObjCPromise<LocalTrackPublication> {

        setCamera(enabled: enabled).asObjCPromise()
    }

    @objc(setMicrophoneEnabled:)
    @discardableResult
    public func setMicrophoneObjC(enabled: Bool) -> Promise<LocalTrackPublication?>.ObjCPromise<LocalTrackPublication> {

        setMicrophone(enabled: enabled).asObjCPromise()
    }

    @objc(setScreenShareEnabled:)
    @discardableResult
    public func setScreenShareObjC(enabled: Bool) -> Promise<LocalTrackPublication?>.ObjCPromise<LocalTrackPublication> {

        setScreenShare(enabled: enabled).asObjCPromise()
    }

    @objc(publishVideoTrack:options:)
    @discardableResult
    public func publishVideoTrackObjC(track: LocalVideoTrack,
                                      publishOptions: VideoPublishOptions? = nil) -> Promise<LocalTrackPublication>.ObjCPromise<LocalTrackPublication> {

        publishVideoTrack(track: track, publishOptions: publishOptions).asObjCPromise()
    }

    @objc(publishAudioTrack:options:)
    @discardableResult
    public func publishAudioTrackObjC(track: LocalAudioTrack,
                                      publishOptions: AudioPublishOptions? = nil) -> Promise<LocalTrackPublication>.ObjCPromise<LocalTrackPublication> {

        publishAudioTrack(track: track, publishOptions: publishOptions).asObjCPromise()
    }

    @objc(unpublishPublication:)
    @discardableResult
    public func unpublishObjC(publication: LocalTrackPublication) -> Promise<Void>.ObjCPromise<NSNull> {

        unpublish(publication: publication).asObjCPromise()
    }

    @objc(publishData:reliability:destination:)
    @discardableResult
    public func publishDataObjC(data: Data,
                                reliability: Reliability = .reliable,
                                destination: [String] = []) -> Promise<Void>.ObjCPromise<NSNull> {

        publishData(data: data, reliability: reliability, destination: destination).asObjCPromise()
    }

    @objc(setTrackSubscriptionPermissionsWithAllParticipantsAllowed:trackPermissions:)
    @discardableResult
    public func setTrackSubscriptionPermissionsObjC(allParticipantsAllowed: Bool,
                                                    trackPermissions: [ParticipantTrackPermission] = []) -> Promise<Void>.ObjCPromise<NSNull> {

        setTrackSubscriptionPermissions(allParticipantsAllowed: allParticipantsAllowed,
                                        trackPermissions: trackPermissions).asObjCPromise()
    }
}

extension CameraCapturer {

    @objc(switchCameraPosition)
    @discardableResult
    public func switchCameraPositionObjC() -> Promise<Bool>.ObjCPromise<NSNumber> {

        switchCameraPosition().asObjCPromise()
    }

    @objc(setCameraPosition:)
    @discardableResult
    public func setCameraPositionObjC(_ position: AVCaptureDevice.Position) -> Promise<Bool>.ObjCPromise<NSNumber> {

        setCameraPosition(position).asObjCPromise()
    }
}

#if os(macOS)
extension MacOSScreenCapturer {

    // TODO: figure out how to return NSArray<MacOSScreenCaptureSource>
    @objc(sourcesFor:includingCurrentApplication:preferredMethod:)
    public static func sourcesObjC(for type: MacOSScreenShareSourceType,
                                   includeCurrentApplication: Bool = false,
                                   preferredMethod: MacOSScreenCapturePreferredMethod = .auto) -> Promise<[MacOSScreenCaptureSource]>.ObjCPromise<NSArray> {

        sources(for: type,
                includeCurrentApplication: includeCurrentApplication,
                preferredMethod: preferredMethod).asObjCPromise()
    }
}
#endif

extension Track {

    @objc(start)
    @discardableResult
    public func startObjC() -> Promise<Bool>.ObjCPromise<NSNumber> {

        start().asObjCPromise()
    }

    @objc(stop)
    @discardableResult
    public func stopObjC() -> Promise<Bool>.ObjCPromise<NSNumber> {

        stop().asObjCPromise()
    }

    @discardableResult
    internal func muteObjC() -> Promise<Void>.ObjCPromise<NSNull> {

        _mute().asObjCPromise()
    }

    @discardableResult
    internal func unmuteObjC() -> Promise<Void>.ObjCPromise<NSNull> {

        _unmute().asObjCPromise()
    }
}

extension LocalAudioTrack {

    public func mute() -> Promise<Void>.ObjCPromise<NSNull> {

        super.muteObjC()
    }

    public func unmute() -> Promise<Void>.ObjCPromise<NSNull> {

        super.unmuteObjC()
    }
}

extension LocalVideoTrack {

    public func mute() -> Promise<Void>.ObjCPromise<NSNull> {

        super.muteObjC()
    }

    public func unmute() -> Promise<Void>.ObjCPromise<NSNull> {

        super.unmuteObjC()
    }
}
