import Foundation
import WebRTC
import Promises

public typealias Sid = String

// A tuple of Promises.
// listen: resolves when started listening
// wait: resolves when wait is complete or rejects when timeout
internal typealias WaitPromises<T> = (listen: Promise<Void>, wait: Promise<T>)

public enum Reliability {
    case reliable
    case lossy
}

internal extension Reliability {

    func toPBType() -> Livekit_DataPacket.Kind {
        if self == .lossy { return .lossy }
        return .reliable
    }
}

public enum SimulateScenario {
    case nodeFailure
    case migration
    case serverLeave
    case speakerUpdate(seconds: Int)
}
