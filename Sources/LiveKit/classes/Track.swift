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
    
    static func fromProtoKind(_ pkind: Livekit_TrackType) -> Track.Kind {
        switch pkind {
        case .audio:
            return .audio
        case .video:
            return .video
        case .data:
            return .data
        default:
            return .none
        }
    }
    
    public enum Priority {
        case standard, high, low
    }
    
    public enum State {
        case ended, live, none
    }
    
    public enum Kind {
        case audio, video, data, none
        
        func toProto() -> Livekit_TrackType {
            switch self {
            case .audio:
                return .audio
            case .video:
                return .video
            case .data:
                return .data
            default:
                return .UNRECOGNIZED(10)
            }
        }
    }

    public internal(set) var name: String
    public internal(set) var state: Track.State
    public internal(set) var sid: String?
    public internal(set) var kind: Track.Kind
    
    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
        self.state = .none
    }
    
    public func stop() {
        // do nothing
    }
}
