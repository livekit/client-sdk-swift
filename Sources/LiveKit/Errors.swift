import Foundation
import WebRTC

protocol LiveKitError: Error {}

enum RoomError: LiveKitError {
    case missingRoomId(String)
    case invalidURL(String)
    case protocolError(String)
}

enum InternalError: LiveKitError & LocalizedError {
    case state(String? = nil)
    case parse(String? = nil)
    case convert(String? = nil)
    case timeout(String? = nil)

    var errorDescription: String? {
        switch self {
        case .state(let message): return Utils.buildErrorDescription("InternalError.State", message)
        case .parse(let message): return Utils.buildErrorDescription("InternalError.Parse", message)
        case .convert(let message): return Utils.buildErrorDescription("InternalError.Convert", message)
        case .timeout(let message): return Utils.buildErrorDescription("InternalError.Timeout", message)
        }
    }
}

enum EngineError: LiveKitError & LocalizedError {
    // WebRTC lib returned error
    case webRTC(String?, Error? = nil)
    case invalidState(String? = nil)

    var errorDescription: String? {
        switch self {
        case .webRTC(let message, _): return Utils.buildErrorDescription("EngineError.webRTC", message)
        case .invalidState(let message): return Utils.buildErrorDescription("EngineError.state", message)
        }
    }
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
    case close(String?)
}
