import Foundation
import WebRTC

public typealias Sid = String

public enum DataPublishReliability: Int {
    case reliable = 0
    case lossy = 1
}

extension DataPublishReliability {

    func toLKType() -> Livekit_DataPacket.Kind {
        if self == .lossy { return .lossy }
        return .reliable
    }
}
