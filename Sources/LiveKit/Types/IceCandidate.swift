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

struct IceCandidate: Codable {
    let sdp: String
    let sdpMLineIndex: Int32
    let sdpMid: String?

    enum CodingKeys: String, CodingKey {
        case sdpMLineIndex, sdpMid
        case sdp = "candidate"
    }

    func toJsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw InternalError.convert(message: "Failed to convert Data to String")
        }
        return string
    }
}

extension RTCIceCandidate {

    func toLKType() -> IceCandidate {
        IceCandidate(sdp: sdp,
                     sdpMLineIndex: sdpMLineIndex,
                     sdpMid: sdpMid)
    }

    convenience init(fromJsonString string: String) throws {
        // String to Data
        guard let data = string.data(using: .utf8) else {
            throw InternalError.convert(message: "Failed to convert String to Data")
        }
        // Decode JSON
        let iceCandidate: IceCandidate = try JSONDecoder().decode(IceCandidate.self, from: data)

        self.init(sdp: iceCandidate.sdp,
                  sdpMLineIndex: iceCandidate.sdpMLineIndex,
                  sdpMid: iceCandidate.sdpMid)
    }
}
