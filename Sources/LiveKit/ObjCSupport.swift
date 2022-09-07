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
import Promises
import WebRTC

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

    @objc
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

    @objc
    @discardableResult
    public func setCamera(enabled: Bool) -> Promise<LocalTrackPublication?>.ObjCPromise<LocalTrackPublication> {
        setCamera(enabled: enabled).asObjCPromise()
    }

    @objc
    @discardableResult
    public func setMicrophone(enabled: Bool) -> Promise<LocalTrackPublication?>.ObjCPromise<LocalTrackPublication> {
        setMicrophone(enabled: enabled).asObjCPromise()
    }
}

extension CameraCapturer {

    @objc
    @discardableResult
    public func switchCameraPosition() -> Promise<Bool>.ObjCPromise<NSNumber> {
        switchCameraPosition().asObjCPromise()
    }

    @objc
    public func setCameraPosition(_ position: AVCaptureDevice.Position) -> Promise<Bool>.ObjCPromise<NSNumber> {
        setCameraPosition(position).asObjCPromise()
    }
}

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
}
