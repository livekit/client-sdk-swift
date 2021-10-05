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

enum EngineError: LiveKitError {

    // WebRTC lib returned error
    case webRTC(String?, Error? = nil)
    case invalidState(String? = nil)

//    var localizedDescription: String {
//        switch self {
//        default: return "Unknown Error"
//        }
//    }
}


enum SignalClientError: LiveKitError {

    case invalidRTCSdpType
    case socketNotConnected
    case socketError(String?, UInt16)
    case socketDisconnected
}
