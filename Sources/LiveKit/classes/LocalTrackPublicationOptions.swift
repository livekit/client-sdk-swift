//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/30/20.
//

import Foundation

public class LocalTrackPublicationOptions {
    
    public private(set) var priority: Track.Priority
    
    public static func optionsWithPriority(_ priority: Track.Priority) -> LocalTrackPublicationOptions {
        self.init(priority: priority)
    }
    
    required init(priority: Track.Priority) {
        self.priority = priority
    }
}
