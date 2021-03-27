//
//  File.swift
//  
//
//  Created by David Zhao on 3/26/21.
//

import Foundation

public enum VideoQuality {
    case low
    case medium
    case high
    
    internal func toProto() -> Livekit_VideoQuality {
        switch self {
        case .low:
            return .low
        case .high:
            return .high
        default:
            return .medium
        }
    }
}

func fromProto(videoQuality: Livekit_VideoQuality) -> VideoQuality {
    switch videoQuality {
    case .low:
        return .low
    case .high:
        return .high
    default:
        return .medium
    }
}
