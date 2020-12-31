//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation

struct IceCandidate: Codable {
    let sdp: String
    let sdpMLineIndex: Int32
    let sdpMid: String?
    
    enum CodingKeys: String, CodingKey {
        case sdpMLineIndex, sdpMid
        case sdp = "candidate"
    }
}
