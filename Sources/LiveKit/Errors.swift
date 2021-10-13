import Foundation
import WebRTC

protocol LiveKitError: Error {}

enum RoomError: LiveKitError {
    case missingRoomId(String)
    case invalidURL(String)
    case protocolError(String)
}

enum InternalError: LiveKitError {
    case state(String? = nil)
    case parse(String? = nil)
    case convert(String? = nil)
    case timeout(String? = nil)

    var localizedDescription: String {
        switch self {
        case .state(let message): return "Error.State \(String(describing: message))"
        case .parse(let message): return "Error.Parse \(String(describing: message))"
        case .convert(let message): return "Error.Convert \(String(describing: message))"
        case .timeout(let message): return "Error.Timeout \(String(describing: message))"
        }
    }
}

enum EngineError: LiveKitError {
    // WebRTC lib returned error
    case webRTC(String?, Error? = nil)
    case invalidState(String? = nil)
}

enum TrackError: LiveKitError {
    case invalidTrackType(String)
    case duplicateTrack(String)
    case invalidTrackState(String)
    case mediaError(String)
    case publishError(String)
    case unpublishError(String)
}

enum SignalClientError: LiveKitError {
    case invalidRTCSdpType
    case socketNotConnected
    case socketError(String?, UInt16)
    case socketDisconnected
}
