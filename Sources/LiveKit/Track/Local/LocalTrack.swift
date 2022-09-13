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

@objc
public protocol LocalTrack where Self: Track {

    @objc(publishOptions)
    var publishOptions: PublishOptions? { get }

    @objc(publishState)
    var publishState: PublishState { get }

    @objc(mute)
    @discardableResult
    func mute() -> Promise<Void>.ObjCPromise<NSNull>

    @objc(unmute)
    @discardableResult
    func unmute() -> Promise<Void>.ObjCPromise<NSNull>
}
