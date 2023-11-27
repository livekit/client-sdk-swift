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

extension Room: MulticastDelegateProtocol {

    public func add(delegate: RoomDelegate) {
        delegates.add(delegate: delegate)
    }

    public func remove(delegate: RoomDelegate) {
        delegates.remove(delegate: delegate)
    }

    @objc
    public func removeAllDelegates() {
        delegates.removeAllDelegates()
    }

    /// Only for Objective-C.
    @objc(addDelegate:)
    @available(swift, obsoleted: 1.0)
    public func addObjC(delegate: RoomDelegateObjC) {
        delegates.add(delegate: delegate)
    }

    /// Only for Objective-C.
    @objc(removeDelegate:)
    @available(swift, obsoleted: 1.0)
    public func removeObjC(delegate: RoomDelegateObjC) {
        delegates.remove(delegate: delegate)
    }
}
