//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/15/20.
//

import Foundation
import WebRTC

enum TrackError: Error {
    case invalidTrackType(String)
    case duplicateTrack(String)
    case invalidTrackState(String)
    case mediaError(String)
    case publishError(String)
}

public class Track {
    public typealias Sid = String
    public typealias Cid = String
    
    static func stateFromRTCMediaTrackState(rtcState: RTCMediaStreamTrackState) throws -> Track.State {
        switch rtcState {
        case .ended:
            return .ended
        case .live:
            return .live
        @unknown default:
            throw TrackError.invalidTrackState("Unknown RTCMediaStreamTrackState: \(rtcState)")
        }
    }
    
    static func stateFromRTCDataChannelState(rtcState: RTCDataChannelState) throws -> Track.State {
        switch rtcState {
        case .connecting, .open:
            return .live
        case .closing, .closed:
            return .ended
        @unknown default:
            throw TrackError.invalidTrackState("Unknown RTCDataChannelState: \(rtcState)")
        }
    }
    
    public enum Priority {
        case standard, high, low
    }
    
    public enum State {
        case ended, live, none
    }
    
    public internal(set) var name: String
    public internal(set) var state: Track.State
    
    init(name: String, state: Track.State) {
        self.name = name
        self.state = state
    }
}
