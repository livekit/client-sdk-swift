//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/04.
//

import Foundation

protocol LiveKitError: Error {
    //
}

enum InternalError: LiveKitError {
    case parse(String? = nil)
    case convert(String? = nil)

    var localizedDescription: String {
        switch self {
        case .parse(let message): return "Error.Parse \(String(describing: message))"
        case .convert(let message): return "Error.Convert \(String(describing: message))"
        }
    }
}

enum EngineError: LiveKitError {

    // WebRTC lib returned error
    case webRTC(String?, Error? = nil)
    case invalidState(String? = nil)


}


enum SignalClientError: LiveKitError {

    case invalidRTCSdpType
    case socketNotConnected
    case socketError(String?, UInt16)
    case socketDisconnected
}
