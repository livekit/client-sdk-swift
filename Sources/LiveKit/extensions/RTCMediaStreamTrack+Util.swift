//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/27/20.
//

import Foundation
import WebRTC

extension RTCMediaStreamTrack {
    var unpackedTrackId: (Participant.Sid, String) {
        let parts = trackId.split(separator: Character("|"))
        guard parts.count > 1 else {
            return ("", trackId)
        }

        let trackIdIndex = trackId.index(trackId.startIndex, offsetBy: parts[0].count + 1)
        return (Participant.Sid(parts[0]), String(trackId[trackIdIndex...]))
    }
}
