import Foundation
import WebRTC

public typealias Sid = String

public enum Reliability: Int {
    case reliable = 0
    case lossy = 1
}

extension Reliability {

    func toPBType() -> Livekit_DataPacket.Kind {
        if self == .lossy { return .lossy }
        return .reliable
    }
}
