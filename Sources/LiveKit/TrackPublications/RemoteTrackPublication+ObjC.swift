/*
 * Copyright 2023 LiveKit
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

public extension RemoteTrackPublication {
    @objc(setEnabled:)
    @discardableResult
    func setObjC(enabled value: Bool) -> Promise<Void>.ObjCPromise<NSNull> {
        set(enabled: value).asObjCPromise()
    }

    @objc(setSubscribed:)
    @discardableResult
    func setObjC(subscribed value: Bool) -> Promise<Void>.ObjCPromise<NSNull> {
        set(subscribed: value).asObjCPromise()
    }
}
