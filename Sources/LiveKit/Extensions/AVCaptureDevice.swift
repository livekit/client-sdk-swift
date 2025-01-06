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

import AVFoundation

public extension AVCaptureDevice {
    /// Helper extension to return the acual direction the camera is facing.
    var facingPosition: AVCaptureDevice.Position {
        #if os(macOS)
        /// In macOS, the Facetime camera's position is .unspecified but this property will return .front for such cases.
        if deviceType == .builtInWideAngleCamera, position == .unspecified {
            return .front
        }
        #elseif os(visionOS)
        /// In visionOS, the Persona camera's position is .unspecified but this property will return .front for such cases.
        if position == .unspecified {
            return .front
        }
        #endif

        return position
    }
}

public extension Collection where Element: AVCaptureDevice {
    /// Helper extension to return only a single suggested device for each position.
    func singleDeviceforEachPosition() -> [AVCaptureDevice] {
        let front = first { $0.facingPosition == .front }
        let back = first { $0.facingPosition == .back }
        return [front, back].compactMap { $0 }
    }
}
