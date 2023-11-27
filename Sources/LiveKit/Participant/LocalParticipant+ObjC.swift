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
