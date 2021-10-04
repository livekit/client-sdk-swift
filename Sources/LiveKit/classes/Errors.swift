//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/04.
//

import Foundation

enum LiveKitError: Error {

    case webRTC(String? = nil)

    var localizedDescription: String {
        switch self {
        default: return "Unknown Error"
        }
    }
}
