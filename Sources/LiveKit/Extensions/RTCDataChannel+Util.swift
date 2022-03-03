import WebRTC

extension RTCDataChannel {

    struct labels {
        static let reliable = "_reliable"
        static let lossy = "_lossy"
    }

    func toLKInfoType() -> Livekit_DataChannelInfo {
        Livekit_DataChannelInfo.with {
            $0.id = UInt32(max(0, channelId))
            $0.label = label
        }
    }
}
