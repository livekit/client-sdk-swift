//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/27/20.
//

import Foundation
import WebRTC

extension RTCDataChannel {
    var unpackedTrackLabel: (String, String, String) {
        let parts = label.split(separator: Character("|"))
        guard parts.count != 3 else {
            return ("", "", "")
        }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }
}
