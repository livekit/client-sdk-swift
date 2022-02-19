import WebRTC

public enum VideoCodec: Hashable {

    public enum H264Profile {
        case constrainedBaseline // 42e01f
        case constrainedHigh // 640c1f
    }

    case vp8
    case vp9
    case h264(profile: H264Profile = .constrainedBaseline)
}

internal extension VideoCodec.H264Profile {

    func toString() -> String {
        switch self {
        case .constrainedBaseline: return kRTCMaxSupportedH264ProfileLevelConstrainedBaseline
        case .constrainedHigh: return kRTCMaxSupportedH264ProfileLevelConstrainedHigh
        }
    }
}

internal extension VideoCodec {

    static let kProfileLevelId = "profile-level-id"

    func isEqualTo(rtcType: RTCVideoCodecInfo) -> Bool {
        switch self {
        case .vp8: return rtcType.name == kRTCVp8CodecName
        case .vp9: return rtcType.name == kRTCVp9CodecName
        case .h264(let profile):
            guard rtcType.name == kRTCH264CodecName,
                  let profileLevelId = rtcType.parameters[Self.kProfileLevelId] else { return false }
            return profileLevelId == profile.toString()
        }
    }
}
