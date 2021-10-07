//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/16/20.
//

import WebRTC

public class AudioTrack: Track {
    public private(set) var sinks: [AudioSink]?
    public var audioTrack: RTCAudioTrack {
        get { return mediaTrack as! RTCAudioTrack }
    }

    init(rtcTrack: RTCAudioTrack, name: String) {
        super.init(name: name, kind: .audio, track: rtcTrack)
    }

    public func addSink(_ sink: AudioSink) {
        sinks?.append(sink)
    }

    public func removeSink(_ sink: AudioSink) {
        sinks?.removeAll(where: { s -> Bool in
            (sink as AnyObject) === (s as AnyObject)
        })
    }
}
