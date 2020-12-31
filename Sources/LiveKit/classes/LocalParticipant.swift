//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation

public class LocalParticipant: Participant {
    
    convenience init(fromInfo info: Livekit_ParticipantInfo) {
        self.init(sid: info.sid, name: info.name)
        self.info = info
    }
    
}
