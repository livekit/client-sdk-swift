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
    case unpublishError(String)
}

public class Track {
    static func fromProtoKind(_ pkind: Livekit_TrackType) -> Track.Kind {
        switch pkind {
        case .audio:
            return .audio
        case .video:
            return .video
        default:
            return .none
        }
    }

    public enum Kind {
        case audio, video, none

        func toProto() -> Livekit_TrackType {
            switch self {
            case .audio:
                return .audio
            case .video:
                return .video
            default:
                return .UNRECOGNIZED(10)
            }
        }
    }

    public struct Dimensions {
        public var width: Int
        public var height: Int
    }

    public internal(set) var name: String
    public internal(set) var sid: String?
    public internal(set) var kind: Track.Kind
    public internal(set) var mediaTrack: RTCMediaStreamTrack
    public internal(set) var transceiver: RTCRtpTransceiver?
    public var sender: RTCRtpSender? {
        return transceiver?.sender
    }

    init(name: String, kind: Kind, track: RTCMediaStreamTrack) {
        self.name = name
        self.kind = kind
        mediaTrack = track
    }

    public func stop() {
        mediaTrack.isEnabled = false
    }
}
