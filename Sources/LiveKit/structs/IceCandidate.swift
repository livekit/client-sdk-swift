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
            throw InternalError.convert("Failed to convert String to Data")
        }
        // Decode JSON
        let iceCandidate: IceCandidate = try JSONDecoder().decode(IceCandidate.self, from: data)

        self.init(sdp: iceCandidate.sdp,
                  sdpMLineIndex: iceCandidate.sdpMLineIndex,
                  sdpMid: iceCandidate.sdpMid)
    }
}

extension IceCandidate {

    func toJsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw InternalError.convert("Failed to convert Data to String")
        }
        return string
    }
}
