//
//  MediaTrack.swift
//  
//
//  Created by Russell D'Sa on 2/4/21.
//

import Foundation
import WebRTC

protocol MediaTrack {
    var mediaTrack: RTCMediaStreamTrack { get }
}
