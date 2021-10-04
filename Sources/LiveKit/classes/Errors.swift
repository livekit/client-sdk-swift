//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/04.
//

import Foundation

enum LiveKitError: Error {

    // WebRTC lib returned error
    case webRTC(String?, Error? = nil)
    case invalidState(String? = nil)

    var localizedDescription: String {
        switch self {
        default: return "Unknown Error"
        }
    }
}
