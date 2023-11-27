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
