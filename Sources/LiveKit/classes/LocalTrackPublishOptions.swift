//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/30/20.
//

import Foundation

public struct LocalAudioTrackPublishOptions {
    public var name: String?
    public var bitrate: Int?
    
    public init() {}
}

public struct LocalVideoTrackPublishOptions {
    public var encoding: VideoEncoding?
    /// true to enable simulcasting, publishes three tracks at different sizes
    public var simulcast: Bool = false
    
    public init() {}
}

public struct LocalDataTrackPublishOptions {
    public var name: String?
}

public struct VideoEncoding {
    public var maxBitrate: Int
    public var maxFps: Int
    
    public init(maxBitrate: Int, maxFps: Int) {
        self.maxBitrate = maxBitrate
        self.maxFps = maxFps
    }
}
