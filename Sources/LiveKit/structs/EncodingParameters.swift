import Foundation

struct EncodingParameters {

    public private(set) var maxAudioBitrate: UInt
    public private(set) var maxVideoBitrate: UInt

    init(audioBitrate: UInt, videoBitrate: UInt) {
        maxAudioBitrate = audioBitrate
        maxVideoBitrate = videoBitrate
    }
}
