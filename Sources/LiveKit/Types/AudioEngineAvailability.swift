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

internal import LiveKitWebRTC

public struct AudioEngineAvailability: Sendable {
    public static let `default` = AudioEngineAvailability(isInputAvailable: true, isOutputAvailable: true)
    public static let none = AudioEngineAvailability(isInputAvailable: false, isOutputAvailable: false)

    public let isInputAvailable: Bool
    public let isOutputAvailable: Bool

    public init(isInputAvailable: Bool, isOutputAvailable: Bool) {
        self.isInputAvailable = isInputAvailable
        self.isOutputAvailable = isOutputAvailable
    }
}

extension LKRTCAudioEngineAvailability {
    func toLKType() -> AudioEngineAvailability {
        AudioEngineAvailability(isInputAvailable: isInputAvailable.boolValue,
                                isOutputAvailable: isOutputAvailable.boolValue)
    }
}

extension AudioEngineAvailability {
    func toRTCType() -> LKRTCAudioEngineAvailability {
        LKRTCAudioEngineAvailability(isInputAvailable: ObjCBool(isInputAvailable),
                                     isOutputAvailable: ObjCBool(isOutputAvailable))
    }
}
