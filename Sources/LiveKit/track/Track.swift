//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/15/20.
//

import Foundation
import WebRTC

public class Track {

    public enum Kind {
        case audio
        case video
        case none
    }

    public internal(set) var name: String
    public internal(set) var sid: Sid?
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
