//
//  AudioOptions.swift
//  
//
//  Created by Russell D'Sa on 1/25/21.
//

import Foundation

public typealias AudioOptionsBuilderBlock = (inout AudioOptionsBuilder) -> Void

public struct AudioOptions {
    /*
    public private(set) audioJitterBufferMaxPackets: Int = 50
    public private(set) audioJitterBufferFastAccelerate: Bool = false
    public private(set) softwareAecEnabled: Bool = false
    public private(set) highpassFilter = true
    */
    
    public static func options() -> AudioOptions {
        return AudioOptions()
    }
    
    public static func options(block: AudioOptionsBuilderBlock) {
        var builder = AudioOptionsBuilder()
        block(&builder)
    }
}

public struct AudioOptionsBuilder {
    /*
    public private(set) audioJitterBufferMaxPackets: Int = 50
    public private(set) audioJitterBufferFastAccelerate: Bool = false
    public private(set) softwareAecEnabled: Bool = false
    public private(set) highpassFilter = true
    */
}
